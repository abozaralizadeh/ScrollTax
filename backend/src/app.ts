import Fastify from 'fastify';
import type { FastifyInstance, FastifyRequest } from 'fastify';
import { existsSync, readFileSync } from 'node:fs';
import { join } from 'node:path';
import type { Config } from './config.ts';
import type { AppleServices } from './apple.ts';
import type { Store, UserRow } from './store.ts';
import { readSession, signSession } from './session.ts';
import { isTimeZone, localDay } from './days.ts';

export interface AppDeps {
  config: Config;
  store: Store;
  apple: AppleServices;
  now?: () => Date;
  logStream?: { write(chunk: string): void };
  webDir?: string;
}

class HttpError extends Error {
  status: number;
  code: string;
  constructor(status: number, code: string, message: string) {
    super(message);
    this.status = status;
    this.code = code;
  }
}

const bad = (msg: string, code = 'bad_request') => new HttpError(400, code, msg);

function asObject(body: unknown): Record<string, unknown> {
  if (typeof body !== 'object' || body === null || Array.isArray(body)) throw bad('Expected a JSON object');
  return body as Record<string, unknown>;
}

function needString(body: Record<string, unknown>, key: string): string {
  const v = body[key];
  if (typeof v !== 'string' || v.length === 0) throw bad(`${key} is required`);
  return v;
}

const LEGAL_PAGES: Record<string, string> = {
  privacy: 'privacy.html',
  terms: 'terms.html',
  support: 'support.html',
  help: 'help.html',
};

