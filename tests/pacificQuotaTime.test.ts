import { expect, test } from 'bun:test';
import { pacificDayStart, pacificParts, shiftPacificDay } from '../src/utils/time/pacific';
import { formatInstantShort } from '../src/utils/quota/relativeTime';

test('UTC date boundaries resolve to the preceding Pacific calendar date', () => {
  const instant = Date.parse('2026-10-03T01:00:00Z');
  expect(pacificParts(instant).day).toBe(2);
  expect(pacificDayStart(instant)).toBe(Date.parse('2026-10-02T07:00:00Z'));
  expect(formatInstantShort(instant)).toContain('PDT');
});
test('Pacific calendar days handle spring and autumn DST without drifting midnight', () => {
  for (const [start, end, hours] of [
    ['2026-03-08T08:00:00Z', '2026-03-09T07:00:00Z', 23],
    ['2026-11-01T07:00:00Z', '2026-11-02T08:00:00Z', 25],
  ] as const) {
    const next = shiftPacificDay(Date.parse(start), 1);
    expect(next).toBe(Date.parse(end));
    expect((next - Date.parse(start)) / 3600000).toBe(hours);
    expect(pacificParts(next).hour).toBe(0);
  }
  expect(formatInstantShort(Date.parse('2026-11-02T08:00:00Z'))).toContain('PST');
});
