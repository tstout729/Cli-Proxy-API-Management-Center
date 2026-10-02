import type {
  AntigravityQuotaState,
  AuthFileItem,
  ClaudeQuotaState,
  CodexQuotaState,
  DevinQuotaState,
  KimiQuotaState,
  MetaQuotaState,
  XaiQuotaState,
} from '@/types';
import { getQuotaCacheKey } from '@/utils/quota/identity';
import type { QuotaFileEntry } from './logic';
import type { QuotaCardState } from './providers';
import type { QuotaProviderType } from './providers/types';

export interface LedgerMetric {
  id: string;
  label: string;
  labelKey?: string;
  labelParams?: Record<string, string | number>;
  remainingPercent: number | null;
  resetAtMs: number | null;
  periodHours: number | null;
  scope: 'account' | 'model' | 'product';
}

export interface LedgerQuota {
  metrics: LedgerMetric[];
  planLabel: string | null;
  planLabelKey?: string;
  messageKey?: string;
}

export interface LedgerAccount extends LedgerQuota {
  key: string;
  entry: QuotaFileEntry;
  identity: string;
  status: QuotaCardState['status'];
  weeklyResetAtMs: number | null;
}

export interface LedgerAggregate {
  metric: LedgerMetric | null;
  remainingPercent: number | null;
  capacityPercent: number | null;
  knownCount: number;
  totalCount: number;
  segments: (number | null)[];
  nextResetAtMs: number | null;
}

export interface LedgerGroup {
  provider: QuotaProviderType;
  accounts: LedgerAccount[];
  summary: LedgerAggregate;
  secondarySummary: LedgerAggregate | null;
}

const WEEK_HOURS = 168;
const finiteNumber = (value: unknown): number | null =>
  typeof value === 'number' && Number.isFinite(value) ? value : null;
const timestampMs = (value: unknown): number | null => {
  const number = finiteNumber(value);
  return number !== null && Number.isFinite(new Date(number).getTime()) ? number : null;
};

export const clampLedgerPercent = (value: unknown): number | null => {
  const number = finiteNumber(value);
  return number === null ? null : Math.max(0, Math.min(100, number));
};

export const remainingFromUsed = (value: unknown): number | null => {
  const used = finiteNumber(value);
  return used === null ? null : clampLedgerPercent(100 - used);
};

/** Mask the entire identifier, including email addresses embedded in filenames. */
export function maskQuotaIdentity(value: string): string {
  return value
    .split(' · ')
    .map((part) => {
      const extension = part.toLowerCase().endsWith('.json') ? part.slice(-5) : '';
      const stem = extension ? part.slice(0, -5) : part;
      const prefix = stem.match(/^(claude|codex|antigravity|kimi|xai|devin|meta)-/i)?.[0] ?? '';
      const identifier = stem.slice(prefix.length);
      const at = identifier.indexOf('@');
      if (at !== -1) {
        const local = identifier.slice(0, at);
        const domain = identifier.slice(at + 1);
        const suffix = domain.includes('.') ? domain.slice(domain.lastIndexOf('.')) : '';
        const host = suffix ? domain.slice(0, -suffix.length) : domain;
        return `${prefix}${local.slice(0, 1)}•••@${host.slice(0, 1)}•••${suffix}${extension}`;
      }
      return `${prefix}${identifier.slice(0, 1)}•••${extension}`;
    })
    .join(' · ');
}

export function ledgerIdentity(file: AuthFileItem, showEmails = false): string {
  const email = file.email?.trim();
  const authIndex = file.authIndex == null ? '' : String(file.authIndex);
  const suffix = email || (file.type === 'devin' ? authIndex : '');
  const identity = suffix && !file.name.includes(suffix) ? `${file.name} · ${suffix}` : file.name;
  return showEmails ? identity : maskQuotaIdentity(identity);
}

/** A fixed timezone prevents browser locale settings from changing calendar dates. */
export function formatLedgerReset(atMs: number): string {
  if (timestampMs(atMs) === null) return '—';
  return new Intl.DateTimeFormat('en-US', {
    timeZone: 'America/Los_Angeles',
    month: '2-digit',
    day: '2-digit',
    hour: '2-digit',
    minute: '2-digit',
    hourCycle: 'h23',
    timeZoneName: 'short',
  }).format(atMs);
}

