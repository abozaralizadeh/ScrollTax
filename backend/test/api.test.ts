import { test } from 'node:test';
import assert from 'node:assert/strict';
import { fakeIdentityToken, fakeSignedNotification } from '../src/apple.ts';
import { makeHarness } from './helpers.ts';

test('health check and public config', async () => {
  const h = makeHarness();
  assert.deepEqual((await h.app.inject('/healthz')).json(), { ok: true });
  const cfg = (await h.app.inject('/v1/config')).json();
  assert.equal(cfg.priceMinor, 99);
  assert.equal(cfg.unlockMinutes, 15);
  assert.equal(cfg.dailyUnlockLimit, 4);
  assert.equal(cfg.leaveWaitHours, 24);
  assert.equal(cfg.minAge, 18);
});

test('proposed answers can be changed from the environment', async () => {
  const h = makeHarness({ PRICE_MINOR: '199', UNLOCK_MINUTES: '30', DAILY_UNLOCK_LIMIT: '2', LEAVE_WAIT_HOURS: '48' });
  const cfg = (await h.app.inject('/v1/config')).json();
  assert.deepEqual([cfg.priceMinor, cfg.unlockMinutes, cfg.dailyUnlockLimit, cfg.leaveWaitHours], [199, 30, 2, 48]);
});

test('registering needs the age box and the current terms', async () => {
  const h = makeHarness();
  const noAge = await h.signIn('a', { ageConfirmed: false });
  assert.equal(noAge.res.statusCode, 400);
  assert.equal(noAge.res.json().error, 'age_not_confirmed');
  const oldTerms = await h.signIn('a', { termsVersion: 'old' });
  assert.equal(oldTerms.res.json().error, 'terms_not_accepted');
  const ok = await h.signIn('a');
  assert.equal(ok.res.statusCode, 200);
  assert.equal(ok.res.json().created, true);
});

test('signing in again finds the same account and needs no extra boxes', async () => {
  const h = makeHarness();
  const first = (await h.signIn('a')).res.json();
  const again = await h.app.inject({
    method: 'POST',
    url: '/v1/auth/apple',
    payload: { identityToken: fakeIdentityToken('a') },
  });
  assert.equal(again.statusCode, 200);
  assert.equal(again.json().created, false);
  assert.equal(again.json().user.id, first.user.id);
});

test('a bad Apple token is refused', async () => {
  const h = makeHarness();
  const res = await h.app.inject({ method: 'POST', url: '/v1/auth/apple', payload: { identityToken: 'nope' } });
  assert.equal(res.statusCode, 401);
});

test('routes that need an account refuse strangers and bad tokens', async () => {
  const h = makeHarness();
  for (const [method, url] of [['GET', '/v1/me'], ['GET', '/v1/payments'], ['POST', '/v1/leave'], ['DELETE', '/v1/me']] as const) {
    assert.equal((await h.app.inject({ method, url })).statusCode, 401, `${method} ${url}`);
  }
  const res = await h.app.inject({ method: 'GET', url: '/v1/me', headers: h.auth('garbage.token') });
  assert.equal(res.statusCode, 401);
});

test('an expired session stops working', async () => {
  const h = makeHarness();
  const { token } = await h.signIn();
  assert.equal((await h.app.inject({ url: '/v1/me', headers: h.auth(token) })).statusCode, 200);
  h.clock.at = new Date(h.clock.at.getTime() + 91 * 86400_000);
  assert.equal((await h.app.inject({ url: '/v1/me', headers: h.auth(token) })).statusCode, 401);
});

test('a payment makes an unlock that ends after the set minutes', async () => {
  const h = makeHarness();
  const { token } = await h.signIn();
  const res = await h.pay(token, 't1');
  assert.equal(res.statusCode, 201);
  const body = res.json();
  assert.equal(body.overLimit, false);
  assert.equal(body.payment.status, 'paid');
  assert.equal(body.payment.amountMinor, 99);
  const started = Date.parse(body.payment.unlock.startedAt);
  assert.equal(Date.parse(body.payment.unlock.endsAt) - started, 15 * 60_000);
});

