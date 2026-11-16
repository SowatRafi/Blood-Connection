import { readFile } from 'node:fs/promises';
import { setTimeout as delay } from 'node:timers/promises';
import pg from 'pg';
import { ISO_COUNTRY_CODES, COUNTRIES } from './countries.js';

export { ISO_COUNTRY_CODES, COUNTRIES } from './countries.js';
const { Pool } = pg;
const allowedCountries = new Set(ISO_COUNTRY_CODES);
const sqlDirectory = new URL('../sql/', import.meta.url);

/** Identifiers cannot be query parameters; this fixed ISO allowlist makes schema interpolation safe. */
export function countrySchema(country) {
  if (!allowedCountries.has(country)) throw Object.assign(new Error('Choose a valid ISO country'), { statusCode: 400 });
  return `"country_${country.toLowerCase()}"`;
}

/** Every helper uses the same checked-out connection, so awaited work cannot escape its transaction. */
function database(client) {
  return {
    query: (sql, values = []) => client.query(sql, values),
    run: (sql, values = []) => client.query(sql, values),
    one: async (sql, values = []) => (await client.query(sql, values)).rows[0],
    all: async (sql, values = []) => (await client.query(sql, values)).rows,
    schema: countrySchema,
  };
}

/** One database keeps safety and country-schema changes atomic; migration credentials stay separate. */
export class Store {
  constructor(settings) {
    this.settings = settings;
    if (!settings.databaseUrl) throw new Error('DATABASE_URL is required');
    this.pool = this.makePool(settings.databaseUrl);
    this.migrationPool = null;
    this.regions = new Set();
  }

  makePool(connectionString) {
    // Timeouts bound stalled requests; production TLS verification comes from the configured URL/PG settings.
    return new Pool({ connectionString, max: this.settings.databasePoolSize ?? 10,
      connectionTimeoutMillis: 5000, idleTimeoutMillis: 30000,
      statement_timeout: 15000, idle_in_transaction_session_timeout: 15000,
      query_timeout: 20000, application_name: 'blood-connection' });
  }

  async initialize() {
    // Startup verifies deployment readiness without granting application workers permission to create tables.
    const { rows } = await this.pool.query('SELECT to_regclass($1) AS table_name', ['registry.accounts']);
    if (!rows[0].table_name) throw new Error('Database is not migrated. Run npm run db:migrate with migration credentials.');
    await this.refreshRegions();
    return this;
  }

  /** Discover only already-provisioned schemas; an HTTP country header cannot cause DDL. */
  async refreshRegions() {
    const { rows } = await this.pool.query("SELECT nspname FROM pg_catalog.pg_namespace WHERE nspname ~ '^country_[a-z]{2}$'");
    this.regions = new Set(rows.map(row => row.nspname.slice(8).toUpperCase()).filter(code => allowedCountries.has(code)));
    return [...this.regions].sort();
  }

  /** Return a copy so workers cannot accidentally mutate the provisioned-country cache. */
  regionNames() { return [...this.regions].sort(); }
  /** Keep the domain-facing country catalog limited to deployable, existing storage. */
  countries() { return this.regionNames(); }

  /** Unknown or unprovisioned countries fail before any dynamically qualified SQL executes. */
  async ensureRegion(country) {
    countrySchema(country);
    if (!this.regions.has(country)) await this.refreshRegions();
    if (!this.regions.has(country)) throw Object.assign(new Error('This country is not provisioned. Ask an administrator to run its migration.'), { statusCode: 409 });
  }

