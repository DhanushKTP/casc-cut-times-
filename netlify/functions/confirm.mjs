// POST /api/confirm  (called by the Power Automate flow after it adds the rows)
// Body: { submissionId, program, confirmToken, status: "synced" | "failed", message? }
import {
  env, safeEqual, hmac, json, fail, body, readJSON, writeJSON, updateJSON, nowLocal, SUBMISSIONS,
} from '../shared/core.mjs';

export default async (req) => {
  if (req.method !== 'POST') return fail(405, 'Use POST.');
  const b = await body(req);
  const id = String(b?.submissionId ?? '');
  const no = String(b?.program ?? '').trim();
  const secret = env('CONFIRM_SECRET') || env('SESSION_SECRET');
  if (!id || !no || !secret || !safeEqual(b?.confirmToken, hmac(id, secret))) return fail(401, 'Not a valid confirmation.');

  const status = b?.status === 'failed' ? 'failed' : 'synced';
  const message = b?.message ? String(b.message).slice(0, 500) : null;

  const { data: sub } = await readJSON(SUBMISSIONS, `sub-${no}`, null);
  if (!sub || sub.submissionId !== id) return fail(404, 'Submission not found.');

  const at = nowLocal();
  await writeJSON(SUBMISSIONS, `sub-${no}`, { ...sub, status, syncedAt: status === 'synced' ? at : null, message });
  await updateJSON(SUBMISSIONS, 'status', {}, (s) => {
    s[no] = { ...(s[no] || {}), status, syncedAt: status === 'synced' ? at : null, message, notified: true };
  });
  return json({ ok: true, program: no, status });
};

export const config = { path: '/api/confirm' };
