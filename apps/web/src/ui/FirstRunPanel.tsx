import { useRef, type ReactNode } from 'react';
import { ChevronRight, FileUp, Lock, Route, Smartphone, Watch } from 'lucide-react';
import { StoryInboxItems } from './StoryInboxItems';
import type { StoryInboxState } from './useStoryInbox';
import { useImportsInFlight } from './useImportsInFlight';
import { t, tn } from '../i18n';

const PLAY_STORE_URL = 'https://play.google.com/store/apps/details?id=dev.holdmytrack.android';

/**
 * The Activities tab of an account with no activities (docs/SPEC.md FR-5.10; firstRun.ts says
 * when): the ways to bring some in, named by where people record rather than by file format,
 * with any Story copy waiting for the account first, since accepting one brings activities too.
 * The Strava and Garmin rows open their export guides; Files hands its pick to the header's
 * Upload menu as a drop on the map does (`hmt:upload-files`), so the menu shows its progress.
 */
export function FirstRunPanel({ inbox, onPrivacy }: { inbox: StoryInboxState; onPrivacy: () => void }) {
  const inFlight = useImportsInFlight();
  const fileInput = useRef<HTMLInputElement>(null);
  const hasInbox = inbox.sends.length > 0 || inbox.copying.length > 0;

  return (
    <div className="first-run" data-testid="first-run">
      {inFlight > 0 && (
        <p className="first-run__processing" role="status" data-testid="first-run-processing">
          {tn('first_run.processing', inFlight)}
        </p>
      )}
      <h2 className="first-run__title">{t('first_run.title')}</h2>
      <p className="first-run__lead">{t('first_run.lead')}</p>
      {hasInbox && (
        <ul className="first-run__inbox">
          <StoryInboxItems inbox={inbox} />
        </ul>
      )}
      <ul className="first-run__sources">
        <Source icon={<Route size={20} />} title={t('first_run.strava')} detail={t('first_run.strava_detail')} href="/import/strava" />
        <Source icon={<Watch size={20} />} title={t('first_run.garmin')} detail={t('first_run.garmin_detail')} href="/import/garmin" />
        <Source icon={<Smartphone size={20} />} title={t('first_run.android')} detail={t('first_run.android_detail')} href={PLAY_STORE_URL} />
        <Source
          icon={<FileUp size={20} />}
          title={t('first_run.files')}
          detail={t('first_run.files_detail')}
          onClick={() => fileInput.current?.click()}
        />
      </ul>
      <input
        ref={fileInput}
        type="file"
        accept=".gpx,.fit,.tcx"
        multiple
        hidden
        data-testid="first-run-file-input"
        onChange={(event) => {
          const files = event.currentTarget.files;
          if (files && files.length > 0) window.dispatchEvent(new CustomEvent('hmt:upload-files', { detail: files }));
          event.currentTarget.value = '';
        }}
      />
      <p className="first-run__nothing">
        <strong>{t('first_run.nothing_title')}</strong>{' '}
        <a href={PLAY_STORE_URL}>{t('first_run.nothing_link')}</a>
      </p>
      <p className="first-run__privacy">
        <Lock size={16} aria-hidden="true" />
        <span>
          {t('first_run.privacy')}{' '}
          <button type="button" className="first-run__link" onClick={onPrivacy}>
            {t('first_run.privacy_link')}
          </button>
        </span>
      </p>
    </div>
  );
}

function Source({ icon, title, detail, href, onClick }: { icon: ReactNode; title: string; detail: string; href?: string; onClick?: () => void }) {
  const body = (
    <>
      <span className="first-run__source-icon" aria-hidden="true">
        {icon}
      </span>
      <span className="first-run__source-text">
        <span className="first-run__source-title">{title}</span>
        <span className="first-run__source-detail">{detail}</span>
      </span>
      <ChevronRight size={16} className="first-run__source-chevron" aria-hidden="true" />
    </>
  );
  return (
    <li>
      {href ? (
        <a className="first-run__source" href={href}>
          {body}
        </a>
      ) : (
        <button type="button" className="first-run__source" onClick={onClick}>
          {body}
        </button>
      )}
    </li>
  );
}