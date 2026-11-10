// POST /api/sync  (called only by the sync script on the PC, with the x-sync-key header)
//   { kind: "waiting", programs: [...] }  -> replaces the list of programs waiting in SigmaNEST
//   { kind: "done",    programs: [...] }  -> adds/updates programs completed in SigmaNEST
//   { kind: "ping" }                       -> checks the key and connection only
import {
  env, safeEqual, json, fail, body, writeJSON, updateJSON, nowLocal, summarize, monthKey,
  PROGRAMS, EMPTY_SUMMARY,
} from '../shared/core.mjs';

function clean(p) {
  if (!p || p.no === undefined || p.no === null || String(p.no).trim() === '') return null;
  const parts = Array.isArray(p.parts) ? p.parts : [];
  return {
    no: String(p.no).trim(),
    machine: String(p.machine ?? ''),
    material: String(p.material ?? ''),
    thickness: p.thickness === null || p.thickness === undefined || p.thickness === '' ? null : Number(p.thickness),
    sheet: String(p.sheet ?? ''),
    sheetL: p.sheetL ? Number(p.sheetL) : null,
    sheetW: p.sheetW ? Number(p.sheetW) : null,
    plannedSec: Number(p.plannedSec) || 0,
    sheets: Number(p.sheets) || 1,
    scrapPct: p.scrapPct === null || p.scrapPct === undefined ? null : Number(p.scrapPct),
    posted: p.posted ? String(p.posted) : null,
    completed: p.completed ? String(p.completed) : null,
    parts: parts.map((x) => ({
      part: String(x.part ?? ''),
      qty: Number(x.qty) || 0,
      op: String(x.op ?? ''),
      wo: String(x.wo ?? ''),
      customer: String(x.customer ?? ''),
      plannedSec: Number(x.plannedSec) || 0,
    })),
  };
}

export default async (req) => {
  if (req.method !== 'POST') return fail(405, 'Use POST.');
  const key = env('SYNC_KEY');
  if (!key) return fail(500, 'SYNC_KEY is not set in Netlify.');
  if (!safeEqual(req.headers.get('x-sync-key'), key)) return fail(401, 'Wrong sync key.');

  const b = await body(req);
  if (!b || !['waiting', 'done', 'ping'].includes(b.kind)) return fail(400, 'kind must be waiting, done or ping.');
  if (b.kind === 'ping') return json({ ok: true, at: nowLocal() });

  const programs = (Array.isArray(b.programs) ? b.programs : []).map(clean).filter(Boolean);
  const at = nowLocal();

  if (b.kind === 'waiting') {
    const map = Object.fromEntries(programs.map((p) => [p.no, p]));
    await writeJSON(PROGRAMS, 'waiting', { updatedAt: at, programs: map });
    await updateJSON(PROGRAMS, 'summary', EMPTY_SUMMARY, (s) => {
      s.waiting = Object.fromEntries(programs.map((p) => [p.no, summarize(p, 'waiting')]));
      s.waitingUpdatedAt = at;
    });
    return json({ ok: true, kind: 'waiting', count: programs.length, at });
  }

  // kind === 'done': file each program under the month it was completed.
  const byMonth = {};
  for (const p of programs) (byMonth[monthKey(p.completed)] ??= []).push(p);
  for (const [month, list] of Object.entries(byMonth)) {
    await updateJSON(PROGRAMS, month, { programs: {} }, (m) => {
      for (const p of list) m.programs[p.no] = p;
    });
  }
  await updateJSON(PROGRAMS, 'summary', EMPTY_SUMMARY, (s) => {
    for (const p of programs) s.done[p.no] = summarize(p, monthKey(p.completed));
    s.doneUpdatedAt = at;
  });
  return json({ ok: true, kind: 'done', count: programs.length, months: Object.keys(byMonth), at });
};

export const config = { path: '/api/sync' };
