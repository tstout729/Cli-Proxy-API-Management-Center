import { describe, expect, test } from 'bun:test';
import { createElement } from 'react';
import { renderToStaticMarkup } from 'react-dom/server';
import '../src/i18n/index';
import {
  aggregateLedgerMetric,
  buildLedgerAccounts,
  buildLedgerGroups,
  clampLedgerPercent,
  formatLedgerReset,
  ledgerIdentity,
  maskQuotaIdentity,
  normalizeLedgerQuota,
  remainingFromUsed,
  weeklyResetFor,
} from '../src/features/quota/ledgerModel';
import { QuotaLedger } from '../src/features/quota/components/QuotaLedger';
import type { QuotaFileEntry } from '../src/features/quota/logic';
import type { QuotaCardState } from '../src/features/quota/providers';
import type { QuotaProviderType } from '../src/features/quota/providers/types';
import type { XaiBillingSummary } from '../src/types';

const now = Date.parse('2026-10-02T22:00:00Z');
const soon = Date.parse('2026-10-03T22:00:00Z');
const later = Date.parse('2026-10-06T22:00:00Z');
const entry = (type: QuotaProviderType, name = `${type}-account.json`): QuotaFileEntry => ({
  type,
  file: { name, type },
});
const window = (
  id: string,
  usedPercent: number | null,
  resetAtMs: number | null,
  periodHours: number
) => ({ id, label: id, resetLabel: '-', usedPercent, resetAtMs, periodHours });
const state = <T extends QuotaCardState>(value: T): T => value;

function xaiBilling(overrides: Partial<XaiBillingSummary> = {}): XaiBillingSummary {
  return {
    mode: 'billing',
    periodType: 'weekly',
    usagePercent: 5,
    productUsage: [],
    monthlyLimitCents: null,
    usedCents: null,
    includedUsedCents: null,
    onDemandCapCents: null,
    onDemandUsedCents: null,
    onDemandUsedPercent: null,
    usedPercent: null,
    resetAtMs: later,
    ...overrides,
  };
}

