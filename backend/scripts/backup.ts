import { mkdirSync, readdirSync, rmSync } from 'node:fs';
import { join } from 'node:path';
import { loadConfig } from '../src/config.ts';
import { Store } from '../src/store.ts';

const KEEP = 14;
const config = loadConfig();
mkdirSync(config.backupDir, { recursive: true });

const stamp = new Date().toISOString().slice(0, 10);
const file = join(config.backupDir, `scrolltax-${stamp}.db`);
rmSync(file, { force: true });

const store = new Store(config.dbPath);
store.backupTo(file);
store.close();
console.log(`backup written: ${file}`);

const old = readdirSync(config.backupDir)
  .filter((f) => /^scrolltax-\d{4}-\d{2}-\d{2}\.db$/.test(f))
  .sort()
  .slice(0, -KEEP);
for (const f of old) rmSync(join(config.backupDir, f));
if (old.length) console.log(`removed ${old.length} old backup(s)`);
