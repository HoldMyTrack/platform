import { Component, type ErrorInfo, type ReactNode } from 'react';
import { t } from './i18n';

/**
 * Catches a throw during render or in an effect anywhere below it, which would otherwise unmount
 * the app and leave an empty page under the server's header. Try again reloads the page: the
 * state that threw is gone with the tree, and a fresh start is the one known to work.
 */
export class ErrorBoundary extends Component<{ children: ReactNode }, { failed: boolean }> {
  override state = { failed: false };

  static getDerivedStateFromError(): { failed: boolean } {
    return { failed: true };
  }

  override componentDidCatch(error: unknown, info: ErrorInfo): void {
    console.error('app crashed', error, info.componentStack);
  }

  override render(): ReactNode {
    if (!this.state.failed) return this.props.children;
    return (
      <div className="app-load-error" role="alert">
        <p className="confirm-dialog__message">{t('app.crashed')}</p>
        <button type="button" className="settings-page__button" onClick={() => window.location.reload()}>
          {t('app.try_again')}
        </button>
      </div>
    );
  }
}
