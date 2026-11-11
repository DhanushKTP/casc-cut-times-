// POST /api/submit -> saves the operator's times (once per program) and sends them to Power Automate.
// Body: { no, operator, mode: "whole"|"split", timing: "stopwatch"|"typed",
//         typed only:  date: "dd/mm/yyyy", whole: { start, end }, lines: [{ key, start, end }] }
// With the stopwatch, the times come from the server's own stopwatch for that program.
import crypto from 'node:crypto';
import {
  env, operators, requireSession, json, fail, body, loadProgram, readJSON, writeJSON, updateJSON, store,
  parseUkDate, parseTime, fmtTime, nowLocal, ukDate, ukDateTime, hmac, notify, siteUrl,
  SUBMISSIONS, TIMERS,
} from '../shared/core.mjs';

function typedSpan(start, end, label) {
  const s = parseTime(start);
  const e = parseTime(end);
  if (s === null) return { error: `${label}: type the start time as HH:MM.` };
  if (e === null) return { error: `${label}: type the end time as HH:MM.` };
  if (e <= s) return { error: `${label}: the end time must be after the start time.` };
  return { start: fmtTime(s), end: fmtTime(e), minutes: e - s, paused: 0 };
}

// "2026-11-10T09:05:33" -> "09:05"
const hm = (iso) => String(iso || '').slice(11, 16);
const oneDp = (x) => Math.round(x * 10) / 10;

function watchSpan(t, label) {
  if (!t) return { error: `${label}: start the stopwatch first (or type the times instead).` };
  if (t.status !== 'stopped') return { error: `${label}: press Stop before submitting.` };
  const runMin = (t.runSec || 0) / 60;
  const wallMin = (t.lastStop - t.firstStart) / 60000;
  return {
    start: hm(t.startedAtLocal), end: hm(t.stoppedAtLocal), minutes: oneDp(runMin),
    paused: oneDp(Math.max(0, wallMin - runMin)), date: String(t.startedAtLocal || '').slice(0, 10),
  };
}

const mins = (sec) => Math.round((Number(sec) || 0) / 6) / 10; // planned minutes, one decimal (49:30 -> 49.5)