interface UsedWindow {
  id: string;
  label: string;
  labelKey?: string;
  labelParams?: Record<string, string | number>;
  usedPercent: number | null;
  resetAtMs?: number | null;
  periodHours?: number | null;
}

function usedWindowMetric(window: UsedWindow, scope: LedgerMetric['scope']): LedgerMetric {
  return {
    id: window.id,
    label: window.label,
    labelKey: window.labelKey,
    labelParams: window.labelParams,
    remainingPercent: remainingFromUsed(window.usedPercent),
    resetAtMs: timestampMs(window.resetAtMs),
    periodHours: finiteNumber(window.periodHours),
    scope,
  };
}

function orderMetrics(metrics: LedgerMetric[], ids: readonly string[]): LedgerMetric[] {
  const rank = (id: string) => {
    const index = ids.indexOf(id);
    return index === -1 ? ids.length : index;
  };
  return [...metrics].sort((a, b) => rank(a.id) - rank(b.id));
}

/** Adapters own fetching; this layer only reads their whitelisted quota observations. */
export function normalizeLedgerQuota(
  provider: QuotaProviderType,
  quota: QuotaCardState | undefined
): LedgerQuota {
  const empty: LedgerQuota = { metrics: [], planLabel: null };
  if (quota?.status !== 'success') return empty;

  if (provider === 'claude') {
    const state = quota as ClaudeQuotaState;
    const metrics = (state.windows ?? []).map((window) =>
      usedWindowMetric(
        window,
        window.id === 'five-hour' || window.id === 'seven-day' ? 'account' : 'model'
      )
    );
    return {
      metrics: orderMetrics(metrics, ['seven-day-fable', 'five-hour', 'seven-day']),
      planLabel: state.planType ?? null,
      planLabelKey: state.planType?.startsWith('plan_')
        ? `claude_quota.${state.planType}`
        : undefined,
    };
  }

  if (provider === 'codex') {
    const state = quota as CodexQuotaState;
    const metrics = (state.windows ?? []).map((window) =>
      usedWindowMetric(
        window,
        ['five-hour', 'weekly', 'monthly'].includes(window.id) ? 'account' : 'model'
      )
    );
    const plan = state.planType?.toLowerCase() ?? null;
    const planKey = plan?.replace(/-/g, '_');
    return {
      metrics: orderMetrics(metrics, ['weekly', 'five-hour', 'monthly']),
      planLabel: state.planType ?? null,
      planLabelKey:
        planKey && ['pro', 'plus', 'free', 'team', 'prolite', 'business_premium'].includes(planKey)
          ? `codex_quota.plan_${planKey}`
          : undefined,
    };
  }

  if (provider === 'devin') {
    const state = quota as DevinQuotaState;
    return {
      metrics: orderMetrics(
        (state.windows ?? []).map((window) => ({
          id: window.id,
          label: window.label ?? window.id,
          labelKey: `devin_quota.${window.id}`,
          remainingPercent: clampLedgerPercent(window.remainingPercent),
          resetAtMs: timestampMs(window.resetAtMs),
          periodHours: finiteNumber(window.periodHours),
          scope: 'account' as const,
        })),
        ['weekly', 'daily']
      ),
      planLabel: state.plan ?? null,
    };
  }

  if (provider === 'meta') {
    const state = quota as MetaQuotaState;
    return {
      metrics: orderMetrics(
        (state.data?.windows ?? []).map((window) => ({
          id: window.id,
          label: window.id,
          labelKey:
            window.id === 'window' && window.durationMinutes
              ? 'meta_quota.window_duration'
              : `meta_quota.${window.id}`,
          labelParams: window.durationMinutes ? { minutes: window.durationMinutes } : undefined,
          remainingPercent: remainingFromUsed(window.usedPercent),
          resetAtMs: window.resetAt === undefined ? null : timestampMs(window.resetAt * 1000),
          periodHours:
            window.id === 'weekly' ? WEEK_HOURS : (window.durationMinutes ?? 0) / 60 || null,
          scope: 'account' as const,
        })),
        ['weekly', 'window']
      ),
      planLabel: state.data?.planName ?? null,
    };
  }

  if (provider === 'kimi') {
    const state = quota as KimiQuotaState;
    const metrics = (state.rows ?? []).map((row): LedgerMetric => {
      const used = finiteNumber(row.used);
      const limit = finiteNumber(row.limit);
      return {
        id: row.id,
        label: row.label ?? row.id,
        labelKey: row.labelKey,
        labelParams: row.labelParams,
        remainingPercent:
          used !== null && limit !== null && limit > 0
            ? clampLedgerPercent(((limit - used) / limit) * 100)
            : null,
        resetAtMs: timestampMs(row.resetAtMs),
        periodHours: finiteNumber(row.periodHours),
        scope: 'account',
      };
    });
    return {
      ...empty,
      metrics: [...metrics].sort((a, b) => (b.periodHours ?? 0) - (a.periodHours ?? 0)),
    };
  }

  if (provider === 'antigravity') {
    const state = quota as AntigravityQuotaState;
    return {
      metrics: (state.groups ?? []).flatMap((group) =>
        group.buckets.map((bucket) => ({
          id: `${group.id}:${bucket.id}`,
          label: bucket.label,
          remainingPercent:
            finiteNumber(bucket.remainingFraction) === null
              ? null
              : clampLedgerPercent(bucket.remainingFraction * 100),
          resetAtMs: timestampMs(bucket.resetAtMs),
          periodHours: finiteNumber(bucket.periodHours),
          scope: 'model' as const,
        }))
      ),
      planLabel: state.subscription?.tierName ?? state.subscription?.plan ?? null,
      planLabelKey:
        state.subscription?.plan &&
        ['free', 'pro', 'ultra', 'ultra-lite'].includes(state.subscription.plan)
          ? `antigravity_subscription.plan_${state.subscription.plan.replace(/-/g, '_')}`
          : undefined,
    };
  }

  const state = quota as XaiQuotaState;
  const billing = state.billing;
  if (!billing) return empty;
  const weekly: LedgerMetric[] =
    billing.mode !== 'paid-health' && billing.periodType === 'weekly'
      ? [
          {
            id: 'weekly',
            label: 'Weekly limit',
            labelKey: 'xai_quota.weekly_limit',
            remainingPercent: remainingFromUsed(billing.usagePercent),
            resetAtMs: timestampMs(billing.resetAtMs),
            periodHours: WEEK_HOURS,
            scope: 'account',
          },
        ]
      : [];
  return {
    metrics: [
      ...weekly,
      ...(billing.productUsage ?? []).map((product) => ({
        id: `product:${product.product}`,
        label: product.product,
        remainingPercent: remainingFromUsed(product.usagePercent),
        resetAtMs: weekly[0]?.resetAtMs ?? null,
        periodHours: weekly[0]?.periodHours ?? null,
        scope: 'product' as const,
      })),
    ],
    planLabel: billing.planLabel ?? (billing.planType === 'paid' ? 'Paid' : null),
    planLabelKey:
      billing.planType === 'paid' && !billing.planLabel ? 'xai_quota.plan_paid' : undefined,
    messageKey: billing.mode === 'paid-health' ? 'xai_quota.paid_health' : undefined,
  };
}

