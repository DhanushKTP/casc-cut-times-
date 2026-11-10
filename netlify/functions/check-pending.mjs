// Runs every 10 minutes. Emails you about submissions the master sheet hasn't confirmed in time.
// Nothing is resent: this only tells you, so you can check and fix it.
import { env, readJSON, updateJSON, nowLocal, ukDateTime, notify, SUBMISSIONS } from '../shared/core.mjs';

const asDate = (s) => new Date(`${String(s).slice(0, 19)}Z`); // both sides are UK local time

export default async () => {
  const limit = Number(env('NOTIFY_AFTER_MINUTES', '30')) || 30;
  const { data: status } = await readJSON(SUBMISSIONS, 'status', {});
  const now = asDate(nowLocal());
  const late = Object.entries(status || {})
    .filter(([, s]) => s.status === 'pending' && !s.notified && s.at && (now - asDate(s.at)) / 60e3 >= limit)
    .map(([no, s]) => ({ no, ...s }));
  if (!late.length) return new Response('nothing late');

  const sent = await notify(
    `Cut times not confirmed: ${late.length} program${late.length > 1 ? 's' : ''}`,
    [
      `These submissions were saved more than ${limit} minutes ago but the master sheet hasn't confirmed them.`,
      'Check the Power Automate run history and the master Excel.',
      '',
      ...late.map((s) => `Program ${s.no}  ·  ${s.operator}  ·  entered ${ukDateTime(s.at)}  ·  ${s.minutes} min  ·  ID ${s.submissionId}`),
    ],
  );
  if (sent) {
    await updateJSON(SUBMISSIONS, 'status', {}, (s) => {
      for (const l of late) if (s[l.no]?.status === 'pending') s[l.no].notified = true;
    });
  }
  return new Response(sent ? `notified ${late.length}` : 'notify failed');
};

export const config = { schedule: '*/10 * * * *' };
