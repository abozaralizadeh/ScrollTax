import { X509Certificate, createPublicKey, verify } from 'node:crypto';
import { readFileSync } from 'node:fs';

export interface TransactionInfo {
  transactionId: string;
  originalTransactionId: string;
  productId: string;
  bundleId: string;
  /** Milliseconds since 1970 */
  purchaseDate: number;
  environment: 'Sandbox' | 'Production';
  /** Price in thousandths of the currency, when Apple includes it */
  priceMilli?: number;
  currency?: string;
}

export interface NotificationInfo {
  type: string;
  subtype?: string;
  transaction?: TransactionInfo;
}

/**
 * Everything we need from Apple, in one place. The real version checks
 * signatures. The fake one accepts made up tokens so everything else can be
 * built and tested without an Apple account.
 */
export interface AppleServices {
  verifyIdentityToken(token: string): Promise<{ sub: string }>;
  verifyTransaction(signed: string): Promise<TransactionInfo>;
  verifyNotification(signed: string): Promise<NotificationInfo>;
  /** Called when an account is deleted. */
  revokeSignIn(sub: string): Promise<void>;
}

export class AppleError extends Error {}

// ---------- fake (local work and tests) ----------

const FAKE_ID_PREFIX = 'fake-user:';
const FAKE_TXN_PREFIX = 'fake-txn.';
const FAKE_NOTE_PREFIX = 'fake-notif.';

export function fakeIdentityToken(userId: string): string {
  return `${FAKE_ID_PREFIX}${userId}`;
}

export function fakeSignedTransaction(info: Partial<TransactionInfo> & { transactionId: string }): string {
  const full: TransactionInfo = {
    originalTransactionId: info.transactionId,
    productId: 'app.scrolltax.unlock15',
    bundleId: 'app.scrolltax',
    purchaseDate: Date.now(),
    environment: 'Sandbox',
    ...info,
  };
  return FAKE_TXN_PREFIX + Buffer.from(JSON.stringify(full)).toString('base64url');
}

export function fakeSignedNotification(type: string, transaction?: TransactionInfo, subtype?: string): string {
  return FAKE_NOTE_PREFIX + Buffer.from(JSON.stringify({ type, subtype, transaction })).toString('base64url');
}

function fakeDecode<T>(prefix: string, value: string): T {
  if (!value.startsWith(prefix)) throw new AppleError('not a fake token');
  try {
    return JSON.parse(Buffer.from(value.slice(prefix.length), 'base64url').toString('utf8')) as T;
  } catch {
    throw new AppleError('bad fake token');
  }
}

export class FakeApple implements AppleServices {
  revoked: string[] = [];

  async verifyIdentityToken(token: string): Promise<{ sub: string }> {
    if (!token.startsWith(FAKE_ID_PREFIX) || token.length === FAKE_ID_PREFIX.length) {
      throw new AppleError('bad identity token');
    }
    return { sub: token.slice(FAKE_ID_PREFIX.length) };
  }

  async verifyTransaction(signed: string): Promise<TransactionInfo> {
    return fakeDecode<TransactionInfo>(FAKE_TXN_PREFIX, signed);
  }

  async verifyNotification(signed: string): Promise<NotificationInfo> {
    return fakeDecode<NotificationInfo>(FAKE_NOTE_PREFIX, signed);
  }

  async revokeSignIn(sub: string): Promise<void> {
    this.revoked.push(sub);
  }
}

// ---------- real (signature checks) ----------

function parseJws(jws: string) {
  const parts = jws.split('.');
  if (parts.length !== 3) throw new AppleError('not a JWS');
  const [h, p, s] = parts as [string, string, string];
  try {
    return {
      header: JSON.parse(Buffer.from(h, 'base64url').toString('utf8')) as Record<string, unknown>,
      payload: JSON.parse(Buffer.from(p, 'base64url').toString('utf8')) as Record<string, unknown>,
      input: Buffer.from(`${h}.${p}`),
      signature: Buffer.from(s, 'base64url'),
    };
  } catch {
    throw new AppleError('unreadable JWS');
  }
}

/**
 * Checks a JWS signed the way App Store Server messages are: ES256 with the
 * certificate chain in the x5c header, ending at a root we trust.
 */
export function verifyX5cJws(jws: string, rootPem: string, now = new Date()): Record<string, unknown> {
  const { header, payload, input, signature } = parseJws(jws);
  if (header['alg'] !== 'ES256') throw new AppleError('unexpected algorithm');
  const x5c = header['x5c'];
  if (!Array.isArray(x5c) || x5c.length === 0) throw new AppleError('missing certificate chain');

  let chain: X509Certificate[];
  try {
    chain = x5c.map((c) => new X509Certificate(Buffer.from(String(c), 'base64')));
  } catch {
    throw new AppleError('bad certificate chain');
  }
  const root = new X509Certificate(rootPem);

  for (let i = 0; i < chain.length; i++) {
    const cert = chain[i]!;
    const issuer = chain[i + 1] ?? root;
    if (!cert.checkIssued(issuer) || !cert.verify(issuer.publicKey)) {
      throw new AppleError('certificate chain does not lead to the trusted root');
    }
    if (now < new Date(cert.validFrom) || now > new Date(cert.validTo)) {
      throw new AppleError('certificate expired or not valid yet');
    }
  }

  const ok = verify('sha256', input, { key: chain[0]!.publicKey, dsaEncoding: 'ieee-p1363' }, signature);
  if (!ok) throw new AppleError('bad signature');
  return payload;
}

