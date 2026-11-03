import { DatabaseSync } from 'node:sqlite';
import { randomUUID } from 'node:crypto';

export interface UserRow {
  id: string;
  apple_user_id: string;
  age_confirmed_at: string;
  terms_version: string;
  terms_accepted_at: string;
  leave_requested_at: string | null;
  created_at: string;
}

export interface PaymentRow {
  id: string;
  user_id: string | null;
  apple_transaction_id: string;
  product_id: string;
  amount_minor: number;
  currency: string;
  status: 'paid' | 'refunded';
  purchased_at: string;
  refunded_at: string | null;
}

export interface UnlockRow {
  id: string;
  payment_id: string;
  started_at: string;
  ends_at: string;
}

const SCHEMA = `
CREATE TABLE IF NOT EXISTS users (
  id TEXT PRIMARY KEY,
  apple_user_id TEXT NOT NULL UNIQUE,
  age_confirmed_at TEXT NOT NULL,
  terms_version TEXT NOT NULL,
  terms_accepted_at TEXT NOT NULL,
  leave_requested_at TEXT,
  created_at TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS payments (
  id TEXT PRIMARY KEY,
  user_id TEXT REFERENCES users(id) ON DELETE SET NULL,
  apple_transaction_id TEXT NOT NULL UNIQUE,
  product_id TEXT NOT NULL,
  amount_minor INTEGER NOT NULL,
  currency TEXT NOT NULL,
  status TEXT NOT NULL CHECK (status IN ('paid', 'refunded')),
  purchased_at TEXT NOT NULL,
  refunded_at TEXT
);
CREATE TABLE IF NOT EXISTS unlocks (
  id TEXT PRIMARY KEY,
  payment_id TEXT NOT NULL UNIQUE REFERENCES payments(id) ON DELETE CASCADE,
  started_at TEXT NOT NULL,
  ends_at TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS pending_refunds (
  apple_transaction_id TEXT PRIMARY KEY,
  refunded_at TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS payments_user ON payments(user_id, purchased_at);
`;

export class Store {
  readonly db: DatabaseSync;

  constructor(path: string) {
    this.db = new DatabaseSync(path);
    this.db.exec('PRAGMA journal_mode = WAL; PRAGMA foreign_keys = ON;');
    this.db.exec(SCHEMA);
  }

  close(): void {
    this.db.close();
  }

  private tx<T>(fn: () => T): T {
    this.db.exec('BEGIN');
    try {
      const out = fn();
      this.db.exec('COMMIT');
      return out;
    } catch (err) {
      this.db.exec('ROLLBACK');
      throw err;
    }
  }

  userById(id: string): UserRow | undefined {
    return this.db.prepare('SELECT * FROM users WHERE id = ?').get(id) as unknown as UserRow | undefined;
  }

  userByApple(appleUserId: string): UserRow | undefined {
    return this.db.prepare('SELECT * FROM users WHERE apple_user_id = ?').get(appleUserId) as unknown as
      | UserRow
      | undefined;
  }

  createUser(appleUserId: string, termsVersion: string, now: Date): UserRow {
    const iso = now.toISOString();
    const id = randomUUID();
    this.db
      .prepare(
        'INSERT INTO users (id, apple_user_id, age_confirmed_at, terms_version, terms_accepted_at, created_at) VALUES (?, ?, ?, ?, ?, ?)',
      )
      .run(id, appleUserId, iso, termsVersion, iso, iso);
    return this.userById(id)!;
  }

  setLeave(userId: string, at: Date | null): void {
    this.db.prepare('UPDATE users SET leave_requested_at = ? WHERE id = ?').run(at ? at.toISOString() : null, userId);
  }

  /**
   * Deletes the account. Payments are kept for tax records but lose the link to
   * the person. Unlocks are only useful with the account, so they go.
   */
  deleteUser(userId: string): void {
    this.tx(() => {
      this.db
        .prepare('DELETE FROM unlocks WHERE payment_id IN (SELECT id FROM payments WHERE user_id = ?)')
        .run(userId);
      this.db.prepare('DELETE FROM users WHERE id = ?').run(userId);
    });
  }

  paymentByTransaction(transactionId: string): PaymentRow | undefined {
    return this.db.prepare('SELECT * FROM payments WHERE apple_transaction_id = ?').get(transactionId) as unknown as
      | PaymentRow
      | undefined;
  }

  unlockForPayment(paymentId: string): UnlockRow | undefined {
    return this.db.prepare('SELECT * FROM unlocks WHERE payment_id = ?').get(paymentId) as unknown as
      | UnlockRow
      | undefined;
  }

  paymentsForUser(userId: string): Array<PaymentRow & { unlock_started_at: string | null; unlock_ends_at: string | null }> {
    return this.db
      .prepare(
        `SELECT p.*, u.started_at AS unlock_started_at, u.ends_at AS unlock_ends_at
         FROM payments p LEFT JOIN unlocks u ON u.payment_id = p.id
         WHERE p.user_id = ? ORDER BY p.purchased_at DESC`,
      )
      .all(userId) as unknown as Array<PaymentRow & { unlock_started_at: string | null; unlock_ends_at: string | null }>;
  }

