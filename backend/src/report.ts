import { existsSync, readFileSync } from 'node:fs';
import type { Store } from './store.ts';

export interface LogCounts {
  warnings: number;
  errors: number;
}

/** Counts warn and error lines in the capped log files. Pino writes the level as a number: 40 warn, 50 error. */
export function countLogProblems(paths: string[]): LogCounts {
  const out: LogCounts = { warnings: 0, errors: 0 };
  for (const path of paths) {
    if (!existsSync(path)) continue;
    for (const line of readFileSync(path, 'utf8').split('\n')) {
      if (line.includes('"level":40,')) out.warnings++;
      else if (line.includes('"level":50,') || line.includes('"level":60,')) out.errors++;
    }
  }
  return out;
}

/** A plain text summary of payments, refunds and problems. No names, no habits, only totals. */
export function buildReport(store: Store, logPaths: string[], now = new Date()): string {
  const r = store.report();
  const log = countLogProblems(logPaths);
  const money = r.paidMinor.length
    ? r.paidMinor.map((m) => `${(m.minor / 100).toFixed(2)} ${m.currency}`).join(', ')
    : 'none';
  const lines = [
    `ScrollTax report, ${now.toISOString()}`,
    '',
    `People:                     ${r.users} (${r.leaving} waiting to leave)`,
    `Payments:                   ${r.payments} (${r.refunded} refunded, ${r.unlinkedPayments} kept after account deletion)`,
    `Paid, before Apple's cut:   ${money}`,
    `Unlocks given:              ${r.unlocks}`,
    `Refunds waiting for payment: ${r.pendingRefunds}`,
    `Log problems:               ${log.errors} errors, ${log.warnings} warnings`,
  ];
  if (r.paymentsWithoutUnlock > 0) {
    lines.push(
      '',
      `Look at this: ${r.paymentsWithoutUnlock} paid payment(s) got no unlock. That happens when someone pays over the daily limit.`,
    );
  }
  return lines.join('\n') + '\n';
}
