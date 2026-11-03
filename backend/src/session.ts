import { createHmac, timingSafeEqual } from 'node:crypto';

/** A small signed token: base64url(json).base64url(hmac). Enough for one app talking to its own backend. */
export function signSession(userId: string, secret: string, ttlDays: number, now = new Date()): string {
  const body = Buffer.from(
    JSON.stringify({ uid: userId, exp: Math.floor(now.getTime() / 1000) + ttlDays * 86400 }),
  ).toString('base64url');
  const mac = createHmac('sha256', secret).update(body).digest('base64url');
  return `${body}.${mac}`;
}

export function readSession(token: string, secret: string, now = new Date()): string | null {
  const [body, mac] = token.split('.');
  if (!body || !mac) return null;
  const expected = createHmac('sha256', secret).update(body).digest();
  const given = Buffer.from(mac, 'base64url');
  if (given.length !== expected.length || !timingSafeEqual(given, expected)) return null;
  try {
    const { uid, exp } = JSON.parse(Buffer.from(body, 'base64url').toString('utf8')) as { uid: string; exp: number };
    if (typeof uid !== 'string' || typeof exp !== 'number' || exp * 1000 < now.getTime()) return null;
    return uid;
  } catch {
    return null;
  }
}
