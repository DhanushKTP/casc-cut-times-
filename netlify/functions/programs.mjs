// GET /api/programs -> every program nested since START_DATE, with its time-entry status.
import {
  requireSession, readJSON, json, startDate, operators, PROGRAMS, SUBMISSIONS, EMPTY_SUMMARY,
} from '../shared/core.mjs';

export default async (req) => {
  const { error } = requireSession(req);
  if (error) return error;

  const [{ data: summary }, { data: status }] = await Promise.all([
    readJSON(PROGRAMS, 'summary', EMPTY_SUMMARY),
    readJSON(SUBMISSIONS, 'status', {}),
  ]);
  const s = summary ?? EMPTY_SUMMARY;
  const from = startDate();

  const out = [];
  const seen = new Set();
  const add = (p, sigma) => {
    if (seen.has(p.no)) return;
    const when = p.completed || p.posted || '';
    if (when && when.slice(0, 10) < from) return;
    seen.add(p.no);
    const st = status?.[p.no];
    out.push({ ...p, sigma, entry: st ? { status: st.status, operator: st.operator, at: st.at, minutes: st.minutes } : null });
  };
  for (const p of Object.values(s.waiting || {})) add(p, 'waiting');
  for (const p of Object.values(s.done || {})) add(p, 'cleared');

  return json({
    ok: true,
    waitingUpdatedAt: s.waitingUpdatedAt,
    doneUpdatedAt: s.doneUpdatedAt,
    startDate: from,
    operators: operators(),
    programs: out,
  });
};

export const config = { path: '/api/programs' };
