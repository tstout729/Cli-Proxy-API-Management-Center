import { useTranslation } from 'react-i18next';
import { IconRefreshCw } from '@/components/ui/icons';
import {
  getAuthFileIcon,
  getThemeSurfaceIconBackground,
  getTypeLabel,
  isThemeSurfaceIconProvider,
} from '@/features/authFiles/constants';
import { useNow } from '@/hooks/useNow';
import type { ResolvedTheme } from '@/types';
import { formatRelativeInstant } from '@/utils/quota';
import {
  buildLedgerAccounts,
  buildLedgerGroups,
  formatLedgerReset,
  type LedgerAccount,
  type LedgerAggregate,
  type LedgerMetric,
} from '../ledgerModel';
import type { QuotaFileEntry } from '../logic';
import type { QuotaCardState } from '../providers';
import type { QuotaProviderType } from '../providers/types';
import styles from './QuotaLedger.module.scss';

export interface QuotaLedgerProps {
  entries: QuotaFileEntry[];
  /** Keep totals over the filtered results when account rows are paginated. */
  summaryEntries?: QuotaFileEntry[];
  quotaFor: (entry: QuotaFileEntry) => QuotaCardState | undefined;
  resolvedTheme: ResolvedTheme;
  showEmails?: boolean;
  canRefresh: boolean;
  onRefresh: (entry: QuotaFileEntry) => void;
  /** Fixed clock for deterministic previews and tests. */
  now?: number;
}

const percentLabel = (percent: number | null) =>
  percent === null ? '—' : `${Math.round(percent * 10) / 10}%`;

const fillClass = (percent: number | null) =>
  percent === null
    ? styles.fillUnknown
    : percent >= 70
      ? styles.fillHigh
      : percent >= 30
        ? styles.fillMedium
        : styles.fillLow;

function ProviderIcon({
  provider,
  resolvedTheme,
}: {
  provider: QuotaProviderType;
  resolvedTheme: ResolvedTheme;
}) {
  const src = getAuthFileIcon(provider, resolvedTheme);
  return (
    <span
      className={styles.providerIcon}
      style={
        isThemeSurfaceIconProvider(provider)
          ? { background: getThemeSurfaceIconBackground(resolvedTheme) }
          : undefined
      }
      aria-hidden="true"
    >
      {src ? <img src={src} alt="" /> : provider.slice(0, 1).toUpperCase()}
    </span>
  );
}

function ResetTime({ atMs, now }: { atMs: number | null; now: number }) {
  const { t, i18n } = useTranslation();
  if (atMs === null) {
    return (
      <span className={styles.resetUnknown}>
        {t('quota_management.ledger_reset_unknown', { defaultValue: 'Reset unavailable' })}
      </span>
    );
  }
  return (
    <time
      className={styles.resetTime}
      dateTime={new Date(atMs).toISOString()}
      title={formatLedgerReset(atMs)}
    >
      <span>{formatRelativeInstant(atMs, now, i18n.resolvedLanguage)}</span>
      <span className={styles.resetAbsolute}>{formatLedgerReset(atMs)}</span>
    </time>
  );
}

function Metric({ metric, now }: { metric: LedgerMetric; now: number }) {
  const { t } = useTranslation();
  const label = metric.labelKey
    ? t(metric.labelKey, { ...metric.labelParams, defaultValue: metric.label })
    : metric.label;
  const percent = metric.remainingPercent;
  return (
    <div className={styles.metric}>
      <div className={styles.metricHeading}>
        <span className={styles.metricLabel} title={label}>
          {label}
        </span>
        <strong className={styles.metricValue}>{percentLabel(percent)}</strong>
      </div>
      <div
        className={styles.track}
        role={percent === null ? 'img' : 'meter'}
        aria-label={
          percent === null
            ? `${label}: ${t('quota_management.ledger_unknown', { defaultValue: 'Quota unavailable' })}`
            : t('quota_management.ledger_metric_remaining', {
                label,
                defaultValue: '{{label}} remaining',
              })
        }
        aria-valuemin={percent === null ? undefined : 0}
        aria-valuemax={percent === null ? undefined : 100}
        aria-valuenow={percent ?? undefined}
        aria-valuetext={
          percent === null
            ? undefined
            : t('quota_management.ledger_percent_remaining', {
                percent: percentLabel(percent),
                defaultValue: '{{percent}} remaining',
              })
        }
      >
        <span
          className={`${styles.fill} ${fillClass(percent)}`}
          style={{ width: `${percent ?? 0}%` }}
        />
      </div>
      <ResetTime atMs={metric.resetAtMs} now={now} />
    </div>
  );
}