function selectWeeklyMetric(provider: QuotaProviderType, metrics: LedgerMetric[]) {
  const weekly = metrics.filter((metric) => metric.periodHours === WEEK_HOURS);
  if (provider === 'claude') {
    return (
      weekly.find((metric) => metric.id === 'seven-day') ??
      weekly.find((metric) => metric.id === 'seven-day-fable') ??
      null
    );
  }
  if (provider === 'codex') return weekly.find((metric) => metric.id === 'weekly') ?? null;
  return weekly.find((metric) => metric.scope === 'account') ?? weekly[0] ?? null;
}

/** Account weekly resets remain independent of rolling and model-only Codex windows. */
export function weeklyResetFor(
  entry: QuotaFileEntry,
  quota: QuotaCardState | undefined,
  now = Date.now()
): number | null {
  const metric = selectWeeklyMetric(entry.type, normalizeLedgerQuota(entry.type, quota).metrics);
  return metric?.resetAtMs != null && metric.resetAtMs > now ? metric.resetAtMs : null;
}

export function buildLedgerAccounts(
  entries: QuotaFileEntry[],
  quotaFor: (entry: QuotaFileEntry) => QuotaCardState | undefined,
  showEmails = false,
  now = Date.now()
): LedgerAccount[] {
  return entries.map((entry) => {
    const quota = quotaFor(entry);
    const normalized = normalizeLedgerQuota(entry.type, quota);
    const weekly = selectWeeklyMetric(entry.type, normalized.metrics);
    return {
      ...normalized,
      key: getQuotaCacheKey(entry.file),
      entry,
      identity: ledgerIdentity(entry.file, showEmails),
      status: quota?.status ?? 'idle',
      weeklyResetAtMs:
        weekly?.resetAtMs != null && weekly.resetAtMs > now ? weekly.resetAtMs : null,
    };
  });
}