describe('quota ledger observations', () => {
  test('inverts used percentages, clamps remaining, and preserves missing/non-finite values', () => {
    expect(remainingFromUsed(83)).toBe(17);
    expect(remainingFromUsed(-10)).toBe(100);
    expect(remainingFromUsed(120)).toBe(0);
    expect(remainingFromUsed(null)).toBeNull();
    expect(remainingFromUsed(Number.NaN)).toBeNull();
    expect(remainingFromUsed(Number.POSITIVE_INFINITY)).toBeNull();
    expect(clampLedgerPercent(120)).toBe(100);
    expect(clampLedgerPercent(-1)).toBe(0);
  });

  test('orders Claude Fable, session and account weekly without losing scoped windows', () => {
    const normalized = normalizeLedgerQuota(
      'claude',
      state({
        status: 'success',
        planType: 'plan_max',
        windows: [
          window('seven-day', 21, later, 168),
          window('seven-day-sonnet', 30, soon, 168),
          window('five-hour', 0, soon, 5),
          window('seven-day-fable', 42, later, 168),
        ],
      })
    );
    expect(normalized.metrics.map((metric) => metric.id)).toEqual([
      'seven-day-fable',
      'five-hour',
      'seven-day',
      'seven-day-sonnet',
    ]);
    expect(normalized.metrics[0]?.remainingPercent).toBe(58);
    expect(normalized.metrics[0]?.scope).toBe('model');
    expect(normalized.metrics[2]?.scope).toBe('account');
    expect(normalized.planLabelKey).toBe('claude_quota.plan_max');
  });

  test('preserves optional Codex windows without treating them as account weekly capacity', () => {
    const codexEntry = entry('codex');
    const quota = state({
      status: 'success',
      windows: [
        window('gpt-5-3-codex-spark-weekly-0', 0, soon, 168),
        window('code-review-weekly', 0, soon, 168),
        window('five-hour', 0, soon, 5),
        window('weekly', 83, later, 168),
      ],
    });
    const groups = buildLedgerGroups(
      buildLedgerAccounts([codexEntry], () => quota, false, now),
      now
    );
    expect(groups[0]?.summary.metric?.id).toBe('weekly');
    expect(groups[0]?.summary.remainingPercent).toBe(17);
    expect(groups[0]?.summary.nextResetAtMs).toBe(later);
    expect(groups[0]?.accounts[0]?.metrics).toHaveLength(4);
    expect(weeklyResetFor(codexEntry, quota, now)).toBe(later);

    const scopedOnly = state({
      status: 'success',
      windows: [window('gpt-5-3-codex-spark-weekly-0', 0, soon, 168)],
    });
    expect(weeklyResetFor(codexEntry, scopedOnly, now)).toBeNull();
    const scopedSummary = buildLedgerGroups(
      buildLedgerAccounts([codexEntry], () => scopedOnly, false, now),
      now
    )[0]?.summary;
    expect(scopedSummary?.remainingPercent).toBeNull();
    expect(scopedSummary?.capacityPercent).toBeNull();
  });

  test('reads Kimi raw counts and keeps monthly limits distinct from weekly resets', () => {
    const quota = state({
      status: 'success',
      rows: [
        { id: 'session', used: 540, limit: 1000, resetAtMs: soon, periodHours: 5 },
        { id: 'monthly', used: 8100, limit: 30000, resetAtMs: later, periodHours: 720 },
        { id: 'unknown', used: 0, limit: 0 },
      ],
    });
    const normalized = normalizeLedgerQuota('kimi', quota);
    expect(normalized.metrics.find((metric) => metric.id === 'session')?.remainingPercent).toBe(46);
    expect(normalized.metrics.find((metric) => metric.id === 'monthly')?.remainingPercent).toBe(73);
    expect(
      normalized.metrics.find((metric) => metric.id === 'unknown')?.remainingPercent
    ).toBeNull();
    expect(weeklyResetFor(entry('kimi'), quota, now)).toBeNull();
  });

  test('reads Antigravity fractions as remaining and never sums separate model scopes', () => {
    const quota = state({
      status: 'success',
      groups: [
        {
          id: 'models',
          label: 'Models',
          buckets: [
            {
              id: 'one',
              label: 'Model one',
              remainingFraction: 0.4,
              periodHours: 168,
              resetAtMs: later,
            },
            {
              id: 'two',
              label: 'Model two',
              remainingFraction: 0.9,
              periodHours: 168,
              resetAtMs: soon,
            },
          ],
        },
      ],
    });
    const groups = buildLedgerGroups(
      buildLedgerAccounts([entry('antigravity')], () => quota, false, now),
      now
    );
    expect(groups[0]?.accounts[0]?.metrics.map((metric) => metric.remainingPercent)).toEqual([
      40, 90,
    ]);
    expect(groups[0]?.summary.remainingPercent).toBe(40);
    expect(groups[0]?.summary.capacityPercent).toBe(100);
  });

  test('reads Devin remaining directly and converts Meta Unix-second reset timestamps', () => {
    const devin = normalizeLedgerQuota(
      'devin',
      state({
        status: 'success',
        windows: [{ id: 'weekly', remainingPercent: 40, resetAtMs: later, periodHours: 168 }],
        plan: 'Ultra',
      })
    );
    expect(devin.metrics[0]?.remainingPercent).toBe(40);
    const meta = state({
      status: 'success',
      data: {
        planName: 'Pro',
        windows: [{ id: 'weekly', usedPercent: 25, resetAt: later / 1000 }],
      },
    });
    const metric = normalizeLedgerQuota('meta', meta).metrics[0];
    expect(metric?.remainingPercent).toBe(75);
    expect(metric?.resetAtMs).toBe(later);
    expect(metric?.periodHours).toBe(168);
    expect(weeklyResetFor(entry('meta'), meta, now)).toBe(later);
  });

  test('xAI uses weekly quota and does not invent quota from a paid health check or billing cycle', () => {
    const weekly = state({ status: 'success', billing: xaiBilling() });
    expect(normalizeLedgerQuota('xai', weekly).metrics[0]?.remainingPercent).toBe(95);
    expect(weeklyResetFor(entry('xai'), weekly, now)).toBe(later);
    for (const billing of [
      xaiBilling({ periodType: 'monthly' }),
      xaiBilling({
        mode: 'paid-health',
        periodType: 'unknown',
        usagePercent: null,
        planType: 'paid',
      }),
    ]) {
      const quota = state({ status: 'success', billing });
      const groups = buildLedgerGroups(
        buildLedgerAccounts([entry('xai')], () => quota, false, now),
        now
      );
      expect(groups[0]?.summary.remainingPercent).toBeNull();
      expect(groups[0]?.summary.capacityPercent).toBeNull();
      expect(weeklyResetFor(entry('xai'), quota, now)).toBeNull();
    }
  });
});

