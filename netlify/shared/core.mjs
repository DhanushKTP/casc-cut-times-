// Shared helpers for every function: settings, storage, auth, HTTP and time maths.
import crypto from 'node:crypto';
import { getStore } from '@netlify/blobs';

/* ---------------------------------------------------------------- settings */

// Every setting comes from Netlify environment variables, so nothing is fixed in code.
export function env(name, fallback = '') {
  const v = globalThis.Netlify?.env?.get?.(name) ?? process.env[name];
  return v === undefined || v === null || v === '' ? fallback : String(v);
}

export function operators() {
  return env('OPERATORS')
    .split(',')
    .map((s) => s.trim())
    .filter(Boolean);
}

export function startDate() {
  // Programs completed or posted before this date are not shown. Format YYYY-MM-DD.
  return env('START_DATE', `${new Date().getFullYear()}-01-01`);
}

/* ----------------------------------------------------------------- storage */

const stores = {};
export function store(name) {
  if (globalThis.__TEST_STORE__) return globalThis.__TEST_STORE__(name);
  stores[name] ??= getStore({ name, consistency: 'strong' });
  return stores[name];
}

export async function readJSON(storeName, key, fallback = null) {
  const r = await store(storeName).getWithMetadata(key, { type: 'json' });
  if (!r) return { data: fallback, etag: null };
  return { data: r.data, etag: r.etag ?? null };
}

export async function writeJSON(storeName, key, data, conditions = {}) {
  return store(storeName).setJSON(key, data, conditions);
}

// Read-modify-write with an etag check, so two tablets saving at once can't overwrite each other.
export async function updateJSON(storeName, key, fallback, mutate, tries = 8) {
  for (let i = 0; i < tries; i++) {
    const { data, etag } = await readJSON(storeName, key, null);
    const current = data ?? structuredClone(fallback);
    const next = (await mutate(current)) ?? current;
    const res = await writeJSON(storeName, key, next, etag ? { onlyIfMatch: etag } : { onlyIfNew: true });
    if (res?.modified !== false) return next;
    await new Promise((r) => setTimeout(r, 40 + Math.random() * 120));
  }
  throw new Error(`Could not update ${storeName}/${key}: too many people saving at once. Try again.`);
}

export const PROGRAMS = 'programs';
export const SUBMISSIONS = 'submissions';

/* -------------------------------------------------------------------- http */

export function json(data, status = 200, headers = {}) {
  return new Response(JSON.stringify(data), {
    status,
    headers: { 'content-type': 'application/json; charset=utf-8', 'cache-control': 'no-store', ...headers },
  });
}

export function fail(status, message) {
  return json({ ok: false, error: message }, status);
}

export async function body(req) {
  try {
    return await req.json();
  } catch {
    return null;
  }
}

/* -------------------------------------------------------------------- auth */

const b64u = (buf) => Buffer.from(buf).toString('base64url');

export function sign(payload, secret) {
  const data = b64u(JSON.stringify(payload));
  const mac = crypto.createHmac('sha256', secret).update(data).digest('base64url');
  return `${data}.${mac}`;
}

export function verify(token, secret) {
  if (!token || typeof token !== 'string' || !token.includes('.')) return null;
  const [data, mac] = token.split('.');
  const expected = crypto.createHmac('sha256', secret).update(data).digest('base64url');
  if (!safeEqual(mac, expected)) return null;
  try {
    const payload = JSON.parse(Buffer.from(data, 'base64url').toString('utf8'));
    if (payload.exp && Date.now() > payload.exp) return null;
    return payload;
  } catch {
    return null;
  }
}

export function safeEqual(a, b) {
  const x = Buffer.from(String(a ?? ''));
  const y = Buffer.from(String(b ?? ''));
  return x.length === y.length && crypto.timingSafeEqual(x, y);
}

export function hmac(value, secret) {
  return crypto.createHmac('sha256', secret).update(String(value)).digest('base64url');
}

// Returns the session, or a Response to send back when the tablet isn't logged in.
export function requireSession(req) {
  const secret = env('SESSION_SECRET');
  if (!secret) return { error: fail(500, 'SESSION_SECRET is not set in Netlify.') };
  const auth = req.headers.get('authorization') || '';
  const session = verify(auth.replace(/^Bearer\s+/i, ''), secret);
  if (!session) return { error: fail(401, 'Please enter the site PIN again.') };
  return { session };
}

/* -------------------------------------------------------------------- time */

// The workshop runs on UK time; the tablet and SigmaNEST both use local time.
export const TZ = 'Europe/London';

export function nowLocal() {
  const parts = new Intl.DateTimeFormat('en-GB', {
    timeZone: TZ, year: 'numeric', month: '2-digit', day: '2-digit',
    hour: '2-digit', minute: '2-digit', second: '2-digit', hour12: false,
  }).formatToParts(new Date());
  const p = Object.fromEntries(parts.map((x) => [x.type, x.value]));
  return `${p.year}-${p.month}-${p.day}T${p.hour === '24' ? '00' : p.hour}:${p.minute}:${p.second}`;
}