  unlockStartsForUser(userId: string): string[] {
    const rows = this.db
      .prepare(
        `SELECT u.started_at FROM unlocks u JOIN payments p ON p.id = u.payment_id
         WHERE p.user_id = ? AND p.status = 'paid'`,
      )
      .all(userId) as unknown as Array<{ started_at: string }>;
    return rows.map((r) => r.started_at);
  }

  /** Stores the payment, and the unlock if there is one, in one step. */
  recordPayment(input: {
    userId: string;
    transactionId: string;
    productId: string;
    amountMinor: number;
    currency: string;
    purchasedAt: Date;
    unlockEndsAt: Date | null;
  }): { payment: PaymentRow; unlock: UnlockRow | null } {
    return this.tx(() => {
      const id = randomUUID();
      const refund = this.db
        .prepare('SELECT refunded_at FROM pending_refunds WHERE apple_transaction_id = ?')
        .get(input.transactionId) as unknown as { refunded_at: string } | undefined;
      this.db
        .prepare(
          `INSERT INTO payments (id, user_id, apple_transaction_id, product_id, amount_minor, currency, status, purchased_at, refunded_at)
           VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)`,
        )
        .run(
          id,
          input.userId,
          input.transactionId,
          input.productId,
          input.amountMinor,
          input.currency,
          refund ? 'refunded' : 'paid',
          input.purchasedAt.toISOString(),
          refund ? refund.refunded_at : null,
        );
      if (refund) this.db.prepare('DELETE FROM pending_refunds WHERE apple_transaction_id = ?').run(input.transactionId);

      let unlockId: string | null = null;
      if (input.unlockEndsAt) {
        unlockId = randomUUID();
        this.db
          .prepare('INSERT INTO unlocks (id, payment_id, started_at, ends_at) VALUES (?, ?, ?, ?)')
          .run(unlockId, id, input.purchasedAt.toISOString(), input.unlockEndsAt.toISOString());
      }
      return {
        payment: this.paymentByTransaction(input.transactionId)!,
        unlock: unlockId ? this.unlockForPayment(id)! : null,
      };
    });
  }

  /** Marks a payment refunded. If we haven't seen the payment yet, remember the refund for later. */
  markRefunded(transactionId: string, at: Date): 'marked' | 'remembered' | 'already' {
    const payment = this.paymentByTransaction(transactionId);
    if (!payment) {
      this.db
        .prepare('INSERT OR REPLACE INTO pending_refunds (apple_transaction_id, refunded_at) VALUES (?, ?)')
        .run(transactionId, at.toISOString());
      return 'remembered';
    }
    if (payment.status === 'refunded') return 'already';
    this.db
      .prepare("UPDATE payments SET status = 'refunded', refunded_at = ? WHERE id = ?")
      .run(at.toISOString(), payment.id);
    return 'marked';
  }

  /** Totals for the report script. Counts and sums only, nothing about any one person. */
  report(): {
    users: number;
    leaving: number;
    payments: number;
    refunded: number;
    unlinkedPayments: number;
    unlocks: number;
    paymentsWithoutUnlock: number;
    pendingRefunds: number;
    paidMinor: Array<{ currency: string; minor: number }>;
  } {
    const n = (sql: string) => (this.db.prepare(sql).get() as unknown as { n: number }).n;
    return {
      users: n('SELECT COUNT(*) AS n FROM users'),
      leaving: n('SELECT COUNT(*) AS n FROM users WHERE leave_requested_at IS NOT NULL'),
      payments: n('SELECT COUNT(*) AS n FROM payments'),
      refunded: n("SELECT COUNT(*) AS n FROM payments WHERE status = 'refunded'"),
      unlinkedPayments: n('SELECT COUNT(*) AS n FROM payments WHERE user_id IS NULL'),
      unlocks: n('SELECT COUNT(*) AS n FROM unlocks'),
      paymentsWithoutUnlock: n(
        "SELECT COUNT(*) AS n FROM payments p WHERE p.status = 'paid' AND p.user_id IS NOT NULL AND NOT EXISTS (SELECT 1 FROM unlocks u WHERE u.payment_id = p.id)",
      ),
      pendingRefunds: n('SELECT COUNT(*) AS n FROM pending_refunds'),
      paidMinor: this.db
        .prepare("SELECT currency, SUM(amount_minor) AS minor FROM payments WHERE status = 'paid' GROUP BY currency")
        .all() as unknown as Array<{ currency: string; minor: number }>,
    };
  }

  /** Copies the whole database to a new file. Safe to run while the server is up. */
  backupTo(file: string): void {
    const quoted = file.replaceAll("'", "''");
    this.db.exec(`VACUUM INTO '${quoted}'`);
  }
}
