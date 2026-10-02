import { useState } from 'react';
import { useTranslation } from 'react-i18next';
import { Select } from '@/components/ui/Select';
import { apiClient } from '@/services/api/client';
import { guardConfigConnection } from '@/services/api/configValue';
import { useConfigStore } from '@/stores';
import styles from './QuotaRoutingPolicy.module.scss';

export function QuotaRoutingPolicy({ disabled }: { disabled: boolean }) {
  const { t } = useTranslation();
  const strategy = useConfigStore((state) => state.config?.routingStrategy ?? 'round-robin');
  const [saving, setSaving] = useState(false);
  const [error, setError] = useState('');
  const active = strategy === 'weekly-reset-first';

  const changeStrategy = async (value: string) => {
    const checkConnection = guardConfigConnection();
    setSaving(true);
    setError('');
    try {
      await apiClient.put('/config/routing/strategy', value);
      checkConnection();
      useConfigStore.getState().updateConfigValue('routing/strategy', value);
    } catch (cause: unknown) {
      try {
        checkConnection();
        setError(cause instanceof Error ? cause.message : t('notification.save_failed'));
      } catch {
        /* The previous connection's result does not belong to this screen. */
      }
    } finally {
      setSaving(false);
    }
  };

  return (
    <div className={styles.policy}>
      <div className={styles.copy}>
        <span className={active ? styles.active : styles.inactive} aria-hidden="true" />
        <div>
          <strong>{t('quota_management.routing_title')}</strong>
          <p>{t(active ? 'quota_management.routing_active' : 'quota_management.routing_hint')}</p>
        </div>
      </div>
      <Select
        value={strategy}
        disabled={disabled || saving}
        size="sm"
        ariaLabel={t('quota_management.routing_title')}
        className={styles.select}
        fullWidth={false}
        options={[
          {
            value: 'weekly-reset-first',
            label: t('basic_settings.routing_strategy_weekly_reset_first'),
          },
          { value: 'round-robin', label: t('basic_settings.routing_strategy_round_robin') },
          {
            value: 'weighted-round-robin',
            label: t('basic_settings.routing_strategy_weighted_round_robin'),
          },
          { value: 'fill-first', label: t('basic_settings.routing_strategy_fill_first') },
        ]}
        onChange={(value) => void changeStrategy(value)}
      />
      {error && (
        <p className={styles.error} role="alert">
          {error}
        </p>
      )}
    </div>
  );
}
