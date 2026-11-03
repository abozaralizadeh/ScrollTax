import { mkdirSync } from 'node:fs';
import { dirname } from 'node:path';
import { buildApp } from './app.ts';
import { FakeApple, RealApple, loadRootCert } from './apple.ts';
import type { AppleServices } from './apple.ts';
import { loadConfig } from './config.ts';
import { RotatingLog, logStream } from './rotating-log.ts';
import { Store } from './store.ts';

const config = loadConfig();
mkdirSync(dirname(config.dbPath), { recursive: true });

let apple: AppleServices;
if (config.appleMode === 'real') {
  apple = new RealApple({
    bundleId: config.appleBundleId,
    environment: config.appleEnvironment,
    rootCertPem: loadRootCert(config.appleRootCertPath),
    warn: (m) => console.warn(m),
  });
} else {
  console.warn('APPLE_MODE=fake: made up tokens are accepted. Never run this in public.');
  apple = new FakeApple();
}

const app = buildApp({
  config,
  store: new Store(config.dbPath),
  apple,
  logStream: logStream(new RotatingLog(config.logDir, config.logMaxBytes)),
});

for (const signal of ['SIGINT', 'SIGTERM'] as const) {
  process.on(signal, () => {
    app.close().finally(() => process.exit(0));
  });
}

await app.listen({ host: config.host, port: config.port });