// "10/11/2026" -> "2026-11-10" or null
export function parseUkDate(s) {
  const m = /^(\d{1,2})\/(\d{1,2})\/(\d{4})$/.exec(String(s || '').trim());
  if (!m) return null;
  const [d, mo, y] = [Number(m[1]), Number(m[2]), Number(m[3])];
  const dt = new Date(Date.UTC(y, mo - 1, d));
  if (dt.getUTCFullYear() !== y || dt.getUTCMonth() !== mo - 1 || dt.getUTCDate() !== d) return null;
  return `${y}-${String(mo).padStart(2, '0')}-${String(d).padStart(2, '0')}`;
}

// "09:05" -> minutes since midnight, or null
export function parseTime(s) {
  const m = /^(\d{1,2}):(\d{2})$/.exec(String(s || '').trim());
  if (!m) return null;
  const h = Number(m[1]);
  const mi = Number(m[2]);
  if (h > 23 || mi > 59) return null;
  return h * 60 + mi;
}

export function fmtTime(mins) {
  return `${String(Math.floor(mins / 60)).padStart(2, '0')}:${String(mins % 60).padStart(2, '0')}`;
}

export function ukDate(iso) {
  // "2026-11-10" or "2026-11-10T09:05:00" -> "10/11/2026"
  const m = /^(\d{4})-(\d{2})-(\d{2})/.exec(String(iso || ''));
  return m ? `${m[3]}/${m[2]}/${m[1]}` : '';
}

export function ukDateTime(iso) {
  const m = /^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2})/.exec(String(iso || ''));
  return m ? `${m[3]}/${m[2]}/${m[1]} ${m[4]}:${m[5]}` : '';
}

/* ---------------------------------------------------------------- programs */

// "TRUMPF_TruLaser_3030_L81_6Kw" -> "3030". Anything else is shown as sent.
export function shortMachine(name) {
  const m = /TruLaser[_ ]?(\d{4})/i.exec(String(name || ''));
  return m ? m[1] : String(name || '').replace(/_/g, ' ');
}

// One line per JN (work order) on the program, with its customer and planned seconds.
export function buildLines(parts = []) {
  const map = new Map();
  for (const p of parts) {
    const jn = String(p.wo ?? '').trim() || '(no W/O)';
    const line = map.get(jn) ?? { jn, customer: '', plannedSec: 0 };
    if (!line.customer && p.customer) line.customer = String(p.customer).trim();
    line.plannedSec += Number(p.plannedSec) || 0;
    map.set(jn, line);
  }
  return [...map.values()].map((l) => ({ ...l, customer: l.customer || '—', plannedSec: Math.round(l.plannedSec) }));
}

export function summarize(p, src) {
  return {
    no: String(p.no),
    machine: shortMachine(p.machine),
    material: p.material ?? '',
    thickness: p.thickness ?? null,
    sheet: p.sheet ?? '',
    plannedSec: Math.round(Number(p.plannedSec) || 0),
    sheets: Number(p.sheets) || 1,
    posted: p.posted ?? null,
    completed: p.completed ?? null,
    src,
    lines: buildLines(p.parts).map((l) => ({ customer: l.customer, jn: l.jn })),
  };
}

export function monthKey(iso) {
  const m = /^(\d{4})-(\d{2})/.exec(String(iso || ''));
  return m ? `done-${m[1]}-${m[2]}` : 'done-unknown';
}

export const EMPTY_SUMMARY = { waitingUpdatedAt: null, doneUpdatedAt: null, waiting: {}, done: {} };

// Full program by number, from whichever list it is in (waiting wins over completed).
export async function loadProgram(no) {
  const { data: summary } = await readJSON(PROGRAMS, 'summary', EMPTY_SUMMARY);
  const s = summary ?? EMPTY_SUMMARY;
  const sigma = s.waiting?.[no] ? 'waiting' : s.done?.[no] ? 'cleared' : null;
  if (!sigma) return null;
  const src = sigma === 'waiting' ? 'waiting' : s.done[no].src;
  const { data } = await readJSON(PROGRAMS, src, null);
  const p = data?.programs?.[no];
  if (!p) return null;
  return {
    ...p,
    machineShort: shortMachine(p.machine),
    sigma,
    lines: buildLines(p.parts),
  };
}

/* ------------------------------------------------------------ notifications */

// Sends an email through the separate notify flow in Power Automate. Never throws.
export async function notify(subject, lines) {
  const url = env('FLOW_NOTIFY_URL');
  if (!url) return false;
  const text = Array.isArray(lines) ? lines.join('\n') : String(lines ?? '');
  try {
    const r = await fetch(url, {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ to: env('NOTIFY_EMAIL'), subject, text, html: text.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/\n/g, '<br>') }),
      signal: AbortSignal.timeout(8000),
    });
    return r.ok;
  } catch {
    return false;
  }
}

export function siteUrl(req) {
  return env('URL') || new URL(req.url).origin;
}
