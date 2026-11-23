import { StrictMode, useEffect, useState } from 'react';
import { createRoot, type Root } from 'react-dom/client';
import { getCurrentUser, type SessionUser } from '../api.ts';
import { AuthProvider } from '../auth/AuthContext.tsx';
import { ErrorBoundary } from '../ErrorBoundary.tsx';
import { t } from '../i18n/index.ts';
import { setAccountTimeZone } from '../ui/timeZone.ts';
import { LibraryPage } from './LibraryPage.tsx';
import './library.css';

/**
 * The Library page's island (`docs/SPEC.md` FR-5.13), mounted into the Go server's /library page
 * (templates/pages/library.html) under its header. Like the map (App.tsx), it reads the session
 * first, and a session that ended goes to sign in.
 */
function Library() {
  const [user, setUser] = useState<SessionUser | { failed: string } | null>(null);
  useEffect(() => {
    getCurrentUser().then(
      (found) => {
        if (!found) window.location.replace('/signin');
        else {
          setAccountTimeZone(found.timezone);
          setUser(found);
        }
      },
      (err: unknown) =>
        setUser({
          failed: err instanceof TypeError ? t('common.network_error') : err instanceof Error ? err.message : String(err),
        }),
    );
  }, []);
  if (user === null) return null;
  if ('failed' in user) {
    return (
      <p className="library__empty" role="alert">
        {t('app.load_failed', { message: user.failed })}
      </p>
    );
  }
  return (
    <AuthProvider value={{ user }}>
      <LibraryPage />
    </AuthProvider>
  );
}

// The root is kept on its element: Vite's dev server can run this entry again on a hot update,
// and a second createRoot on the same element would mount a second copy of the page beside it.
const container = document.getElementById('library-root') as (HTMLElement & { libraryRoot?: Root }) | null;
if (container) {
  container.libraryRoot ??= createRoot(container);
  container.libraryRoot.render(
    <StrictMode>
      <ErrorBoundary>
        <Library />
      </ErrorBoundary>
    </StrictMode>,
  );
}
