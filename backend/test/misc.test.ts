import { test } from 'node:test';
import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { existsSync, mkdirSync, mkdtempSync, readFileSync, readdirSync, statSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { loadConfig } from '../src/config.ts';
import { RotatingLog } from '../src/rotating-log.ts';
import { readSession, signSession } from '../src/session.ts';
import { Store } from '../src/store.ts';
import { isTimeZone, localDay } from '../src/days.ts';
import { SECRET } from './helpers.ts';

const tmp = () => mkdtempSync(join(tmpdir(), 'scrolltax-test-'));

test('config refuses a weak secret and bad numbers', () => {
  assert.throws(() => loadConfig({}), /SESSION_SECRET/);
  assert.throws(() => loadConfig({ SESSION_SECRET: 'short' }), /SESSION_SECRET/);
  assert.throws(() => loadConfig({ SESSION_SECRET: SECRET, PRICE_MINOR: 'abc' }), /PRICE_MINOR/);
  assert.throws(() => loadConfig({ SESSION_SECRET: SECRET, MIN_AGE: '12' }), /MIN_AGE/);
  assert.throws(() => loadConfig({ SESSION_SECRET: SECRET, APPLE_MODE: 'maybe' }), /APPLE_MODE/);
});

test('real Apple mode needs a root certificate, and defaults stay on the sandbox', () => {
  assert.throws(() => loadConfig({ SESSION_SECRET: SECRET, APPLE_MODE: 'real' }), /APPLE_ROOT_CERT_PATH/);
  const c = loadConfig({ SESSION_SECRET: SECRET });
  assert.equal(c.appleMode, 'fake');
  assert.equal(c.appleEnvironment, 'Sandbox');
});

test('sessions round trip, expire, and reject tampering', () => {
  const now = new Date('2026-11-02T00:00:00Z');
  const token = signSession('u1', SECRET, 1, now);
  assert.equal(readSession(token, SECRET, now), 'u1');
  assert.equal(readSession(token, SECRET, new Date(now.getTime() + 2 * 86400_000)), null);
  assert.equal(readSession(token, 'y'.repeat(40), now), null);
  const [body, mac] = token.split('.');
  const forged = Buffer.from(JSON.stringify({ uid: 'u2', exp: 9999999999 })).toString('base64url');
  assert.notEqual(forged, body);
  assert.equal(readSession(`${forged}.${mac}`, SECRET, now), null);
  assert.equal(readSession('nonsense', SECRET, now), null);
});

test('days follow the person\'s time zone', () => {
  const t = new Date('2026-11-02T23:30:00Z');
  assert.equal(localDay(t, 'UTC'), '2026-11-02');
  assert.equal(localDay(t, 'Europe/Rome'), '2026-11-03');
  assert.equal(localDay(t, 'America/Los_Angeles'), '2026-11-02');
  assert.ok(isTimeZone('Asia/Tokyo'));
  assert.ok(!isTimeZone('Nowhere/Land'));
});

test('the log file never grows past its cap', () => {
  const dir = tmp();
  const log = new RotatingLog(dir, 1000);
  const line = 'x'.repeat(99) + '\n';
  for (let i = 0; i < 200; i++) log.write(line);
  const files = readdirSync(dir).sort();
  assert.deepEqual(files, ['scrolltax.log', 'scrolltax.log.1']);
  for (const f of files) assert.ok(statSync(join(dir, f)).size <= 1000, f);
  assert.ok(readFileSync(join(dir, 'scrolltax.log'), 'utf8').endsWith(line));
});

test('the log picks up where it left off after a restart', () => {
  const dir = tmp();
  const a = new RotatingLog(dir, 500);
  a.write('y'.repeat(400));
  const b = new RotatingLog(dir, 500);
  b.write('z'.repeat(400));
  assert.ok(existsSync(join(dir, 'scrolltax.log.1')));
  assert.equal(readFileSync(join(dir, 'scrolltax.log'), 'utf8'), 'z'.repeat(400));
});

test('a backup is a working copy of the database', () => {
  const dir = tmp();
  const store = new Store(join(dir, 'live.db'));
  const user = store.createUser('apple-1', 'v1', new Date());
  const file = join(dir, 'copy.db');
  store.backupTo(file);
  store.close();
  const copy = new Store(file);
  assert.equal(copy.userById(user.id)?.apple_user_id, 'apple-1');
  copy.close();
});

test('the backup script writes a file and keeps only the latest 14', () => {
  const dir = tmp();
  const dbPath = join(dir, 'live.db');
  new Store(dbPath).close();
  const backups = join(dir, 'backups');
  // 16 old files, which the script should trim to leave 14 including today's
  mkdirSync(backups);
  for (let i = 1; i <= 16; i++) writeFileSync(join(backups, `scrolltax-2020-01-${String(i).padStart(2, '0')}.db`), 'old');
  execFileSync('node', [join(import.meta.dirname, '..', 'scripts', 'backup.ts')], {
    env: { ...process.env, SESSION_SECRET: SECRET, DB_PATH: dbPath, BACKUP_DIR: backups },
    stdio: 'pipe',
  });
  const left = readdirSync(backups).sort();
  assert.equal(left.length, 14);
  assert.match(left.at(-1)!, /^scrolltax-202[6-9]/);
  assert.ok(!left.includes('scrolltax-2020-01-01.db'));
});
