import { join } from 'node:path';
import { loadConfig } from '../src/config.ts';
import { buildReport } from '../src/report.ts';
import { Store } from '../src/store.ts';

const config = loadConfig();
const store = new Store(config.dbPath);
const logs = [join(config.logDir, 'scrolltax.log'), join(config.logDir, 'scrolltax.log.1')];
process.stdout.write(buildReport(store, logs));
store.close();