  /** Serializable retries preserve cross-schema safety invariants when multiple API workers race. */
  async transaction(country, work) {
    if (typeof country === 'function') { work = country; country = null; }
    if (country) await this.ensureRegion(country);
    for (let attempt = 0; attempt < 4; attempt += 1) {
      const client = await this.pool.connect();
      try {
        await client.query('BEGIN ISOLATION LEVEL SERIALIZABLE');
        await client.query(`SET LOCAL search_path = pg_catalog, ${country ? `${countrySchema(country)}, ` : ''}registry, public`);
        const result = await work(database(client));
        await client.query('COMMIT');
        return result;
      } catch (error) {
        await client.query('ROLLBACK').catch(() => {});
        // Only retry serialization/deadlock failures; callbacks must contain database work, never external delivery.
        if (!['40001', '40P01'].includes(error.code) || attempt === 3) throw error;
      } finally { client.release(); }
      await delay(10 * (attempt + 1));
    }
  }

  /** Explicit migration ownership keeps schema changes and runtime privileges independently controllable. */
  async migrate(countries = this.settings.demo ? ISO_COUNTRY_CODES : [...(this.settings.countries ?? [])]) {
    if (!this.settings.migrationDatabaseUrl) throw new Error('MIGRATION_DATABASE_URL is required for schema changes');
    const requested = [...new Set(countries)].sort();
    requested.forEach(countrySchema);
    if (!requested.length) throw new Error('At least one enabled country is required');
    this.migrationPool ??= this.makePool(this.settings.migrationDatabaseUrl);
    const client = await this.migrationPool.connect();
    const registrySql = await readFile(new URL('registry.sql', sqlDirectory), 'utf8');
    const countrySql = await readFile(new URL('country.sql', sqlDirectory), 'utf8');
    const role = this.settings.databaseRole ?? new URL(this.settings.databaseUrl).username;
    if (!/^[a-z_][a-z0-9_]*$/.test(role)) throw new Error('Application database role must be a simple identifier');
    const grant = async schema => {
      await client.query(`GRANT USAGE ON SCHEMA ${schema} TO "${role}"`);
      await client.query(`GRANT SELECT,INSERT,UPDATE,DELETE ON ALL TABLES IN SCHEMA ${schema} TO "${role}"`);
      await client.query(`GRANT USAGE,SELECT ON ALL SEQUENCES IN SCHEMA ${schema} TO "${role}"`);
      await client.query(`REVOKE CREATE ON SCHEMA ${schema} FROM "${role}",PUBLIC`);
    };
    try {
      await client.query('BEGIN');
      await client.query('SELECT pg_advisory_xact_lock(975223104)');
      await client.query(registrySql);
      await grant('registry');
      await client.query(`REVOKE UPDATE,DELETE,TRUNCATE ON registry.audit FROM "${role}"`);
      await client.query(`REVOKE INSERT,UPDATE,DELETE,TRUNCATE ON registry.schema_migrations FROM "${role}"`);
      await client.query("INSERT INTO registry.schema_migrations(scope,version,applied_at) VALUES('registry',1,$1) ON CONFLICT(scope) DO NOTHING", [new Date().toISOString()]);
      await client.query('COMMIT');
      for (const country of requested) {
        const schema = countrySchema(country);
        await client.query('BEGIN');
        await client.query('SELECT pg_advisory_xact_lock(975223104)');
        await client.query(countrySql.replaceAll('__COUNTRY_SCHEMA__', schema));
        await grant(schema);
        await client.query('INSERT INTO registry.schema_migrations(scope,version,applied_at) VALUES($1,1,$2) ON CONFLICT(scope) DO NOTHING', [country, new Date().toISOString()]);
        await client.query('COMMIT');
      }
    } catch (error) {
      await client.query('ROLLBACK').catch(() => {});
      throw error;
    } finally { client.release(); }
    await this.refreshRegions();
    return this;
  }

