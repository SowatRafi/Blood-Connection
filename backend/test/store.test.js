import assert from 'node:assert/strict';
import { before, beforeEach, after, test } from 'node:test';
import { Store, countrySchema } from '../src/store.js';

// Tests use a separate named database; the store refuses destructive reset against the interactive app.
const store = new Store({
  databaseUrl: process.env.TEST_DATABASE_URL || 'postgresql://blood_connection_app:local-development-runtime-only@127.0.0.1:5436/blood_connection_test',
  migrationDatabaseUrl: process.env.TEST_MIGRATION_DATABASE_URL || 'postgresql://blood_connection_migrator:local-development-migration-only@127.0.0.1:5436/blood_connection_test',
  demo: true, countries: new Set(['BD', 'AU']),
});
before(async () => { await store.migrate(['BD', 'AU']); await store.initialize(); });
beforeEach(async () => { await store.resetForTests(); });
after(async () => { await store.close(); });

test('country move and global safety state roll back together on failure', async () => {
  await assert.rejects(store.transaction('BD', async db => {
    const original = await db.one("SELECT * FROM profiles WHERE id='seeker'");
    await db.run(`INSERT INTO ${db.schema('AU')}.profiles(id,display_name,blood_type,height_cm,weight_kg,city,latitude,longitude) VALUES($1,$2,$3,$4,$5,$6,$7,$8)`,
      [original.id, original.display_name, original.blood_type, original.height_cm, original.weight_kg, 'Sydney', -33.8688, 151.2093]);
    await db.run("UPDATE accounts SET country='AU',location_mode='manual' WHERE id='seeker'");
    await db.run("DELETE FROM profiles WHERE id='seeker'");
    throw new Error('simulated transfer failure');
  }), /simulated transfer failure/);
  await store.transaction('BD', async db => {
    assert.equal((await db.one("SELECT country FROM accounts WHERE id='seeker'")).country, 'BD');
    assert.equal((await db.one("SELECT city FROM profiles WHERE id='seeker'")).city, 'Dhaka');
    assert.equal(await db.one(`SELECT id FROM ${db.schema('AU')}.profiles WHERE id='seeker'`), undefined);
  });
});

test('database reservations reject a person matching concurrently in opposite roles', async () => {
  const outcomes = await Promise.allSettled([
    store.transaction('BD', db => db.run('INSERT INTO active_matches(donor_id,requester_id,request_id,country) VALUES($1,$2,$3,$4)', ['donor','seeker','race-a','BD'])),
    store.transaction('BD', db => db.run('INSERT INTO active_matches(donor_id,requester_id,request_id,country) VALUES($1,$2,$3,$4)', ['seeker','donor-two','race-b','BD'])),
  ]);
  assert.equal(outcomes.filter(result => result.status === 'fulfilled').length, 1);
  assert.equal(outcomes.find(result => result.status === 'rejected').reason.code, '23505');
  await store.transaction('BD', async db => {
    assert.equal((await db.all('SELECT * FROM active_matches')).length, 1);
    assert.equal((await db.all('SELECT * FROM match_participants')).length, 2);
    await db.run('DELETE FROM active_matches');
    assert.equal((await db.all('SELECT * FROM match_participants')).length, 0);
  });
});

test('runtime role cannot create tables or rewrite audit evidence', async () => {
  await store.transaction(null, db => db.run('INSERT INTO audit VALUES($1,$2,$3,$4,$5,$6,$7,$8)',
    ['audit-fixture','admin','reported','dismissed','BD','demo-report','Fictional review note',new Date().toISOString()]));
  for (const sql of ["UPDATE audit SET note='rewritten'", 'DELETE FROM audit', 'TRUNCATE audit', 'CREATE TABLE registry.forbidden_table(id text)']) {
    await assert.rejects(store.transaction(null, db => db.run(sql)), error => error.code === '42501');
  }
  assert.equal((await store.transaction(null, db => db.one("SELECT note FROM audit WHERE id='audit-fixture'"))).note, 'Fictional review note');
});

test('geography coordinates support bounded indexed searches and invalid country names are rejected', async () => {
  await store.transaction('BD', async db => {
    const row = await db.one("SELECT public.ST_DWithin(location,public.ST_SetSRID(public.ST_MakePoint($1,$2),4326)::public.geography,$3) AS nearby FROM profiles WHERE id='donor'", [90.413,23.811,1000]);
    assert.equal(row.nearby, true);
    const index = await db.one("SELECT indexdef FROM pg_indexes WHERE schemaname='country_bd' AND indexname='profile_location'");
    assert.match(index.indexdef, /USING gist \(location\)/);
  });
  for (const country of ['ZZ', 'bd', 'BD;DROP SCHEMA registry', null]) assert.throws(() => countrySchema(country));
  const interactive = new Store({ databaseUrl: 'postgresql://example@127.0.0.1/blood_connection', migrationDatabaseUrl: 'postgresql://example@127.0.0.1/blood_connection' });
  try { await assert.rejects(interactive.resetForTests(), /matching \*_test/); }
  finally { await interactive.close(); }
});