test('sending the same purchase twice changes nothing', async () => {
  const h = makeHarness();
  const { token } = await h.signIn();
  await h.pay(token, 't1');
  const again = await h.pay(token, 't1');
  assert.equal(again.statusCode, 200);
  assert.equal(again.json().duplicate, true);
  const list = (await h.app.inject({ url: '/v1/payments', headers: h.auth(token) })).json();
  assert.equal(list.payments.length, 1);
});

test('someone else cannot claim a purchase', async () => {
  const h = makeHarness();
  const a = await h.signIn('a');
  const b = await h.signIn('b');
  await h.pay(a.token, 't1');
  const res = await h.pay(b.token, 't1');
  assert.equal(res.statusCode, 409);
});

test('wrong product, junk transactions and bad time zones are refused', async () => {
  const h = makeHarness();
  const { token } = await h.signIn();
  assert.equal((await h.pay(token, 't1', { productId: 'other' })).statusCode, 422);
  const junk = await h.app.inject({
    method: 'POST', url: '/v1/payments', headers: h.auth(token),
    payload: { signedTransaction: 'junk', timeZone: 'Europe/Rome' },
  });
  assert.equal(junk.statusCode, 422);
  const tz = await h.pay(token, 't2', {}, 'Mars/Olympus');
  assert.equal(tz.statusCode, 400);
});

test('the fifth unlock in a day is recorded but gives no time', async () => {
  const h = makeHarness();
  const { token } = await h.signIn();
  for (let i = 1; i <= 4; i++) assert.equal((await h.pay(token, `t${i}`)).json().overLimit, false);
  const fifth = await h.pay(token, 't5');
  assert.equal(fifth.statusCode, 201);
  assert.equal(fifth.json().overLimit, true);
  assert.equal(fifth.json().payment.unlock, null);
  const me = (await h.app.inject({ url: '/v1/me?tz=Europe/Rome', headers: h.auth(token) })).json();
  assert.deepEqual(me.today, { unlocksUsed: 4, limit: 4 });
});

test('the daily count resets at midnight in the person\'s own time zone', async () => {
  // 22:30 UTC on 2 Nov is 23:30 in Rome and 07:30 on 3 Nov in Tokyo.
  const h = makeHarness({}, '2026-11-02T22:30:00Z');
  const { token } = await h.signIn();
  for (let i = 1; i <= 4; i++) await h.pay(token, `t${i}`, {}, 'Europe/Rome');
  const same = await h.app.inject({ url: '/v1/me?tz=Europe/Rome', headers: h.auth(token) });
  assert.equal(same.json().today.unlocksUsed, 4);
  // An hour later it is a new day in Rome.
  h.clock.at = new Date('2026-11-02T23:30:00Z');
  const next = await h.app.inject({ url: '/v1/me?tz=Europe/Rome', headers: h.auth(token) });
  assert.equal(next.json().today.unlocksUsed, 0);
  const fresh = await h.pay(token, 't9', {}, 'Europe/Rome');
  assert.equal(fresh.json().overLimit, false);
});

test('a refund notice marks the payment refunded and keeps the unlock that was used', async () => {
  const h = makeHarness();
  const { token } = await h.signIn();
  await h.pay(token, 't1');
  const info = { transactionId: 't1', originalTransactionId: 't1', productId: h.config.productId, bundleId: 'x', purchaseDate: 0, environment: 'Sandbox' as const };
  const res = await h.app.inject({
    method: 'POST', url: '/v1/apple/notifications',
    payload: { signedPayload: fakeSignedNotification('REFUND', info) },
  });
  assert.equal(res.statusCode, 200);
  const p = (await h.app.inject({ url: '/v1/payments', headers: h.auth(token) })).json().payments[0];
  assert.equal(p.status, 'refunded');
  assert.ok(p.refundedAt);
  assert.ok(p.unlock);
});