  /** Create fictional fixtures only on a new demo database, preserving all existing interactive records. */
  async seed() {
    if (!this.settings.demo) throw new Error('Fictional fixtures require explicit demo mode');
    await this.ensureRegion('BD');
    await this.transaction('BD', async db => {
      if (await db.one("SELECT id FROM accounts WHERE id='seeker'")) return;
      const now = new Date().toISOString();
      const fixtures = [
        ['donor', 'Nadia (demo)', 'O+', 165, 62, 23.8103, 90.4125, 1],
        ['seeker', 'Rafi (demo)', 'B+', 175, 73, 23.8110, 90.4130, 0],
        ['admin', 'Community admin (demo)', 'AB+', 170, 65, 23.8103, 90.4125, 0],
        ['donor-two', 'Arif (demo)', 'O+', 178, 78, 23.8203, 90.4225, 1],
        ['donor-three', 'Maya (demo)', 'A+', 162, 56, 23.7913, 90.4035, 1],
        ['reported', 'Reported account (demo)', 'B-', 170, 68, 23.8313, 90.4235, 1],
      ];
      for (const [id, name, group, height, weight, latitude, longitude, available] of fixtures) {
        await db.run('INSERT INTO accounts(id,country,available,role,created_at) VALUES($1,$2,$3,$4,$5)', [id, 'BD', available, id === 'admin' ? 'admin' : 'member', now]);
        await db.run('INSERT INTO profiles(id,display_name,blood_type,height_cm,weight_kg,city,latitude,longitude) VALUES($1,$2,$3,$4,$5,$6,$7,$8)', [id, name, group, height, weight, 'Dhaka', latitude, longitude]);
      }
      await db.run('INSERT INTO conversations VALUES($1,$2,$3,$4)', ['demo-conversation', 'donor', 'seeker', now]);
      await db.run('INSERT INTO messages VALUES($1,$2,$3,$4,$5)', ['demo-message', 'demo-conversation', 'donor', 'Hello! This is a fictional demo conversation. Blood donation is always voluntary and free.', now]);
      await db.run('INSERT INTO conversations VALUES($1,$2,$3,$4)', ['demo-report-conversation', 'reported', 'seeker', now]);
      const evidence = [{ sender_id: 'reported', body: 'Fictional report evidence: please send money before I donate.', created_at: now }];
      await db.run('INSERT INTO messages VALUES($1,$2,$3,$4,$5)', ['demo-evidence-message', 'demo-report-conversation', 'reported', evidence[0].body, now]);
      await db.run('INSERT INTO reports(id,reporter_id,reported_id,conversation_id,reason,details,status,evidence,created_at) VALUES($1,$2,$3,$4,$5,$6,$7,$8,$9)', ['demo-report', 'seeker', 'reported', 'demo-report-conversation', 'money_request', 'Fictional sample report for reviewing the admin workflow.', 'pending', JSON.stringify(evidence), now]);
    });
  }

  async resetForTests() {
    // Destructive cleanup is permitted only on an explicitly named test database, through the migration role.
    const appName = decodeURIComponent(new URL(this.settings.databaseUrl).pathname.slice(1));
    const migrationName = this.settings.migrationDatabaseUrl && decodeURIComponent(new URL(this.settings.migrationDatabaseUrl).pathname.slice(1));
    if (!appName.endsWith('_test') || appName !== migrationName) throw new Error('Test reset requires matching *_test database URLs');
    this.migrationPool ??= this.makePool(this.settings.migrationDatabaseUrl);
    const client = await this.migrationPool.connect();
    try {
      await client.query('BEGIN');
      const { rows } = await client.query("SELECT schemaname,tablename FROM pg_catalog.pg_tables WHERE (schemaname='registry' OR schemaname ~ '^country_[a-z]{2}$') AND tablename<>'schema_migrations'");
      const names = rows.map(row => `"${row.schemaname}"."${row.tablename}"`);
      if (names.length) await client.query(`TRUNCATE ${names.join(',')} RESTART IDENTITY CASCADE`);
      await client.query('COMMIT');
    } catch (error) { await client.query('ROLLBACK').catch(() => {}); throw error; }
    finally { client.release(); }
    if (this.settings.demo) await this.seed();
  }

  /** Close both identities' pools so shutdown/tests leave no idle database sessions. */
  async close() {
    await Promise.all([this.pool.end(), this.migrationPool?.end()]);
  }
}
