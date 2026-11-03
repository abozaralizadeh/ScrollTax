export type AppleMode = 'fake' | 'real';

export interface Config {
  host: string;
  port: number;
  sessionSecret: string;
  sessionTtlDays: number;
  dbPath: string;
  backupDir: string;
  logDir: string;
  logMaxBytes: number;
  logLevel: string;
  appleMode: AppleMode;
  appleBundleId: string;
  appleRootCertPath: string;
  appleEnvironment: 'Sandbox' | 'Production';
  productId: string;
  priceMinor: number;
  currency: string;
  unlockMinutes: number;
  dailyUnlockLimit: number;
  leaveWaitHours: number;
  minAge: number;
  termsVersion: string;
  supportEmail: string;
}

function int(env: NodeJS.ProcessEnv, key: string, fallback: number, min = 0): number {
  const raw = env[key];
  if (raw === undefined || raw === '') return fallback;
  const n = Number(raw);
  if (!Number.isInteger(n) || n < min) throw new Error(`${key} must be a whole number of at least ${min}`);
  return n;
}

function str(env: NodeJS.ProcessEnv, key: string, fallback: string): string {
  const raw = env[key];
  return raw === undefined || raw === '' ? fallback : raw;
}

export function loadConfig(env: NodeJS.ProcessEnv = process.env): Config {
  const sessionSecret = str(env, 'SESSION_SECRET', '');
  if (sessionSecret.length < 32) {
    throw new Error('SESSION_SECRET must be at least 32 characters. Try: openssl rand -hex 32');
  }

  const appleMode = str(env, 'APPLE_MODE', 'fake');
  if (appleMode !== 'fake' && appleMode !== 'real') throw new Error('APPLE_MODE must be "fake" or "real"');

  const appleEnvironment = str(env, 'APPLE_ENVIRONMENT', 'Sandbox');
  if (appleEnvironment !== 'Sandbox' && appleEnvironment !== 'Production') {
    throw new Error('APPLE_ENVIRONMENT must be "Sandbox" or "Production"');
  }

  const config: Config = {
    host: str(env, 'HOST', '127.0.0.1'),
    port: int(env, 'PORT', 8787, 1),
    sessionSecret,
    sessionTtlDays: int(env, 'SESSION_TTL_DAYS', 90, 1),
    dbPath: str(env, 'DB_PATH', './data/scrolltax.db'),
    backupDir: str(env, 'BACKUP_DIR', './data/backups'),
    logDir: str(env, 'LOG_DIR', './logs'),
    logMaxBytes: int(env, 'LOG_MAX_BYTES', 25 * 1024 * 1024, 1024),
    logLevel: str(env, 'LOG_LEVEL', 'info'),
    appleMode,
    appleBundleId: str(env, 'APPLE_BUNDLE_ID', 'app.scrolltax'),
    appleRootCertPath: str(env, 'APPLE_ROOT_CERT_PATH', ''),
    appleEnvironment,
    productId: str(env, 'PRODUCT_ID', 'app.scrolltax.unlock15'),
    priceMinor: int(env, 'PRICE_MINOR', 99, 1),
    currency: str(env, 'CURRENCY', 'EUR'),
    unlockMinutes: int(env, 'UNLOCK_MINUTES', 15, 1),
    dailyUnlockLimit: int(env, 'DAILY_UNLOCK_LIMIT', 4, 1),
    leaveWaitHours: int(env, 'LEAVE_WAIT_HOURS', 24, 0),
    minAge: int(env, 'MIN_AGE', 18, 13),
    termsVersion: str(env, 'TERMS_VERSION', '2026-11-draft'),
    supportEmail: str(env, 'SUPPORT_EMAIL', ''),
  };

  if (config.appleMode === 'real' && !config.appleRootCertPath) {
    throw new Error('APPLE_ROOT_CERT_PATH is required when APPLE_MODE=real');
  }
  return config;
}