function Summary({
  provider,
  summary,
  secondary,
  resolvedTheme,
  now,
}: {
  provider: QuotaProviderType;
  summary: LedgerAggregate;
  secondary: LedgerAggregate | null;
  resolvedTheme: ResolvedTheme;
  now: number;
}) {
  const { t } = useTranslation();
  const providerLabel = getTypeLabel(t, provider);
  const metricLabel = summary.metric
    ? summary.metric.labelKey
      ? t(summary.metric.labelKey, {
          ...summary.metric.labelParams,
          defaultValue: summary.metric.label,
        })
      : summary.metric.label
    : t('quota_management.ledger_weekly_limit', { defaultValue: 'Weekly limit' });
  return (
    <article className={styles.summaryCard}>
      <div className={styles.summaryHeading}>
        <span className={styles.providerName}>
          <ProviderIcon provider={provider} resolvedTheme={resolvedTheme} />
          {providerLabel}
        </span>
        <span className={styles.credentialCount}>
          {t('quota_management.ledger_credentials', {
            count: summary.totalCount,
            defaultValue: '{{count}} credentials',
          })}
        </span>
      </div>
      <div className={styles.summaryLabel}>{metricLabel}</div>
      <div
        className={styles.summaryAmount}
        title={t('quota_management.ledger_aggregate_hint', {
          defaultValue: 'Totals add the remaining percentage for each reporting credential.',
        })}
      >
        <strong>{percentLabel(summary.remainingPercent)}</strong>
        {summary.capacityPercent !== null && (
          <span>
            {t('quota_management.ledger_capacity', {
              percent: percentLabel(summary.capacityPercent),
              defaultValue: 'of {{percent}}',
            })}
          </span>
        )}
      </div>
      <div
        className={styles.segmentedTrack}
        role="img"
        aria-label={t('quota_management.ledger_summary_remaining', {
          provider: providerLabel,
          label: metricLabel,
          percent: percentLabel(summary.remainingPercent),
          defaultValue: '{{provider}} {{label}}: {{percent}} remaining',
        })}
      >
        {summary.segments.map((percent, index) => (
          <span className={styles.segment} key={index}>
            <span
              className={`${styles.fill} ${fillClass(percent)}`}
              style={{ width: `${percent ?? 0}%` }}
            />
          </span>
        ))}
      </div>
      <ResetTime atMs={summary.nextResetAtMs} now={now} />
      {summary.knownCount < summary.totalCount && (
        <span className={styles.partialNote}>
          {t('quota_management.ledger_partial', {
            known: summary.knownCount,
            total: summary.totalCount,
            defaultValue: '{{known}} of {{total}} credentials reporting',
          })}
        </span>
      )}
      {secondary?.remainingPercent !== null && secondary?.metric && (
        <div className={styles.secondarySummary}>
          <span>
            {secondary.metric.labelKey
              ? t(secondary.metric.labelKey, { defaultValue: secondary.metric.label })
              : secondary.metric.label}
          </span>
          <strong>{percentLabel(secondary.remainingPercent)}</strong>
        </div>
      )}
    </article>
  );
}

