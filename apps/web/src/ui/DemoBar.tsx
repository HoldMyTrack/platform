import { useState } from 'react';
import { Eye, X } from 'lucide-react';
import { DEMO_BAR_HIDE_MS, demoBarShown, readHiddenUntil } from './demoBar';
import { t } from '../i18n';

const STORAGE_KEY = 'hmt_demo_bar_hidden_until';

function storedHiddenUntil(): number | null {
  try {
    return readHiddenUntil(window.localStorage.getItem(STORAGE_KEY));
  } catch {
    return null;
  }
}

/**
 * The strip under the header in a demo session (demoBar.ts says when): what the demo is, and the
 * way to an account of one's own. The tour's last demo step lights its button
 * (`data-demo-bar-start`, tourRules.ts).
 */
export function DemoBar({ isDemo }: { isDemo: boolean }) {
  const [hiddenUntil, setHiddenUntil] = useState(storedHiddenUntil);
  if (!demoBarShown(isDemo, hiddenUntil, Date.now())) return null;

  const hide = () => {
    const until = Date.now() + DEMO_BAR_HIDE_MS;
    try {
      window.localStorage.setItem(STORAGE_KEY, String(until));
    } catch {
      // Hidden for this page only.
    }
    setHiddenUntil(until);
  };

  return (
    <div className="demo-bar" role="region" aria-label={t('demo_bar.label')} data-testid="demo-bar">
      <Eye size={18} className="demo-bar__icon" aria-hidden="true" />
      <p className="demo-bar__text">
        <span className="demo-bar__long">
          <strong>{t('demo_bar.lead')}</strong> {t('demo_bar.body')}
        </span>
        <span className="demo-bar__short">
          <strong>{t('demo_bar.short_lead')}</strong> {t('demo_bar.short_body')}
        </span>
      </p>
      <a className="demo-bar__start" href="/signup" data-demo-bar-start>
        <span className="demo-bar__long">{t('demo_bar.start')}</span>
        <span className="demo-bar__short">{t('demo_bar.start_short')}</span>
      </a>
      <button type="button" className="demo-bar__hide" onClick={hide} aria-label={t('demo_bar.hide')} title={t('demo_bar.hide')}>
        <X size={18} aria-hidden="true" />
      </button>
    </div>
  );
}