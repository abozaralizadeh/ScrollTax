import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, readFileSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { buildReport, countLogProblems } from '../src/report.ts';
import { makeHarness } from './helpers.ts';

test('the time endpoint gives the server clock and needs no sign in', async () => {
  const h = makeHarness({}, '2026-11-02T10:00:00Z');
  const res = await h.app.inject('/v1/time');
  assert.equal(res.statusCode, 200);
  assert.deepEqual(res.json(), { now: '2026-11-02T10:00:00.000Z' });
  h.clock.at = new Date('2026-11-02T10:05:00Z');
  assert.equal((await h.app.inject('/v1/time')).json().now, '2026-11-02T10:05:00.000Z');
});

test('/v1/me carries the server time next to the daily count', async () => {
  const h = makeHarness();
  const { token } = await h.signIn();
  await h.pay(token, 't1');
  const me = (await h.app.inject({ url: '/v1/me?tz=Europe/Rome', headers: h.auth(token) })).json();
  assert.equal(me.serverTime, h.clock.at.toISOString());
  assert.deepEqual(me.today, { unlocksUsed: 1, limit: 4 });
});

test('the daily count comes from Apple purchase dates, so a wrong phone clock cannot hide unlocks', async () => {
  const h = makeHarness({ DAILY_UNLOCK_LIMIT: '2' });
  const { token } = await h.signIn();
  await h.pay(token, 'a');
  await h.pay(token, 'b');
  const third = await h.pay(token, 'c');
  assert.equal(third.json().overLimit, true);
  assert.equal(third.json().payment.unlock, null);
  // A phone with its clock moved a day ahead asks for "today" in another time zone and still sees the truth for the real day.
  const me = (await h.app.inject({ url: '/v1/me?tz=Europe/Rome', headers: h.auth(token) })).json();
  assert.equal(me.today.unlocksUsed, 2);
});

test('the data export has the person\'s own records and nobody else\'s', async () => {
  const h = makeHarness();
  const alice = await h.signIn('alice');
  const bob = await h.signIn('bob');
  await h.pay(alice.token, 'a1');
  await h.pay(bob.token, 'bobs-private-txn');
  const res = await h.app.inject({ url: '/v1/me/export', headers: h.auth(alice.token) });
  assert.equal(res.statusCode, 200);
  assert.match(String(res.headers['content-disposition']), /attachment/);
  const out = res.json();
  assert.equal(out.account.appleUserId, 'alice');
  assert.equal(out.account.termsVersion, h.config.termsVersion);
  assert.equal(out.payments.length, 1);
  assert.equal(out.payments[0].transactionId, 'a1');
  assert.ok(out.payments[0].unlock);
  assert.ok(!JSON.stringify(out).includes('bobs-private-txn'));
  assert.equal((await h.app.inject('/v1/me/export')).statusCode, 401);
});

test('the report shows totals and flags paid payments with no unlock', async () => {
  const h = makeHarness({ DAILY_UNLOCK_LIMIT: '1' });
  const { token } = await h.signIn();
  await h.pay(token, 'p1');
  await h.pay(token, 'p2');
  const text = buildReport(h.store, [], new Date('2026-11-02T12:00:00Z'));
  assert.match(text, /People:\s+1/);
  assert.match(text, /Payments:\s+2 \(0 refunded/);
  assert.match(text, /1\.98 EUR/);
  assert.match(text, /Unlocks given:\s+1/);
  assert.match(text, /Look at this: 1 paid payment/);
  assert.ok(!text.includes('alice'));
});

test('the log counter reads warnings and errors from the capped files', () => {
  const dir = mkdtempSync(join(tmpdir(), 'scrolltax-report-'));
  const a = join(dir, 'scrolltax.log');
  const b = join(dir, 'scrolltax.log.1');
  writeFileSync(a, '{"level":30,"msg":"x"}\n{"level":40,"msg":"w"}\n{"level":50,"msg":"e"}\n');
  writeFileSync(b, '{"level":40,"msg":"w"}\n');
  assert.deepEqual(countLogProblems([a, b, join(dir, 'missing.log')]), { warnings: 2, errors: 1 });
});

test('the help page is served, points to a helpline finder and makes no treatment claim', async () => {
  const h = makeHarness();
  const res = await h.app.inject('/legal/help');
  assert.equal(res.statusCode, 200);
  assert.match(res.body, /findahelpline\.com/);
  assert.match(res.body, /not a treatment|isn't a replacement/);
  assert.ok(!/\b(cure|therapy for|treats)\b/i.test(res.body));
  assert.match((await h.app.inject('/legal/support')).body, /\/legal\/help/);
});

test('the data list covers every column', async () => {
  const h = makeHarness();
  const doc = readFileSync(join(import.meta.dirname, '..', '..', 'docs', 'DATA.md'), 'utf8');
  const tables = h.store.db
    .prepare("SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%'")
    .all() as unknown as Array<{ name: string }>;
  assert.ok(tables.length >= 4);
  const missing: string[] = [];
  for (const { name } of tables) {
    const cols = h.store.db.prepare(`PRAGMA table_info(${name})`).all() as unknown as Array<{ name: string }>;
    for (const c of cols) if (!doc.includes(`\`${name}.${c.name}\``)) missing.push(`${name}.${c.name}`);
  }
  assert.deepEqual(missing, []);
});