export function buildApp(deps: AppDeps): FastifyInstance {
  const { config, store, apple } = deps;
  const now = deps.now ?? (() => new Date());
  const webDir = deps.webDir ?? join(import.meta.dirname, '..', '..', 'web');

  const app = Fastify({
    logger: deps.logStream ? { level: config.logLevel, stream: deps.logStream } : false,
    bodyLimit: 64 * 1024,
  });

  app.setErrorHandler((err: Error, req, reply) => {
    if (err instanceof HttpError) {
      return reply.status(err.status).send({ error: err.code, message: err.message });
    }
    const status = (err as { statusCode?: number }).statusCode;
    if (typeof status === 'number' && status >= 400 && status < 500) {
      return reply.status(status).send({ error: 'bad_request', message: err.message });
    }
    req.log.error({ err }, 'unhandled error');
    return reply.status(500).send({ error: 'server_error', message: 'Something went wrong on our side' });
  });

  function requireUser(req: FastifyRequest): UserRow {
    const header = req.headers.authorization ?? '';
    const token = header.startsWith('Bearer ') ? header.slice(7) : '';
    const uid = token ? readSession(token, config.sessionSecret, now()) : null;
    const user = uid ? store.userById(uid) : undefined;
    if (!user) throw new HttpError(401, 'unauthorized', 'Please sign in again');
    return user;
  }

  function leaveStatus(user: UserRow) {
    if (!user.leave_requested_at) return { requestedAt: null, effectiveAt: null, complete: false };
    const effective = new Date(new Date(user.leave_requested_at).getTime() + config.leaveWaitHours * 3600_000);
    return {
      requestedAt: user.leave_requested_at,
      effectiveAt: effective.toISOString(),
      complete: effective.getTime() <= now().getTime(),
    };
  }

  function unlocksToday(userId: string, tz: string): number {
    const today = localDay(now(), tz);
    return store.unlockStartsForUser(userId).filter((s) => localDay(new Date(s), tz) === today).length;
  }

  function paymentView(p: ReturnType<Store['paymentsForUser']>[number]) {
    return {
      id: p.id,
      transactionId: p.apple_transaction_id,
      amountMinor: p.amount_minor,
      currency: p.currency,
      status: p.status,
      purchasedAt: p.purchased_at,
      refundedAt: p.refunded_at,
      unlock: p.unlock_started_at ? { startedAt: p.unlock_started_at, endsAt: p.unlock_ends_at } : null,
    };
  }

  app.get('/healthz', async () => ({ ok: true }));

  // The app reads these so a change here shows up without a new app release.
  // The price itself comes from the App Store product, so priceMinor is for display only.
  app.get('/v1/config', async () => ({
    productId: config.productId,
    priceMinor: config.priceMinor,
    currency: config.currency,
    unlockMinutes: config.unlockMinutes,
    dailyUnlockLimit: config.dailyUnlockLimit,
    leaveWaitHours: config.leaveWaitHours,
    minAge: config.minAge,
    termsVersion: config.termsVersion,
  }));

  // The phone checks its own clock against this. Only the time, nothing about the person.
  app.get('/v1/time', async () => ({ now: now().toISOString() }));

  app.post('/v1/auth/apple', async (req) => {
    const body = asObject(req.body);
    const identityToken = needString(body, 'identityToken');

    let sub: string;
    try {
      sub = (await apple.verifyIdentityToken(identityToken)).sub;
    } catch (err) {
      req.log.warn({ err }, 'identity token rejected');
      throw new HttpError(401, 'bad_identity_token', 'Apple sign in could not be checked');
    }

    let user = store.userByApple(sub);
    let created = false;
    if (!user) {
      if (body['ageConfirmed'] !== true) {
        throw bad(`You must confirm you are ${config.minAge} or over`, 'age_not_confirmed');
      }
      if (body['termsVersion'] !== config.termsVersion) {
        throw bad('Please accept the current terms', 'terms_not_accepted');
      }
      user = store.createUser(sub, config.termsVersion, now());
      created = true;
      req.log.info({ userId: user.id }, 'account created');
    }
    return {
      token: signSession(user.id, config.sessionSecret, config.sessionTtlDays, now()),
      created,
      user: { id: user.id, createdAt: user.created_at },
    };
  });

  app.get('/v1/me', async (req) => {
    const user = requireUser(req);
    const tz = (req.query as { tz?: string }).tz;
    const out: Record<string, unknown> = {
      id: user.id,
      createdAt: user.created_at,
      serverTime: now().toISOString(),
      leave: leaveStatus(user),
    };
    if (tz) {
      if (!isTimeZone(tz)) throw bad('Unknown time zone');
      out['today'] = { unlocksUsed: unlocksToday(user.id, tz), limit: config.dailyUnlockLimit };
    }
    return out;
  });

  // A copy of everything held about the person, as a file they can keep.
  app.get('/v1/me/export', async (req, reply) => {
    const user = requireUser(req);
    return reply
      .header('content-disposition', 'attachment; filename="scrolltax-my-data.json"')
      .send({
        exportedAt: now().toISOString(),
        account: {
          id: user.id,
          appleUserId: user.apple_user_id,
          createdAt: user.created_at,
          ageConfirmedAt: user.age_confirmed_at,
          termsVersion: user.terms_version,
          termsAcceptedAt: user.terms_accepted_at,
          leaveRequestedAt: user.leave_requested_at,
        },
        payments: store.paymentsForUser(user.id).map(paymentView),
      });
  });

  app.delete('/v1/me', async (req, reply) => {
    const user = requireUser(req);
    store.deleteUser(user.id);
    try {
      await apple.revokeSignIn(user.apple_user_id);
    } catch (err) {
      req.log.warn({ err }, 'could not revoke Apple sign in');
    }
    req.log.info({ userId: user.id }, 'account deleted');
    return reply.status(204).send();
  });

  app.post('/v1/payments', async (req, reply) => {
    const user = requireUser(req);
    const body = asObject(req.body);
    const signed = needString(body, 'signedTransaction');
    const tz = needString(body, 'timeZone');
    if (!isTimeZone(tz)) throw bad('Unknown time zone');

    let txn;
    try {
      txn = await apple.verifyTransaction(signed);
    } catch (err) {
      req.log.warn({ err }, 'transaction rejected');
      throw new HttpError(422, 'bad_transaction', 'The purchase could not be checked');
    }
    if (txn.productId !== config.productId) {
      throw new HttpError(422, 'wrong_product', 'This purchase is not an unlock');
    }

    const view = (p: NonNullable<ReturnType<Store['paymentByTransaction']>>, fresh: boolean, overLimit = false) => {
      const unlock = store.unlockForPayment(p.id);
      return {
        duplicate: !fresh,
        overLimit,
        payment: paymentView({ ...p, unlock_started_at: unlock?.started_at ?? null, unlock_ends_at: unlock?.ends_at ?? null }),
      };
    };

    const existing = store.paymentByTransaction(txn.transactionId);
    if (existing) {
      if (existing.user_id !== user.id) throw new HttpError(409, 'transaction_taken', 'This purchase belongs to another account');
      return view(existing, false);
    }

    const purchasedAt = new Date(txn.purchaseDate);
    const used = store
      .unlockStartsForUser(user.id)
      .filter((s) => localDay(new Date(s), tz) === localDay(purchasedAt, tz)).length;
    const overLimit = used >= config.dailyUnlockLimit;

    // The money has already been taken by Apple, so we always keep the record.
    // Over the limit we just don't hand out another unlock.
    const { payment } = store.recordPayment({
      userId: user.id,
      transactionId: txn.transactionId,
      productId: txn.productId,
      amountMinor: txn.priceMilli !== undefined ? Math.round(txn.priceMilli / 10) : config.priceMinor,
      currency: txn.currency ?? config.currency,
      purchasedAt,
      unlockEndsAt: overLimit ? null : new Date(purchasedAt.getTime() + config.unlockMinutes * 60_000),
    });
    if (overLimit) req.log.warn({ userId: user.id }, 'payment recorded over the daily limit');
    reply.status(201);
    return view(payment, true, overLimit);
  });

  app.get('/v1/payments', async (req) => {
    const user = requireUser(req);
    return { payments: store.paymentsForUser(user.id).map(paymentView) };
  });

  app.post('/v1/leave', async (req) => {
    const user = requireUser(req);
    if (!user.leave_requested_at) store.setLeave(user.id, now());
    return leaveStatus(store.userById(user.id)!);
  });

  app.delete('/v1/leave', async (req) => {
    const user = requireUser(req);
    store.setLeave(user.id, null);
    return leaveStatus(store.userById(user.id)!);
  });

  app.post('/v1/apple/notifications', async (req) => {
    const body = asObject(req.body);
    const signed = needString(body, 'signedPayload');
    let note;
    try {
      note = await apple.verifyNotification(signed);
    } catch (err) {
      req.log.warn({ err }, 'notification rejected');
      throw new HttpError(400, 'bad_notification', 'Could not verify the notification');
    }
    if (note.type === 'REFUND' && note.transaction) {
      const result = store.markRefunded(note.transaction.transactionId, now());
      req.log.info({ result }, 'refund notification handled');
    } else {
      req.log.info({ type: note.type }, 'notification ignored');
    }
    return { ok: true };
  });

  // The legal pages are plain HTML files in web/. They are drafts and not legal advice.
  app.get('/legal/:page', async (req, reply) => {
    const file = LEGAL_PAGES[(req.params as { page: string }).page];
    const path = file ? join(webDir, file) : '';
    if (!file || !existsSync(path)) throw new HttpError(404, 'not_found', 'No such page');
    return reply.type('text/html; charset=utf-8').send(
      readFileSync(path, 'utf8')
        .replaceAll('{{TERMS_VERSION}}', config.termsVersion)
        .replaceAll('{{SUPPORT_EMAIL}}', config.supportEmail || 'support address not set yet'),
    );
  });

  return app;
}
