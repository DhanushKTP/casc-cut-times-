// POST /api/timer  { no, line: "all" | <line key>, action: "start"|"pause"|"resume"|"stop"|"reset", operator }
// The stopwatch lives on the server so it keeps going when the tablet sleeps, reloads or changes.
import {
  requireSession, operators, json, fail, body, readJSON, updateJSON, loadProgram, nowLocal, timerView, timersSummary,
  TIMERS, SUBMISSIONS,
} from '../shared/core.mjs';

export default async (req) => {
  if (req.method !== 'POST') return fail(405, 'Use POST.');
  const { error } = requireSession(req);
  if (error) return error;

  const b = await body(req);
  const no = String(b?.no ?? '').trim();
  const line = String(b?.line ?? 'all');
  const action = String(b?.action ?? '');
  const operator = String(b?.operator ?? '').trim();
  if (!['start', 'pause', 'resume', 'stop', 'reset'].includes(action)) return fail(400, 'Unknown stopwatch action.');
  if (!operators().includes(operator)) return fail(400, 'Pick your name again: that operator is not on the list.');

  const program = await loadProgram(no);
  if (!program) return fail(404, `Program ${no} wasn't found.`);
  if (line !== 'all' && !program.lines.some((l) => l.key === line)) return fail(400, 'That line is not on this program.');
  const { data: sub } = await readJSON(SUBMISSIONS, `sub-${no}`, null);
  if (sub) return fail(409, `Program ${no} has already been submitted.`);

  let problem = null;
  const now = Date.now();
  const local = nowLocal();
  const rec = await updateJSON(TIMERS, `timer-${no}`, { no, operator, lines: {} }, (r) => {
    problem = null;
    const t = r.lines[line];
    if (action === 'reset') { delete r.lines[line]; return; }
    if (action === 'start') {
      if (t && t.status !== 'stopped') { problem = 'This stopwatch is already going.'; return; }
      r.lines[line] = { status: 'running', operator, firstStart: now, startedAtLocal: local, runningSince: now, runSec: 0, pauses: 0 };
      r.operator = operator;
      return;
    }
    if (!t) { problem = 'Press Start first.'; return; }
    if (action === 'pause') {
      if (t.status !== 'running') { problem = 'The stopwatch is not running.'; return; }
      t.runSec += (now - t.runningSince) / 1000; t.runningSince = null; t.status = 'paused'; t.pauses = (t.pauses || 0) + 1;
      t.pausedAt = now; t.pausedAtLocal = local;
    } else if (action === 'resume') {
      if (t.status !== 'paused') { problem = 'The stopwatch is not paused.'; return; }
      t.runningSince = now; t.status = 'running';
    } else if (action === 'stop') {
      if (t.status === 'running') {
        t.runSec += (now - t.runningSince) / 1000; t.runningSince = null; t.lastStop = now; t.stoppedAtLocal = local;
      } else if (t.status === 'paused') {
        t.lastStop = t.pausedAt; t.stoppedAtLocal = t.pausedAtLocal; // it ended when it was paused
      } else { problem = 'The stopwatch has already stopped.'; return; }
      t.status = 'stopped';
    }
    r.operator = operator;
  });
  if (problem) return fail(409, problem);

  // Small index for the program list ("Running" / "Paused" badges).
  await updateJSON(TIMERS, 'index', {}, (idx) => {
    const sum = timersSummary(rec);
    if (sum) idx[no] = sum; else delete idx[no];
  });

  const timers = Object.fromEntries(Object.entries(rec.lines || {}).map(([k, v]) => [k, timerView(v, now)]));
  return json({ ok: true, timers, serverNow: now });
};

export const config = { path: '/api/timer' };
