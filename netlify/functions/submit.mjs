// POST /api/submit -> saves the operator's times (once per program) and sends them to Power Automate.
// Body: { no, operator, date: "dd/mm/yyyy", mode: "whole"|"split",
//         whole: { start: "HH:MM", end: "HH:MM" }, lines: [{ jn, start, end }] }
import crypto from 'node:crypto';
import {
  env, operators, requireSession, json, fail, body, loadProgram, readJSON, writeJSON, updateJSON,
  parseUkDate, parseTime, fmtTime, nowLocal, ukDate, ukDateTime, hmac, notify, siteUrl, SUBMISSIONS,
} from '../shared/core.mjs';

function span(start, end, label) {
  const s = parseTime(start);
  const e = parseTime(end);
  if (s === null) return { error: `${label}: type the start time as HH:MM.` };
  if (e === null) return { error: `${label}: type the end time as HH:MM.` };
  if (e <= s) return { error: `${label}: the end time must be after the start time.` };
  return { start: fmtTime(s), end: fmtTime(e), minutes: e - s };
}

const mins = (sec) => Math.round((Number(sec) || 0) / 60);

export default async (req) => {
  if (req.method !== 'POST') return fail(405, 'Use POST.');
  const { error } = requireSession(req);
  if (error) return error;

  const b = await body(req);
  if (!b) return fail(400, 'Nothing was sent.');
  const no = String(b.no ?? '').trim();
  const operator = String(b.operator ?? '').trim();
  if (!operators().includes(operator)) return fail(400, 'Pick your name again: that operator is not on the list.');

  const isoDate = parseUkDate(b.date);
  if (!isoDate) return fail(400, 'Type the date as DD/MM/YYYY.');
  const today = nowLocal().slice(0, 10);
  if (isoDate > today) return fail(400, "The cut date can't be in the future.");

  const program = await loadProgram(no);
  if (!program) return fail(404, `Program ${no} wasn't found.`);

  const { data: existing } = await readJSON(SUBMISSIONS, `sub-${no}`, null);
  if (existing) return fail(409, `Program ${no} was already submitted by ${existing.operator} on ${ukDateTime(existing.enteredAt)}.`);

  const mode = b.mode === 'split' ? 'split' : 'whole';
  const lines = program.lines;
  const sheets = Number(program.sheets) || 1;
  const timed = [];

  if (mode === 'whole') {
    const t = span(b.whole?.start, b.whole?.end, 'Whole program');
    if (t.error) return fail(400, t.error);
    lines.forEach((l, i) => timed.push(i === 0
      ? { ...l, ...t, plannedMinutes: mins(program.plannedSec * sheets) }
      : { ...l, start: '', end: '', minutes: null, plannedMinutes: null }));
  } else {
    const given = new Map((Array.isArray(b.lines) ? b.lines : []).map((x) => [String(x.jn), x]));
    for (const l of lines) {
      const x = given.get(l.jn);
      const t = span(x?.start, x?.end, `${l.customer} ${l.jn}`);
      if (t.error) return fail(400, t.error);
      timed.push({ ...l, ...t, plannedMinutes: mins(l.plannedSec * sheets) });
    }
  }

  const submissionId = crypto.randomUUID();
  const enteredAt = nowLocal();
  const totalMinutes = timed.reduce((a, r) => a + (r.minutes || 0), 0);

  // One row per customer/JN line, keyed by the master sheet's column names.
  const rows = timed.map((r, i) => ({
    'Submission ID': submissionId,
    'Line': i + 1,
    'Program': no,
    'Laser': program.machineShort,
    'Material': program.material,
    'Thickness (mm)': program.thickness ?? '',
    'Sheet': program.sheet,
    'Sheets': sheets,
    'Posted': ukDateTime(program.posted),
    'Customer': r.customer,
    'JN': r.jn,
    'Operator': operator,
    'Cut date': ukDate(isoDate),
    'Start': r.start,
    'End': r.end,
    'Minutes': r.minutes ?? '',
    'Planned minutes': r.plannedMinutes ?? '',
    'Entry': mode === 'split' ? 'Split' : 'Whole',
    'Entered at': ukDateTime(enteredAt),
  }));

  const record = {
    submissionId, no, operator, date: isoDate, mode, rows, totalMinutes, enteredAt,
    status: 'pending', syncedAt: null, message: null,
  };

  // onlyIfNew: if two tablets submit the same program at once, only the first one is kept.
  const saved = await writeJSON(SUBMISSIONS, `sub-${no}`, record, { onlyIfNew: true });
  if (saved?.modified === false) return fail(409, `Program ${no} was just submitted on another tablet.`);

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
    await notify(`Cut times not sent: program ${no}`, [
      `Program ${no} was saved in the app but did not reach the master sheet.`,
      `Reason: ${sendError}`,
      `Operator: ${operator}`,
      `Cut date: ${ukDate(isoDate)}  Total: ${totalMinutes} min`,
      `Submission ID: ${submissionId}`,
      '',
      ...rows.map((r) => `${r.Customer}  ${r.JN}  ${r.Start}-${r.End}  ${r.Minutes} min`),
    ]);
    return json({ ok: true, saved: true, status: 'failed', submissionId, message: sendError });
  }

  return json({ ok: true, saved: true, status: 'pending', submissionId, totalMinutes });
};

export const config = { path: '/api/submit' };
