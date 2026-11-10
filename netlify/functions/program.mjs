// GET /api/program?no=54533 -> full program (parts, JN lines) plus its submission, if any.
import { requireSession, readJSON, json, fail, loadProgram, SUBMISSIONS } from '../shared/core.mjs';

export default async (req) => {
  const { error } = requireSession(req);
  if (error) return error;
  const no = new URL(req.url).searchParams.get('no')?.trim();
  if (!no) return fail(400, 'Program number missing.');

  const program = await loadProgram(no);
  if (!program) return fail(404, `Program ${no} wasn't found. It may have been deleted in SigmaNEST.`);

  const { data: sub } = await readJSON(SUBMISSIONS, `sub-${no}`, null);
  const submission = sub
    ? {
        submissionId: sub.submissionId, operator: sub.operator, date: sub.date, mode: sub.mode,
        rows: sub.rows, totalMinutes: sub.totalMinutes, enteredAt: sub.enteredAt,
        status: sub.status, syncedAt: sub.syncedAt ?? null, message: sub.message ?? null,
      }
    : null;
  return json({ ok: true, program, submission });
};

export const config = { path: '/api/program' };
