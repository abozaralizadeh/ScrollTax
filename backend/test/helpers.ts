import { execFileSync } from 'node:child_process';
import { mkdtempSync, readFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { createSign, generateKeyPairSync, sign } from 'node:crypto';
import { buildApp } from '../src/app.ts';
import { FakeApple, fakeIdentityToken, fakeSignedTransaction } from '../src/apple.ts';
import type { TransactionInfo } from '../src/apple.ts';
import { loadConfig } from '../src/config.ts';
import type { Config } from '../src/config.ts';
import { Store } from '../src/store.ts';

export const SECRET = 'x'.repeat(40);

export function testConfig(extra: Record<string, string> = {}): Config {
  return loadConfig({ SESSION_SECRET: SECRET, ...extra });
}

export function makeHarness(extra: Record<string, string> = {}, start = '2026-11-02T10:00:00Z') {
  const clock = { at: new Date(start) };
  const store = new Store(':memory:');
  const apple = new FakeApple();
  const config = testConfig(extra);
  const app = buildApp({ config, store, apple, now: () => clock.at, webDir: join(import.meta.dirname, '..', '..', 'web') });

  async function signIn(name = 'alice', opts: { ageConfirmed?: boolean; termsVersion?: string } = {}) {
    const res = await app.inject({
      method: 'POST',
      url: '/v1/auth/apple',
      payload: {
        identityToken: fakeIdentityToken(name),
        ageConfirmed: opts.ageConfirmed ?? true,
        termsVersion: opts.termsVersion ?? config.termsVersion,
      },
    });
    return { res, token: res.statusCode === 200 ? (res.json().token as string) : '' };
  }

  function auth(token: string) {
    return { authorization: `Bearer ${token}` };
  }

  function txn(id: string, extra: Partial<TransactionInfo> = {}) {
    return fakeSignedTransaction({ transactionId: id, purchaseDate: clock.at.getTime(), ...extra });
  }

  async function pay(token: string, id: string, extra: Partial<TransactionInfo> = {}, timeZone = 'Europe/Rome') {
    return app.inject({
      method: 'POST',
      url: '/v1/payments',
      headers: auth(token),
      payload: { signedTransaction: txn(id, extra), timeZone },
    });
  }

  return { app, store, apple, config, clock, signIn, auth, txn, pay };
}

// ---- a throwaway certificate chain, made with openssl, for the signature tests ----

export interface TestChain {
  rootPem: string;
  /** base64 DER of the leaf and root, as they would appear in an x5c header */
  x5c: string[];
  leafKeyPem: string;
}

export function makeChain(): TestChain {
  const dir = mkdtempSync(join(tmpdir(), 'scrolltax-chain-'));
  const run = (...args: string[]) => execFileSync('openssl', args, { cwd: dir, stdio: 'pipe' });
  run('ecparam', '-name', 'prime256v1', '-genkey', '-noout', '-out', 'root.key');
  run('req', '-x509', '-new', '-key', 'root.key', '-sha256', '-days', '30', '-subj', '/CN=Test Root',
    '-addext', 'basicConstraints=critical,CA:TRUE', '-out', 'root.pem');
  run('ecparam', '-name', 'prime256v1', '-genkey', '-noout', '-out', 'leaf.key');
  run('req', '-new', '-key', 'leaf.key', '-subj', '/CN=Test Leaf', '-out', 'leaf.csr');
  run('x509', '-req', '-in', 'leaf.csr', '-CA', 'root.pem', '-CAkey', 'root.key', '-CAcreateserial',
    '-days', '30', '-sha256', '-out', 'leaf.pem');
  const der = (file: string) => run('x509', '-in', file, '-outform', 'DER').toString('base64');
  return {
    rootPem: readFileSync(join(dir, 'root.pem'), 'utf8'),
    x5c: [der('leaf.pem'), der('root.pem')],
    leafKeyPem: readFileSync(join(dir, 'leaf.key'), 'utf8'),
  };
}

const b64u = (v: unknown) => Buffer.from(JSON.stringify(v)).toString('base64url');

export function signEs256(chain: TestChain, payload: unknown, x5c = chain.x5c.slice(0, 1)): string {
  const head = b64u({ alg: 'ES256', x5c });
  const body = b64u(payload);
  const sig = sign('sha256', Buffer.from(`${head}.${body}`), { key: chain.leafKeyPem, dsaEncoding: 'ieee-p1363' });
  return `${head}.${body}.${sig.toString('base64url')}`;
}

export function makeIdentityKey() {
  const { publicKey, privateKey } = generateKeyPairSync('rsa', { modulusLength: 2048 });
  const jwk = { ...publicKey.export({ format: 'jwk' }), kid: 'test-key', alg: 'RS256', use: 'sig' };
  const make = (claims: Record<string, unknown>, kid = 'test-key') => {
    const head = b64u({ alg: 'RS256', kid });
    const body = b64u(claims);
    const signer = createSign('RSA-SHA256').update(`${head}.${body}`);
    return `${head}.${body}.${signer.sign(privateKey).toString('base64url')}`;
  };
  return { jwk, make };
}