test('a refund that arrives before the payment is applied when the payment shows up', async () => {
  const h = makeHarness();
  const { token } = await h.signIn();
  const info = { transactionId: 't1', originalTransactionId: 't1', productId: h.config.productId, bundleId: 'x', purchaseDate: 0, environment: 'Sandbox' as const };
  await h.app.inject({ method: 'POST', url: '/v1/apple/notifications', payload: { signedPayload: fakeSignedNotification('REFUND', info) } });
  const res = await h.pay(token, 't1');
  assert.equal(res.json().payment.status, 'refunded');
});

test('other notification types are accepted and ignored, junk is refused', async () => {
  const h = makeHarness();
  const ok = await h.app.inject({ method: 'POST', url: '/v1/apple/notifications', payload: { signedPayload: fakeSignedNotification('TEST') } });
  assert.equal(ok.statusCode, 200);
  const junk = await h.app.inject({ method: 'POST', url: '/v1/apple/notifications', payload: { signedPayload: 'junk' } });
  assert.equal(junk.statusCode, 400);
});

test('leaving: starts a wait, can be cancelled, and completes after the wait', async () => {
  const h = makeHarness();
  const { token } = await h.signIn();
  assert.equal((await h.app.inject({ url: '/v1/me', headers: h.auth(token) })).json().leave.requestedAt, null);

  const start = (await h.app.inject({ method: 'POST', url: '/v1/leave', headers: h.auth(token) })).json();
  assert.equal(start.complete, false);
  assert.equal(Date.parse(start.effectiveAt) - Date.parse(start.requestedAt), 24 * 3600_000);

  // asking again does not push the date back
  h.clock.at = new Date(h.clock.at.getTime() + 3600_000);
  const again = (await h.app.inject({ method: 'POST', url: '/v1/leave', headers: h.auth(token) })).json();
  assert.equal(again.requestedAt, start.requestedAt);

  const cancel = (await h.app.inject({ method: 'DELETE', url: '/v1/leave', headers: h.auth(token) })).json();
  assert.equal(cancel.requestedAt, null);

  await h.app.inject({ method: 'POST', url: '/v1/leave', headers: h.auth(token) });
  h.clock.at = new Date(h.clock.at.getTime() + 25 * 3600_000);
  assert.equal((await h.app.inject({ url: '/v1/me', headers: h.auth(token) })).json().leave.complete, true);
});

test('deleting an account removes the person but keeps payment records without a link', async () => {
  const h = makeHarness();
  const { token } = await h.signIn('alice');
  await h.pay(token, 't1');
  const del = await h.app.inject({ method: 'DELETE', url: '/v1/me', headers: h.auth(token) });
  assert.equal(del.statusCode, 204);
  assert.deepEqual(h.apple.revoked, ['alice']);

  assert.equal((await h.app.inject({ url: '/v1/me', headers: h.auth(token) })).statusCode, 401);
  const users = h.store.db.prepare('SELECT COUNT(*) AS n FROM users').get() as { n: number };
  const unlocks = h.store.db.prepare('SELECT COUNT(*) AS n FROM unlocks').get() as { n: number };
  const pay = h.store.db.prepare('SELECT user_id FROM payments').get() as { user_id: string | null };
  assert.equal(users.n, 0);
  assert.equal(unlocks.n, 0);
  assert.equal(pay.user_id, null);

  // the same Apple account can register again and starts fresh
  const back = await h.signIn('alice');
  assert.equal(back.res.json().created, true);
  assert.deepEqual((await h.app.inject({ url: '/v1/payments', headers: h.auth(back.token) })).json().payments, []);
});

test('legal pages are served with the current terms version filled in', async () => {
  const h = makeHarness();
  const res = await h.app.inject('/legal/privacy');
  assert.equal(res.statusCode, 200);
  assert.match(res.headers['content-type'] as string, /text\/html/);
  assert.match(res.body, /2026-11-draft/);
  assert.equal((await h.app.inject('/legal/nothing')).statusCode, 404);
});

test('bad bodies get a clear 400', async () => {
  const h = makeHarness();
  const res = await h.app.inject({ method: 'POST', url: '/v1/auth/apple', payload: [] });
  assert.equal(res.statusCode, 400);
  const empty = await h.app.inject({ method: 'POST', url: '/v1/auth/apple', payload: {} });
  assert.equal(empty.statusCode, 400);
});
