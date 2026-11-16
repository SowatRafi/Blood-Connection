/** One-time, offline importer. SQLite is read only here; the application runtime uses PostgreSQL exclusively. */
import { DatabaseSync, backup } from 'node:sqlite';
import { mkdir, readdir } from 'node:fs/promises';
import { resolve, join } from 'node:path';
import pg from 'pg';
import { loadSettings } from '../src/config.js';
import { Store, countrySchema } from '../src/store.js';
import { ISO_COUNTRY_CODES } from '../src/countries.js';

const source = resolve(process.argv[2] || 'data');
const backupDirectory = resolve(process.argv[3] || `../artifacts/sqlite-backup-${new Date().toISOString().replace(/[:.]/g, '-')}`);
const settings = loadSettings();
if (!settings.migrationDatabaseUrl) throw new Error('MIGRATION_DATABASE_URL is required for the one-time import');
const files = (await readdir(source)).filter(name => name === 'registry.sqlite3' || (/^[A-Z]{2}\.sqlite3$/.test(name) && ISO_COUNTRY_CODES.includes(name.slice(0, 2))));
if (!files.includes('registry.sqlite3')) throw new Error('Source registry.sqlite3 is required');
await mkdir(backupDirectory, { recursive: true });
const snapshots = new Map();
const globalTables = ['accounts', 'donations', 'donation_confirmations', 'blocks', 'audit', 'media_cleanup', 'deletion_jobs', 'devices', 'active_matches'];
const countryTables = ['profiles', 'conversations', 'messages', 'reports', 'report_attachments', 'calls', 'profile_photos', 'donation_requests', 'request_invitations', 'events', 'push_outbox'];
// Stop legacy writers before running this importer: each file gets a consistent
// SQLite backup, but separate database files do not share one snapshot boundary.
for (const name of files) {
  const sourceDatabase = new DatabaseSync(join(source, name), { readOnly: true });
  try { await backup(sourceDatabase, join(backupDirectory, name)); } finally { sourceDatabase.close(); }
  const snapshot = new DatabaseSync(join(backupDirectory, name), { readOnly: true });
  try {
    const tables = name === 'registry.sqlite3' ? globalTables : countryTables;
    const exists = new Set(snapshot.prepare("SELECT name FROM sqlite_master WHERE type='table'").all().map(row => row.name));
    // This importer targets the committed baseline, not unknown historic layouts requiring clinical-data backfills.
    const required = name === 'registry.sqlite3' ? {
      donations: ['facility_name', 'location_name', 'country', 'request_id', 'confirmed_by', 'confirmed_by_role', 'idempotency_key'],
      donation_confirmations: ['requester_id', 'donor_name', 'donor_dismissed', 'seeker_dismissed'],
    } : { reports: ['request_id', 'idempotency_key', 'reviewed_at'], events: ['report_id', 'report_country'] };
    for (const [table, columns] of Object.entries(required)) {
      const found = new Set(snapshot.prepare(`PRAGMA table_info("${table}")`).all().map(row => row.name));
      if (!columns.every(column => found.has(column))) throw new Error('Import requires the SQLite schema from baseline 4e90456; upgrade an older installation first');
    }
    snapshots.set(name, Object.fromEntries(tables.map(table => [table, exists.has(table) ? snapshot.prepare(`SELECT * FROM "${table}"`).all() : []])));
  } finally { snapshot.close(); }
}

const store = new Store(settings);
const client = new pg.Client({ connectionString: settings.migrationDatabaseUrl });
let count = 0, skippedOutbox = 0;
try {
  await store.migrate(settings.demo ? ISO_COUNTRY_CODES : [...new Set([...settings.countries, ...files.filter(f => f !== 'registry.sqlite3').map(f => f.slice(0, 2))])]);
  await client.connect();
  await client.query('BEGIN ISOLATION LEVEL SERIALIZABLE');
  await client.query('LOCK TABLE registry.accounts IN ACCESS EXCLUSIVE MODE');
  if (Number((await client.query('SELECT COUNT(*) AS count FROM registry.accounts')).rows[0].count)) throw new Error('Target already contains accounts; import refused to avoid overwriting data');
  const registry = snapshots.get('registry.sqlite3');
  const deviceIds = new Set(registry.devices.map(row => row.id));
  const timestamps = new Set(['created_at', 'updated_at', 'expires_at', 'reviewed_at', 'eligible_after_utc', 'next_attempt']);
  // Fixed table lists and validated column names prevent SQL injection; timestamps retain their original instants.
  const insert = async (schema, table, row) => {
    const fields = Object.keys(row);
    if (fields.some(field => !/^[a-z_]+$/.test(field))) throw new Error('Unexpected legacy column');
    const values = fields.map(field => {
      const value = row[field];
      if (value instanceof Uint8Array) return Buffer.from(value);
      if (value && timestamps.has(field)) return new Date(value).toISOString();
      return value;
    });
    await client.query(`INSERT INTO ${schema}."${table}"(${fields.map(f => `"${f}"`).join(',')}) VALUES(${fields.map((_, i) => `$${i + 1}`).join(',')})`, values);
    count++;
  };
  for (const table of globalTables) for (const row of registry[table]) await insert('registry', table, row);
  for (const [file, tables] of snapshots) {
    if (file === 'registry.sqlite3') continue;
    const schema = countrySchema(file.slice(0, 2));
    for (const table of countryTables) for (const row of tables[table]) {
      // Legacy device removal could leave undeliverable jobs; account data and inbox events are retained.
      if (table === 'push_outbox' && !deviceIds.has(row.device_id)) { skippedOutbox++; continue; }
      await insert(schema, table, row);
    }
    // Explicitly imported IDs do not advance PostgreSQL's identity sequence.
    // Leave an empty inbox uncalled so its first newly created event still gets ID 1.
    await client.query(`SELECT setval(pg_get_serial_sequence($1,'id'),COALESCE((SELECT MAX(id) FROM ${schema}.events),1),EXISTS(SELECT 1 FROM ${schema}.events))`, [`${schema}.events`]);
  }
  await client.query('COMMIT');
  console.info(JSON.stringify({ importedRows: count, skippedUndeliverableOutboxRows: skippedOutbox, backupDirectory }));
} catch (error) {
  await client.query('ROLLBACK').catch(() => {});
  throw error;
} finally { await client.end(); await store.close(); }