describe('quota ledger aggregates and weekly expiration ordering', () => {
  test('unknown, errored, loading and idle accounts do not contribute fabricated capacity', () => {
    const entries = ['idle', 'loading', 'error'].map((name) => entry('claude', `${name}.json`));
    const quotas: Record<string, QuotaCardState> = {
      'loading.json': { status: 'loading' },
      'error.json': { status: 'error', error: 'Unavailable' },
    };
    const accounts = buildLedgerAccounts(
      entries,
      (account) => quotas[account.file.name],
      false,
      now
    );
    const summary = buildLedgerGroups(accounts, now)[0]?.summary;
    expect(summary?.remainingPercent).toBeNull();
    expect(summary?.capacityPercent).toBeNull();
    expect(summary?.knownCount).toBe(0);
    expect(summary?.segments).toEqual([null, null, null]);
    expect(summary?.nextResetAtMs).toBeNull();
  });

  test('partial totals reflect only reported capacity and preserve unknown segments', () => {
    const entries = [entry('claude', 'known.json'), entry('claude', 'unknown.json')];
    const accounts = buildLedgerAccounts(
      entries,
      (account) =>
        account.file.name === 'known.json'
          ? state({ status: 'success', windows: [window('seven-day', 40, later, 168)] })
          : undefined,
      false,
      now
    );
    const summary = buildLedgerGroups(accounts, now)[0]?.summary;
    expect(summary?.remainingPercent).toBe(60);
    expect(summary?.capacityPercent).toBe(100);
    expect(summary?.knownCount).toBe(1);
    expect(summary?.totalCount).toBe(2);
    expect(summary?.segments).toEqual([60, null]);
  });

  test('combines only the selected weekly scope, matching the screenshot totals', () => {
    const fableRemaining = [58, 100, 100, 51, 100];
    const weeklyRemaining = [79, 100, 100, 75, 100];
    const entries = fableRemaining.map((_, index) => entry('claude', `${index}.json`));
    const accounts = buildLedgerAccounts(
      entries,
      (account) => {
        const index = Number.parseInt(account.file.name);
        return state({
          status: 'success',
          windows: [
            window(
              'seven-day-fable',
              100 - fableRemaining[index]!,
              index === 0 ? soon : later,
              168
            ),
            window('seven-day', 100 - weeklyRemaining[index]!, later, 168),
            window('five-hour', 0, now + 60000, 5),
          ],
        });
      },
      false,
      now
    );
    const group = buildLedgerGroups(accounts, now)[0];
    expect(group?.summary.remainingPercent).toBe(409);
    expect(group?.summary.capacityPercent).toBe(500);
    expect(group?.summary.nextResetAtMs).toBe(soon);
    expect(group?.secondarySummary?.remainingPercent).toBe(454);
  });

  test('does not mix Fable-only observations with unscoped account weekly observations', () => {
    const entries = [entry('claude', 'fable.json'), entry('claude', 'unscoped.json')];
    const accounts = buildLedgerAccounts(
      entries,
      (account) =>
        state({
          status: 'success',
          windows: [
            window(
              account.file.name === 'fable.json' ? 'seven-day-fable' : 'seven-day',
              20,
              later,
              168
            ),
          ],
        }),
      false,
      now
    );
    const summary = buildLedgerGroups(accounts, now)[0]?.summary;
    expect(summary?.remainingPercent).toBe(80);
    expect(summary?.capacityPercent).toBe(100);
    expect(summary?.segments).toEqual([80, null]);
  });

  test('weekly ordering uses account expiry, excludes 5-hour and past timestamps, and keeps exhausted accounts', () => {
    const claude = entry('claude');
    const quota = state({
      status: 'success',
      windows: [
        window('five-hour', 100, soon, 5),
        window('seven-day-fable', 10, soon, 168),
        window('seven-day', 100, later, 168),
      ],
    });
    expect(weeklyResetFor(claude, quota, now)).toBe(later);
    expect(weeklyResetFor(claude, quota, later)).toBeNull();
    const account = buildLedgerAccounts([claude], () => quota, false, now)[0]!;
    expect(account.weeklyResetAtMs).toBe(later);
    expect(account.metrics.find((metric) => metric.id === 'seven-day')?.remainingPercent).toBe(0);
    expect(aggregateLedgerMetric([account], account.metrics[2]!, now).capacityPercent).toBe(100);
  });

  test('invalid date values do not become reset instants', () => {
    const quota = state({
      status: 'success',
      windows: [window('weekly', 10, Number.MAX_VALUE, 168)],
    });
    expect(weeklyResetFor(entry('codex'), quota, now)).toBeNull();
    expect(normalizeLedgerQuota('codex', quota).metrics[0]?.resetAtMs).toBeNull();
  });
});

