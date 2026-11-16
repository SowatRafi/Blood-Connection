import { Store } from '../src/store.js';
import { ISO_COUNTRY_CODES } from '../src/countries.js';

// Provisioning is an explicit operator command, separate from the API's restricted runtime identity.
const demo = process.env.DEMO_MODE === '1';
const countries = (process.env.ENABLED_COUNTRIES ?? '').split(',').map(value => value.trim().toUpperCase()).filter(Boolean);
const settings = {
  databaseUrl: process.env.DATABASE_URL,
  migrationDatabaseUrl: process.env.MIGRATION_DATABASE_URL,
  demo, countries,
};
const store = new Store(settings);
try {
  await store.migrate(countries.length ? countries : demo ? ISO_COUNTRY_CODES : []);
  // Migration never overwrites existing accounts; fixture creation is idempotent and demo-only.
  if (demo && store.countries().includes('BD')) await store.seed();
  console.log(`Database ready: ${store.countries().length} country schemas provisioned.`);
} finally { await store.close(); }