type Jwk = { kid?: string; kty: string; n?: string; e?: string };

export interface RealAppleOptions {
  bundleId: string;
  environment: 'Sandbox' | 'Production';
  rootCertPem: string;
  /** Replaceable so tests don't touch the network */
  fetchJwks?: () => Promise<Jwk[]>;
  now?: () => Date;
  warn?: (msg: string) => void;
}

const APPLE_ISSUER = 'https://appleid.apple.com';

function toTransaction(payload: Record<string, unknown>): TransactionInfo {
  const info: TransactionInfo = {
    transactionId: String(payload['transactionId'] ?? ''),
    originalTransactionId: String(payload['originalTransactionId'] ?? payload['transactionId'] ?? ''),
    productId: String(payload['productId'] ?? ''),
    bundleId: String(payload['bundleId'] ?? ''),
    purchaseDate: Number(payload['purchaseDate']),
    environment: payload['environment'] === 'Production' ? 'Production' : 'Sandbox',
  };
  if (typeof payload['price'] === 'number') info.priceMilli = payload['price'];
  if (typeof payload['currency'] === 'string') info.currency = payload['currency'];
  if (!info.transactionId || !info.productId || !Number.isFinite(info.purchaseDate)) {
    throw new AppleError('transaction is missing fields');
  }
  return info;
}

export class RealApple implements AppleServices {
  private readonly opts: RealAppleOptions;
  private jwks: { keys: Jwk[]; at: number } | null = null;

  constructor(opts: RealAppleOptions) {
    this.opts = opts;
  }

  private now(): Date {
    return this.opts.now ? this.opts.now() : new Date();
  }

  private async keys(): Promise<Jwk[]> {
    if (this.jwks && Date.now() - this.jwks.at < 60 * 60 * 1000) return this.jwks.keys;
    const fetchJwks =
      this.opts.fetchJwks ??
      (async () => {
        const res = await fetch(`${APPLE_ISSUER}/auth/keys`);
        if (!res.ok) throw new AppleError(`Apple keys request failed (${res.status})`);
        return ((await res.json()) as { keys: Jwk[] }).keys;
      });
    const keys = await fetchJwks();
    this.jwks = { keys, at: Date.now() };
    return keys;
  }

  async verifyIdentityToken(token: string): Promise<{ sub: string }> {
    const { header, payload, input, signature } = parseJws(token);
    if (header['alg'] !== 'RS256') throw new AppleError('unexpected algorithm');
    const jwk = (await this.keys()).find((k) => k.kid === header['kid']);
    if (!jwk) throw new AppleError('unknown signing key');
    const key = createPublicKey({ key: jwk as never, format: 'jwk' });
    if (!verify('RSA-SHA256', input, key, signature)) throw new AppleError('bad signature');
    if (payload['iss'] !== APPLE_ISSUER) throw new AppleError('wrong issuer');
    if (payload['aud'] !== this.opts.bundleId) throw new AppleError('wrong audience');
    if (typeof payload['exp'] !== 'number' || payload['exp'] * 1000 < this.now().getTime()) {
      throw new AppleError('token expired');
    }
    if (typeof payload['sub'] !== 'string' || !payload['sub']) throw new AppleError('missing subject');
    return { sub: payload['sub'] };
  }

  private checkTransaction(info: TransactionInfo): TransactionInfo {
    if (info.bundleId !== this.opts.bundleId) throw new AppleError('transaction is for another app');
    if (info.environment !== this.opts.environment) {
      throw new AppleError(`only ${this.opts.environment} transactions are accepted`);
    }
    return info;
  }

  async verifyTransaction(signed: string): Promise<TransactionInfo> {
    const payload = verifyX5cJws(signed, this.opts.rootCertPem, this.now());
    return this.checkTransaction(toTransaction(payload));
  }

  async verifyNotification(signed: string): Promise<NotificationInfo> {
    const payload = verifyX5cJws(signed, this.opts.rootCertPem, this.now());
    const data = (payload['data'] ?? {}) as Record<string, unknown>;
    const out: NotificationInfo = { type: String(payload['notificationType'] ?? '') };
    if (typeof payload['subtype'] === 'string') out.subtype = payload['subtype'];
    if (typeof data['signedTransactionInfo'] === 'string') {
      out.transaction = this.checkTransaction(
        toTransaction(verifyX5cJws(data['signedTransactionInfo'], this.opts.rootCertPem, this.now())),
      );
    }
    return out;
  }

  async revokeSignIn(_sub: string): Promise<void> {
    // Revoking needs an Apple signing key and the sign in authorization code,
    // which come from an Apple developer account. Not built yet.
    this.opts.warn?.('Sign in with Apple revoke skipped: not set up yet');
  }
}

export function loadRootCert(path: string): string {
  return readFileSync(path, 'utf8');
}
