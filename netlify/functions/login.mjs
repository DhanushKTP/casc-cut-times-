// POST /api/login  { pin } -> { token, operators, expiresAt }
import { env, operators, sign, safeEqual, json, fail, body, readJSON, writeJSON, store } from '../shared/core.mjs';

const MAX_FAILS = 8;          // wrong PINs allowed from one address...
const WINDOW_MS = 15 * 60e3;  // ...within this many minutes, then that address waits.

export default async (req, context) => {
  if (req.method !== 'POST') return fail(405, 'Use POST.');
  const pin = env('SITE_PIN');
  const secret = env('SESSION_SECRET');
  if (!pin || !secret) return fail(500, 'SITE_PIN and SESSION_SECRET must be set in Netlify.');

  const ip = String(context?.ip || req.headers.get('x-nf-client-connection-ip') || 'unknown').replace(/[^0-9a-fA-F:.]/g, '_');
  const key = `pin-fails-${ip}`;
  const { data: fails } = await readJSON('security', key, null);
  const now = Date.now();
  const recent = fails && now - fails.first < WINDOW_MS ? fails : null;
  if (recent && recent.count >= MAX_FAILS) {
    const mins = Math.ceil((WINDOW_MS - (now - recent.first)) / 60e3);
    return fail(429, `Too many wrong PINs. Try again in ${mins} min.`);
  }

  const b = await body(req);
  if (!safeEqual(String(b?.pin ?? ''), pin)) {
    await writeJSON('security', key, recent ? { ...recent, count: recent.count + 1 } : { first: now, count: 1 });
    await new Promise((r) => setTimeout(r, 400));
    return fail(401, 'That PIN is not right.');
  }
  if (recent) await store('security').delete(key);

  const hours = Number(env('SESSION_HOURS', '12')) || 12;
  const expiresAt = now + hours * 3600e3;
  return json({ ok: true, token: sign({ exp: expiresAt }, secret), expiresAt, operators: operators() });
};

export const config = { path: '/api/login' };
