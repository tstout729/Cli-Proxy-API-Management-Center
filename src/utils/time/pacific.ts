export const PACIFIC_TIME_ZONE = 'America/Los_Angeles';

const formatter = new Intl.DateTimeFormat('en-US', {
  timeZone: PACIFIC_TIME_ZONE,
  year: 'numeric',
  month: 'numeric',
  day: 'numeric',
  hour: 'numeric',
  minute: 'numeric',
  second: 'numeric',
  hourCycle: 'h23',
});

export function pacificParts(ms: number) {
  const parts = Object.fromEntries(
    formatter.formatToParts(ms).map((part) => [part.type, part.value])
  );
  const year = Number(parts.year),
    month = Number(parts.month),
    day = Number(parts.day);
  return {
    year,
    month,
    day,
    hour: Number(parts.hour),
    minute: Number(parts.minute),
    second: Number(parts.second),
    weekday: new Date(Date.UTC(year, month - 1, day)).getUTCDay(),
  };
}

/** Calendar conversion is offset-aware, including both Pacific DST transitions. */
export function pacificCalendarInstant(year: number, month: number, day: number, hour = 0): number {
  const target = Date.UTC(year, month - 1, day, hour);
  let instant = target;
  for (let attempt = 0; attempt < 3; attempt += 1) {
    const p = pacificParts(instant);
    const delta = target - Date.UTC(p.year, p.month - 1, p.day, p.hour, p.minute, p.second);
    if (delta === 0) break;
    instant += delta;
  }
  return instant;
}

export function pacificDayStart(ms: number): number {
  const p = pacificParts(ms);
  return pacificCalendarInstant(p.year, p.month, p.day);
}

export function shiftPacificDay(ms: number, days: number, hour = 0): number {
  const p = pacificParts(ms);
  const calendar = new Date(Date.UTC(p.year, p.month - 1, p.day + days));
  return pacificCalendarInstant(
    calendar.getUTCFullYear(),
    calendar.getUTCMonth() + 1,
    calendar.getUTCDate(),
    hour
  );
}