function AccountRow({
  account,
  canRefresh,
  onRefresh,
  now,
}: {
  account: LedgerAccount;
  canRefresh: boolean;
  onRefresh: (entry: QuotaFileEntry) => void;
  now: number;
}) {
  const { t } = useTranslation();
  const loading = account.status === 'loading';
  const plan = account.planLabelKey
    ? t(account.planLabelKey, { defaultValue: account.planLabel ?? '' })
    : account.planLabel;
  const buttonLabel =
    account.status === 'idle'
      ? t('quota_management.ledger_load', { defaultValue: 'Load quota' })
      : loading
        ? t('quota_management.ledger_loading', { defaultValue: 'Loading quota' })
        : t('quota_management.ledger_refresh', { defaultValue: 'Refresh quota' });
  const message =
    account.status === 'error'
      ? t('quota_management.ledger_failed', { defaultValue: 'Could not load quota' })
      : loading
        ? t('quota_management.ledger_loading', { defaultValue: 'Loading quota' })
        : account.status === 'idle'
          ? t('quota_management.ledger_idle', { defaultValue: 'Load quota to view limits' })
          : account.messageKey
            ? t(account.messageKey)
            : t('quota_management.ledger_unknown', { defaultValue: 'Quota unavailable' });
  return (
    <article className={styles.accountRow} aria-busy={loading}>
      <div className={styles.accountIdentity}>
        <span className={styles.fileName} title={account.identity}>
          {account.identity}
        </span>
        {plan && <span className={styles.plan}>{plan}</span>}
      </div>
      {account.metrics.length > 0 ? (
        <div className={styles.metrics}>
          {account.metrics.map((metric) => (
            <Metric key={metric.id} metric={metric} now={now} />
          ))}
        </div>
      ) : (
        <span
          className={`${styles.rowMessage} ${account.status === 'error' ? styles.rowError : ''}`}
          role={account.status === 'error' ? 'alert' : 'status'}
        >
          {message}
        </span>
      )}
      <button
        className={styles.refreshButton}
        type="button"
        disabled={!canRefresh || loading}
        onClick={() => onRefresh(account.entry)}
        aria-label={t('quota_management.ledger_refresh_account', {
          action: buttonLabel,
          account: account.identity,
          defaultValue: '{{action}} for {{account}}',
        })}
      >
        <IconRefreshCw
          size={14}
          aria-hidden="true"
          className={loading ? styles.spinning : undefined}
        />
        {buttonLabel}
      </button>
    </article>
  );
}

export function QuotaLedger({
  entries,
  summaryEntries,
  quotaFor,
  resolvedTheme,
  showEmails = false,
  canRefresh,
  onRefresh,
  now: nowProp,
}: QuotaLedgerProps) {
  const { t } = useTranslation();
  const clock = useNow(nowProp === undefined);
  const now = nowProp ?? clock;
  const accounts = buildLedgerAccounts(entries, quotaFor, showEmails, now);
  const groups = buildLedgerGroups(accounts, now);
  const summaries = summaryEntries
    ? buildLedgerGroups(buildLedgerAccounts(summaryEntries, quotaFor, showEmails, now), now)
    : groups;

  return (
    <section
      className={styles.ledger}
      aria-label={t('quota_management.ledger_label', { defaultValue: 'Account quota ledger' })}
    >
      <div className={styles.summaryStrip}>
        {summaries.map((group) => (
          <Summary
            key={group.provider}
            provider={group.provider}
            summary={group.summary}
            secondary={group.secondarySummary}
            resolvedTheme={resolvedTheme}
            now={now}
          />
        ))}
      </div>
      <div className={styles.accountGroups}>
        {groups.map((group) => (
          <section
            className={styles.accountGroup}
            key={group.provider}
            aria-label={getTypeLabel(t, group.provider)}
          >
            <h2 className={styles.groupHeading}>
              {getTypeLabel(t, group.provider)}
              <span>{group.accounts.length}</span>
            </h2>
            {group.accounts.map((account) => (
              <AccountRow
                key={account.key}
                account={account}
                canRefresh={canRefresh}
                onRefresh={onRefresh}
                now={now}
              />
            ))}
          </section>
        ))}
      </div>
    </section>
  );
}