describe('quota ledger privacy and Pacific timestamps', () => {
  test('masks embedded emails, arbitrary filenames, and multi-identity display names', () => {
    expect(maskQuotaIdentity('claude-trevor@simplyvrm.com.json')).toBe('claude-t•••@s•••.com.json');
    expect(maskQuotaIdentity('work-account.json')).toBe('w•••.json');
    expect(maskQuotaIdentity('devin-work.json · trevor@simplyvrm.com')).toBe(
      'devin-w•••.json · t•••@s•••.com'
    );
    const file = { name: 'codex-work.json', email: 'person@example.com', type: 'codex' };
    expect(ledgerIdentity(file)).not.toContain('person@example.com');
    expect(ledgerIdentity(file)).not.toContain('codex-work.json');
    expect(ledgerIdentity(file, true)).toBe('codex-work.json · person@example.com');
  });

  test('formats Pacific date boundaries and the appropriate daylight/standard timezone label', () => {
    expect(formatLedgerReset(Date.parse('2026-10-03T01:00:00Z'))).toBe('10/02, 18:00 PDT');
    expect(formatLedgerReset(Date.parse('2026-12-03T01:00:00Z'))).toBe('12/02, 17:00 PST');
    expect(formatLedgerReset(Number.NaN)).toBe('—');
    expect(formatLedgerReset(Number.MAX_VALUE)).toBe('—');
  });

  test('markup masks identifiers in text, titles and action labels and offers known meters', () => {
    const account = entry('claude', 'claude-private@example.com.json');
    account.file.email = 'private@example.com';
    account.file.account = 'never-display-api-key';
    const quota = state({ status: 'success', windows: [window('seven-day', 25, later, 168)] });
    const markup = renderToStaticMarkup(
      createElement(QuotaLedger, {
        entries: [account],
        quotaFor: () => quota,
        resolvedTheme: 'dark',
        canRefresh: true,
        onRefresh: () => {},
        now,
      })
    );
    expect(markup).not.toContain('private@example.com');
    expect(markup).not.toContain('never-display-api-key');
    expect(markup).toContain('claude-p•••@e•••.com.json');
    expect(markup).toContain('role="meter"');
    expect(markup).toContain('aria-valuenow="75"');
    expect(markup).toContain('PDT');
  });

  test('summary includes all filtered accounts while rows contain only the current page', () => {
    const pageEntry = entry('codex', 'codex-page.json');
    const secondEntry = entry('codex', 'codex-other.json');
    const markup = renderToStaticMarkup(
      createElement(QuotaLedger, {
        entries: [pageEntry],
        summaryEntries: [pageEntry, secondEntry],
        quotaFor: () => state({ status: 'success', windows: [window('weekly', 25, later, 168)] }),
        resolvedTheme: 'dark',
        showEmails: true,
        canRefresh: false,
        onRefresh: () => {},
        now,
      })
    );
    expect(markup).toContain('150%');
    expect(markup).toContain('200%');
    expect(markup).toContain('codex-page.json');
    expect(markup).not.toContain('codex-other.json');
    expect(markup).toContain('disabled=""');
  });

  test('idle and loading rows retain their accessible load action without inventing meters', () => {
    const markup = renderToStaticMarkup(
      createElement(QuotaLedger, {
        entries: [entry('codex')],
        quotaFor: () => undefined,
        resolvedTheme: 'dark',
        canRefresh: true,
        onRefresh: () => {},
        now,
      })
    );
    expect(markup).toContain('role="status"');
    expect(markup).not.toContain('role="meter"');
    expect(markup).not.toContain('100%');
    expect(markup).toContain('aria-label=');
  });
});