export function aggregateLedgerMetric(
  accounts: LedgerAccount[],
  metric: LedgerMetric | null,
  now = Date.now()
): LedgerAggregate {
  const observations = accounts.map((account) =>
    metric ? account.metrics.find((candidate) => candidate.id === metric.id) : undefined
  );
  const segments = observations.map((observation) => observation?.remainingPercent ?? null);
  const known = segments.filter((percent): percent is number => percent !== null);
  const futureResets = observations
    .map((observation) => observation?.resetAtMs)
    .filter((atMs): atMs is number => atMs != null && atMs > now);
  return {
    metric,
    remainingPercent:
      known.length > 0 ? Math.round(known.reduce((sum, value) => sum + value, 0) * 10) / 10 : null,
    capacityPercent: known.length > 0 ? known.length * 100 : null,
    knownCount: known.length,
    totalCount: accounts.length,
    segments,
    nextResetAtMs: futureResets.length > 0 ? Math.min(...futureResets) : null,
  };
}

function summaryMetric(
  provider: QuotaProviderType,
  accounts: LedgerAccount[]
): LedgerMetric | null {
  const metrics = accounts.flatMap((account) => account.metrics);
  if (provider === 'claude') {
    return (
      metrics.find((metric) => metric.id === 'seven-day-fable') ??
      metrics.find((metric) => metric.id === 'seven-day') ??
      null
    );
  }
  if (provider === 'codex') {
    return (
      metrics.find((metric) => metric.id === 'weekly') ??
      metrics.find((metric) => metric.id === 'monthly') ??
      null
    );
  }
  const weekly = selectWeeklyMetric(provider, metrics);
  if (weekly) return weekly;
  // xAI billing cycles and per-product observations are not account quota capacity.
  if (provider === 'xai') return null;
  return [...metrics].sort((a, b) => (b.periodHours ?? 0) - (a.periodHours ?? 0))[0] ?? null;
}

export function buildLedgerGroups(accounts: LedgerAccount[], now = Date.now()): LedgerGroup[] {
  const groups = new Map<QuotaProviderType, LedgerAccount[]>();
  accounts.forEach((account) => {
    const group = groups.get(account.entry.type) ?? [];
    group.push(account);
    groups.set(account.entry.type, group);
  });
  return [...groups].map(([provider, groupAccounts]) => {
    const primary = summaryMetric(provider, groupAccounts);
    const secondary =
      provider === 'claude' && primary?.id === 'seven-day-fable'
        ? (groupAccounts
            .flatMap((account) => account.metrics)
            .find((metric) => metric.id === 'seven-day') ?? null)
        : null;
    return {
      provider,
      accounts: groupAccounts,
      summary: aggregateLedgerMetric(groupAccounts, primary, now),
      secondarySummary: secondary ? aggregateLedgerMetric(groupAccounts, secondary, now) : null,
    };
  });
}
