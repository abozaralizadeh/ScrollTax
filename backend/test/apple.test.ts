import { test } from 'node:test';
import assert from 'node:assert/strict';
import { RealApple, verifyX5cJws } from '../src/apple.ts';
import { makeChain, makeIdentityKey, signEs256 } from './helpers.ts';

const chain = makeChain();
const now = new Date();

test('a message signed by the leaf of a trusted chain is accepted', () => {
  const jws = signEs256(chain, { hello: 'world' });
  assert.deepEqual(verifyX5cJws(jws, chain.rootPem, now), { hello: 'world' });
});

test('a chain that includes the root itself is accepted too', () => {
  const jws = signEs256(chain, { a: 1 }, chain.x5c);
  assert.ok(verifyX5cJws(jws, chain.rootPem, now));
});

test('a changed payload is refused', () => {
  const [h, , s] = signEs256(chain, { amount: 1 }).split('.');
  const forged = `${h}.${Buffer.from(JSON.stringify({ amount: 1000 })).toString('base64url')}.${s}`;
  assert.throws(() => verifyX5cJws(forged, chain.rootPem, now), /bad signature/);
});

test('a chain from a different root is refused', () => {
  const other = makeChain();
  const jws = signEs256(chain, { a: 1 });
  assert.throws(() => verifyX5cJws(jws, other.rootPem, now), /trusted root/);
});

test('expired certificates are refused', () => {
  const later = new Date(Date.now() + 60 * 86400_000);
  assert.throws(() => verifyX5cJws(signEs256(chain, { a: 1 }), chain.rootPem, later), /expired/);
});

test('other algorithms and missing chains are refused', () => {
  const head = Buffer.from(JSON.stringify({ alg: 'none' })).toString('base64url');
  assert.throws(() => verifyX5cJws(`${head}.e30.`, chain.rootPem), /algorithm|JWS/);
  const noChain = Buffer.from(JSON.stringify({ alg: 'ES256' })).toString('base64url');
  assert.throws(() => verifyX5cJws(`${noChain}.e30.AAAA`, chain.rootPem), /certificate chain/);
  assert.throws(() => verifyX5cJws('not-a-jws', chain.rootPem), /JWS/);
});

function real(extra: Partial<ConstructorParameters<typeof RealApple>[0]> = {}) {
  return new RealApple({ bundleId: 'app.scrolltax', environment: 'Sandbox', rootCertPem: chain.rootPem, now: () => now, ...extra });
}

const goodTxn = {
  transactionId: '100', originalTransactionId: '100', productId: 'app.scrolltax.unlock15',
  bundleId: 'app.scrolltax', purchaseDate: now.getTime(), environment: 'Sandbox', price: 990, currency: 'EUR',
};

test('real transactions are read and checked', async () => {
  const txn = await real().verifyTransaction(signEs256(chain, goodTxn));
  assert.equal(txn.transactionId, '100');
  assert.equal(txn.priceMilli, 990);
  assert.equal(txn.currency, 'EUR');
});

test('production transactions are refused while the project is sandbox only', async () => {
  await assert.rejects(real().verifyTransaction(signEs256(chain, { ...goodTxn, environment: 'Production' })), /Sandbox/);
});

test('transactions for another app are refused', async () => {
  await assert.rejects(real().verifyTransaction(signEs256(chain, { ...goodTxn, bundleId: 'other.app' })), /another app/);
});

test('a refund notification carries its transaction', async () => {
  const note = signEs256(chain, {
    notificationType: 'REFUND',
    data: { signedTransactionInfo: signEs256(chain, goodTxn) },
  });
  const out = await real().verifyNotification(note);
  assert.equal(out.type, 'REFUND');
  assert.equal(out.transaction?.transactionId, '100');
});

test('sign in tokens are checked against Apple\'s published keys', async () => {
  const key = makeIdentityKey();
  const claims = { iss: 'https://appleid.apple.com', aud: 'app.scrolltax', sub: 'user-1', exp: Math.floor(now.getTime() / 1000) + 600 };
  const apple = real({ fetchJwks: async () => [key.jwk as never] });
  assert.deepEqual(await apple.verifyIdentityToken(key.make(claims)), { sub: 'user-1' });
  await assert.rejects(apple.verifyIdentityToken(key.make({ ...claims, aud: 'other' })), /audience/);
  await assert.rejects(apple.verifyIdentityToken(key.make({ ...claims, iss: 'https://evil.example' })), /issuer/);
  await assert.rejects(apple.verifyIdentityToken(key.make({ ...claims, exp: 1 })), /expired/);
  await assert.rejects(apple.verifyIdentityToken(key.make(claims, 'unknown-kid')), /unknown signing key/);

  const other = makeIdentityKey();
  await assert.rejects(apple.verifyIdentityToken(other.make(claims)), /bad signature/);
});