export default async (req) => {
  if (req.method !== 'POST') return fail(405, 'Use POST.');
  const { error } = requireSession(req);
  if (error) return error;

  const b = await body(req);
  if (!b) return fail(400, 'Nothing was sent.');
  const no = String(b.no ?? '').trim();
  const operator = String(b.operator ?? '').trim();
  if (!operators().includes(operator)) return fail(400, 'Pick your name again: that operator is not on the list.');

  const program = await loadProgram(no);
  if (!program) return fail(404, `Program ${no} wasn't found.`);

  const { data: existing } = await readJSON(SUBMISSIONS, `sub-${no}`, null);
  if (existing) return fail(409, `Program ${no} was already submitted by ${existing.operator} on ${ukDateTime(existing.enteredAt)}.`);

  const mode = b.mode === 'split' && program.lines.length > 1 ? 'split' : 'whole';
  const timing = b.timing === 'stopwatch' ? 'stopwatch' : 'typed';
  const lines = program.lines;
  const timed = [];
  let isoDate;

  if (timing === 'stopwatch') {
    const { data: tr } = await readJSON(TIMERS, `timer-${no}`, null);
    const tl = tr?.lines || {};
    if (mode === 'whole') {
      const t = watchSpan(tl.all, 'Whole program');
      if (t.error) return fail(400, t.error);
      isoDate = t.date;
      lines.forEach((l, i) => timed.push(i === 0
        ? { ...l, ...t, plannedMinutes: mins(program.plannedTotalSec) }
        : { ...l, start: '', end: '', minutes: null, paused: null, plannedMinutes: null }));
    } else {
      for (const l of lines) {
        const t = watchSpan(tl[l.key], `${l.customer} ${l.label}`);
        if (t.error) return fail(400, t.error);
        if (!isoDate || t.date < isoDate) isoDate = t.date;
        timed.push({ ...l, ...t, plannedMinutes: mins(l.plannedSec) });
      }
    }
  } else {
    isoDate = parseUkDate(b.date);
    if (!isoDate) return fail(400, 'Type the date as DD/MM/YYYY.');
    if (isoDate > nowLocal().slice(0, 10)) return fail(400, "The cut date can't be in the future.");
    if (mode === 'whole') {
      const t = typedSpan(b.whole?.start, b.whole?.end, 'Whole program');
      if (t.error) return fail(400, t.error);
      lines.forEach((l, i) => timed.push(i === 0
        ? { ...l, ...t, plannedMinutes: mins(program.plannedTotalSec) }
        : { ...l, start: '', end: '', minutes: null, paused: null, plannedMinutes: null }));
    } else {
      const given = new Map((Array.isArray(b.lines) ? b.lines : []).map((x) => [String(x.key), x]));
      for (const l of lines) {
        const x = given.get(l.key);
        const t = typedSpan(x?.start, x?.end, `${l.customer} ${l.label}`);
        if (t.error) return fail(400, t.error);
        timed.push({ ...l, ...t, plannedMinutes: mins(l.plannedSec) });
      }
    }
  }

  const submissionId = crypto.randomUUID();
  const enteredAt = nowLocal();
  const totalMinutes = oneDp(timed.reduce((a, r) => a + (r.minutes || 0), 0));
  const isTube = program.type === 'tube';

  // Each line's share of the time, so per-JN totals add up even for a whole-program entry.
  // Split: the line's own time. Whole: the program's time shared by each line's planned time
  // (equal shares if nothing is planned); the last line takes the rounding so the shares add up exactly.
  const jnColumns = /^(yes|true|1)$/i.test(env('MASTER_JN_COLUMNS') || '');
  const plannedSum = lines.reduce((a, l) => a + (Number(l.plannedSec) || 0), 0);
  const shareMin = [];
  const sharePlanned = lines.map((l) => mins(Number(l.plannedSec) || 0));
  if (mode === 'split') timed.forEach((r) => shareMin.push(r.minutes ?? 0));
  else {
    let left = totalMinutes;
    lines.forEach((l, i) => {
      if (i === lines.length - 1) { shareMin.push(oneDp(left)); return; }
      const f = plannedSum > 0 ? (Number(l.plannedSec) || 0) / plannedSum : 1 / lines.length;
      const m = oneDp(totalMinutes * f);
      shareMin.push(m); left -= m;
    });
  }

  // One row per line (JN on the flat lasers, tube type on the tube laser), keyed by the master sheet's column names.
  const rows = timed.map((r, i) => ({
    'Submission ID': submissionId,
    'Line': i + 1,
    'Machine': program.machineShort,
    'Program': isTube ? program.job : no,
    'JN': r.jn,
    'Customer': r.customer,
    'Item': isTube ? r.label : r.jn,
    'Material': program.material,
    'Thickness (mm)': isTube ? '' : program.thickness ?? '',
    'Sheet / profile': isTube ? program.profile : program.sheet,
    'Sheets / tubes': Number(program.sheets) || 1,
    'Posted': ukDateTime(program.posted),
    'Operator': operator,
    'Cut date': ukDate(isoDate),
    'Start': r.start,
    'End': r.end,
    'Minutes': r.minutes ?? '',
    'Paused minutes': r.paused ?? '',
    'Planned minutes': r.plannedMinutes ?? '',
    'Entry': mode === 'split' ? (isTube ? 'Split by tube' : 'Split by customer') : 'Whole',
    'Timing': timing === 'stopwatch' ? 'Stopwatch' : 'Typed',
    'Entered at': ukDateTime(enteredAt),
    // Sent only once the master tables have these two columns (Netlify variable MASTER_JN_COLUMNS=yes),
    // because Power Automate can't add a row with a column the table doesn't have.
    ...(jnColumns ? { 'JN minutes': shareMin[i], 'JN planned minutes': sharePlanned[i] } : {}),
  }));

  const record = {
    submissionId, no, operator, date: isoDate, mode, timing, rows, totalMinutes, enteredAt,
    status: 'pending', syncedAt: null, message: null,
  };

  // onlyIfNew: if two tablets submit the same program at once, only the first one is kept.
  const saved = await writeJSON(SUBMISSIONS, `sub-${no}`, record, { onlyIfNew: true });
  if (saved?.modified === false) return fail(409, `Program ${no} was just submitted on another tablet.`);

  // Any stopwatch on this program is finished with.
  try {
    await store(TIMERS).delete(`timer-${no}`);
    await updateJSON(TIMERS, 'index', {}, (idx) => { delete idx[no]; });
  } catch { /* not important */ }

  const setStatus = (status, extra = {}) => updateJSON(SUBMISSIONS, 'status', {}, (s) => {
    s[no] = { ...(s[no] || {}), status, operator, at: enteredAt, minutes: totalMinutes, submissionId, ...extra };
  });
  await setStatus('pending', { notified: false });

  // Hand over to Power Automate. It answers 202 straight away and confirms later via /api/confirm.
  const flowUrl = env('FLOW_SUBMIT_URL');
  let sendError = null;
  if (!flowUrl) {
    sendError = 'FLOW_SUBMIT_URL is not set in Netlify.';
  } else {
    try {
      const r = await fetch(flowUrl, {
        method: 'POST',
        headers: { 'content-type': 'application/json' },
        body: JSON.stringify({
          submissionId,
          program: no,
          machine: program.machineShort, // "3030", "1040" or "Tube 7000": the flow picks the sheet from this
          operator,
          rows,
          confirmUrl: `${siteUrl(req)}/api/confirm`,
          confirmToken: hmac(submissionId, env('CONFIRM_SECRET') || env('SESSION_SECRET')),
        }),
        signal: AbortSignal.timeout(9000),
      });
      if (!r.ok) sendError = `Power Automate answered ${r.status}.`;
    } catch (e) {
      sendError = `Couldn't reach Power Automate (${e.name === 'TimeoutError' ? 'timed out' : e.message}).`;
    }
  }

  if (sendError) {
    await writeJSON(SUBMISSIONS, `sub-${no}`, { ...record, status: 'failed', message: sendError });
    await setStatus('failed', { message: sendError, notified: true });
    await notify(`Cut times not sent: ${isTube ? program.job : `program ${no}`}`, [
      `${isTube ? program.job : `Program ${no}`} was saved in the app but did not reach the master sheet.`,
      `Reason: ${sendError}`,
      `Operator: ${operator}`,
      `Cut date: ${ukDate(isoDate)}  Total: ${totalMinutes} min`,
      `Submission ID: ${submissionId}`,
      '',
      ...rows.map((r) => `${r.Customer}  ${r.Item}  ${r.Start}-${r.End}  ${r.Minutes} min`),
    ]);
    return json({ ok: true, saved: true, status: 'failed', submissionId, message: sendError, totalMinutes });
  }

  return json({ ok: true, saved: true, status: 'pending', submissionId, totalMinutes });
};

export const config = { path: '/api/submit' };
