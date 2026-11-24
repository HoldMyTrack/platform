import { useCallback, useEffect, useMemo, useRef, useState } from 'react';
import { Download, Lock, Trash2, X } from 'lucide-react';
import { appBridge } from './appBridge.ts';
import { deleteTrack, downloadTracksGpx, listTrackPage, listTrips, type LibraryTrack, type TrackPageResult } from '../api.ts';
import { useAuth } from '../auth/AuthContext.tsx';
import { t, tn } from '../i18n/index.ts';
import { CheckAllMenu } from '../ui/CheckAllMenu.tsx';
import { ConfirmDialog } from '../ui/ConfirmDialog.tsx';
import { dateFilterBounds, setDateFilter } from '../ui/dateFilter.ts';
import { todayIn } from '../ui/dateMath.ts';
import { formatDistance, formatDuration, formatShortDate, formatTotalDistance, formatTrackType } from '../ui/format.ts';
import { rowLabel } from '../ui/TrackRow.tsx';
import { saveFile } from '../ui/saveFile.ts';
import { FilterDropdown, TrackFilters } from '../ui/TrackFilters.tsx';
import { typeIcon } from '../ui/trackKindIcon.ts';
import { useUnitSystem } from '../ui/units.ts';
import {
  anyFilter,
  ariaSort,
  emptyReason,
  firstBlocked,
  keepListed,
  libraryUrl,
  mapHref,
  pageQuery,
  pager,
  parseLibraryUrl,
  sortBy,
  withFilter,
  type LibraryState,
  type SortKey,
} from './libraryState.ts';

type Load = { state: 'loading' } | { state: 'failed'; message: string } | { state: 'ready'; result: TrackPageResult };

const COLUMNS: readonly { key: SortKey; label: () => string }[] = [
  { key: 'started', label: () => t('library.col_started') },
  { key: 'distance', label: () => t('library.col_distance') },
  { key: 'moving', label: () => t('library.col_moving') },
  { key: 'added', label: () => t('library.col_added') },
];

/**
 * The Library page (`docs/SPEC.md` FR-5.13): every track the account keeps, a page of 100 at a
 * time, with the Tracks panel's filters, Check all and delete dialog. Each row has its own Download
 * and Delete; the Checked rows' are in a bar at the window's foot. Its state lives in the URL
 * (libraryState.ts), so Back and a shared link reopen the same page. Checked stays within the
 * page: another page, sort or filter clears it.
 */
export function LibraryPage() {
  const { user } = useAuth();
  const system = useUnitSystem();
  const readOnly = !('email' in user);
  const today = todayIn(user.timezone);

  const [state, setState] = useState<LibraryState>(() => parseLibraryUrl(window.location.search));
  const [load, setLoad] = useState<Load>({ state: 'loading' });
  // Every type the account has, from the last answer: the Type filter is sent as the types kept.
  const [allTypes, setAllTypes] = useState<string[] | null>(null);
  const [trips, setTrips] = useState<{ id: string; name: string }[]>([]);
  const [checked, setChecked] = useState<Set<string>>(new Set());
  const [reload, setReload] = useState(0);
  const [search, setSearch] = useState(state.q);
  const [message, setMessage] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  // The tracks the Delete dialog is asking about: one row's, or the Checked ones.
  const [deleting, setDeleting] = useState<LibraryTrack[] | null>(null);
  // The Distance slider as it is dragged, applied once it rests (below).
  const [draftDistance, setDraftDistance] = useState<{ value: LibraryState['distance'] } | null>(null);
  // The last bounds read: the filters keep their choices while a page is loading, has failed or
  // asks for nothing.
  const lastBounds = useRef<TrackPageResult['bounds'] | null>(null);

  // A change of state is a new entry in the history; Back reads the URL again.
  const go = useCallback((next: LibraryState) => {
    window.history.pushState(null, '', window.location.pathname + libraryUrl(next));
    setState(next);
    setSearch(next.q);
    setChecked(new Set());
    setMessage(null);
  }, []);
  useEffect(() => {
    const onPop = () => {
      const next = parseLibraryUrl(window.location.search);
      setState(next);
      setSearch(next.q);
      setChecked(new Set());
      setDraftDistance(null);
      setMessage(null);
    };
    window.addEventListener('popstate', onPop);
    return () => window.removeEventListener('popstate', onPop);
  }, []);

  // The Distance slider as it is dragged: applied once it rests, so a drag is one history entry
  // and one request, not one per step.
  useEffect(() => {
    if (draftDistance === null) return;
    const timer = setTimeout(() => {
      setDraftDistance(null);
      go(withFilter(state, { distance: draftDistance.value }));
    }, 400);
    return () => clearTimeout(timer);
  }, [draftDistance, state, go]);

  useEffect(() => {
    const controller = new AbortController();
    listTrips(controller.signal).then(
      (list) => setTrips(list.map((trip) => ({ id: trip.id, name: trip.name }))),
      () => {},
    );
    return () => controller.abort();
  }, []);

  useEffect(() => {
    // With types left out but none known yet, the first answer is asked without the Type filter
    // and used only for its bounds, still loading; the effect then runs again with them.
    const probing = state.exclude.length > 0 && allTypes === null;
    const query = pageQuery(state, allTypes ?? []);
    const controller = new AbortController();
    if (query === null) {
      // Every type left out: nothing matches, and there is nothing to ask.
      const bounds = lastBounds.current;
      if (bounds !== null) setLoad({ state: 'ready', result: { tracks: [], total: 0, pageSize: 100, bounds } });
      return () => controller.abort();
    }
    setLoad((prev) => (prev.state === 'ready' && !probing ? prev : { state: 'loading' }));
    listTrackPage(query, controller.signal).then(
      (result) => {
        lastBounds.current = result.bounds;
        const types = result.bounds.types.map((c) => c.type);
        setAllTypes((prev) => (prev !== null && prev.join() === types.join() ? prev : types));
        if (probing) return;
        setLoad({ state: 'ready', result });
        setChecked((prev) => keepListed(prev, result.tracks));
      },
      (err: unknown) => {
        if (controller.signal.aborted) return;
        setLoad({
          state: 'failed',
          message: err instanceof Error ? err.message : String(err),
        });
      },
    );
    return () => controller.abort();
  }, [state, allTypes, reload]);

  const result = load.state === 'ready' ? load.result : null;
  const rows = useMemo(() => result?.tracks ?? [], [result]);
  const checkable = rows.filter((row) => !row.pending);
  const target = rows.filter((row) => checked.has(row.id));
  const blocked = firstBlocked(rows, checked);

  const toggle = (id: string) =>
    setChecked((prev) => {
      const next = new Set(prev);
      if (next.has(id)) next.delete(id);
      else next.add(id);
      return next;
    });

  // Download and Delete act on one row's icons or on the Checked rows' bar alike.
  const download = async (rows: readonly LibraryTrack[]) => {
    const bridge = appBridge();
    if (bridge) {
      bridge.downloadGpx(rows.map((row) => row.id).join(','));
      return;
    }
    setBusy(true);
    setMessage(t('library.downloading'));
    try {
      const { blob, name } = await downloadTracksGpx(rows.map((row) => row.id));
      saveFile(blob, name);
      setMessage(null);
    } catch (err) {
      setMessage(err instanceof Error ? err.message : String(err));
    } finally {
      setBusy(false);
    }
  };
  /** "“Morning ride” (6.4 mi)" or "3 checked tracks (12 mi)", as the panel's dialogs name a group. */
  const groupSummary = (rows: readonly LibraryTrack[]) =>
    t('tracks.group_summary', {
      name: rows.length === 1 && rows[0] ? t('tracks.target_one', { label: rowLabel(rows[0]) }) : tn('tracks.checked_count', rows.length),
      distance: formatTotalDistance(
        rows.reduce((sum, a) => sum + (a.distanceMeters ?? 0), 0),
        system,
      ),
    });

  const bounds = result?.bounds ?? lastBounds.current;
  const facets = bounds?.types ?? [];
  const excluded = new Set(state.exclude);
  const datesBounds = dateFilterBounds(bounds?.firstDate ?? null, bounds?.lastDate ?? null, today);
  // A Distance from a URL with one end left out is 0 or Infinity: the slider shows that end at
  // the bound.
  const shownDistance = draftDistance !== null ? draftDistance.value : state.distance;
  const distanceFilter =
    shownDistance !== null && bounds?.distance
      ? { min: Math.max(shownDistance.min, bounds.distance.min), max: Math.min(shownDistance.max, bounds.distance.max) }
      : shownDistance;
  const pages = result ? pager(state.page, result.total, result.pageSize) : null;

  const downloadTitle =
    blocked !== null ? t('library.download_blocked', { track: rowLabel(blocked), reason: t(`library.blocked_${blocked.blocked}`) }) : undefined;

  return (
    <div className="library">
      {/* The title and how many tracks pass the filters, on one line: that number answers
          "how many", so it sits by the heading. */}
      <div className="library__head">
        <h1 className="profile__title library__heading">{t('library.title')}</h1>
        {result && <span className="library__count">{anyFilter(state) ? tn('library.matching', result.total) : tn('library.count', result.total)}</span>}
      </div>

      <div className="library__controls">
        <div className="library__filter-row">
          <TrackFilters
            facets={facets}
            excludedTypes={excluded}
            onToggleType={(type) =>
              go(
                withFilter(state, {
                  exclude: excluded.has(type) ? state.exclude.filter((x) => x !== type) : [...state.exclude, type],
                }),
              )
            }
            distanceBounds={bounds?.distance ?? null}
            distanceFilter={distanceFilter}
            onChangeDistance={(distance) => setDraftDistance({ value: distance })}
            dates={{
              value: state.dates,
              bounds: datesBounds,
              earliest: bounds?.firstDate ?? null,
              today,
              onChange: (end, value) => {
                const { filter } = setDateFilter(state.dates, end, value, datesBounds);
                go(withFilter(state, { dates: filter }));
              },
              onClear: () => go(withFilter(state, { dates: { after: null, before: null } })),
            }}
          />
          {(trips.length > 0 || state.trip !== null) && <TripFilter trips={trips} value={state.trip} onChange={(trip) => go(withFilter(state, { trip }))} />}
        </div>
        <form
          className="library__search"
          role="search"
          onSubmit={(e) => {
            e.preventDefault();
            if (search.trim() !== state.q) go(withFilter(state, { q: search.trim() }));
          }}
        >
          <input
            className="library__search-input"
            type="search"
            value={search}
            maxLength={200}
            placeholder={t('library.search_placeholder')}
            aria-label={t('library.search_label')}
            onChange={(e) => setSearch(e.target.value)}
            onBlur={() => {
              if (search.trim() !== state.q) go(withFilter(state, { q: search.trim() }));
            }}
          />
        </form>
      </div>

      {load.state === 'failed' && (
        <p className="library__empty" role="alert">
          {load.message}{' '}
          <button type="button" className="library__link" onClick={() => setReload((n) => n + 1)}>
            {t('app.try_again')}
          </button>
        </p>
      )}
      {load.state === 'loading' && <p className="library__empty">{t('library.loading')}</p>}
      {result && rows.length === 0 && <EmptyMessage state={state} result={result} onFirstPage={() => go({ ...state, page: 1 })} />}

      {rows.length > 0 && (
        <table className="library__table">
          <thead>
            <tr>
              <th className="library__cell--check" scope="col">
                {/* The panel's Check all and its menu, heading the checkbox column. */}
                <span className="library__check-all">
                  <CheckAllMenu
                    total={checkable.length}
                    checkedCount={target.length}
                    onAll={() => setChecked(new Set(checkable.map((row) => row.id)))}
                    onNone={() => setChecked(new Set())}
                    onInvert={() => setChecked(new Set(checkable.filter((row) => !checked.has(row.id)).map((row) => row.id)))}
                  />
                </span>
              </th>
              <th scope="col">{t('library.col_track')}</th>
              {COLUMNS.map((col) => (
                <th key={col.key} className="library__cell--num" scope="col" aria-sort={ariaSort(state, col.key)}>
                  <button type="button" className="library__sort" onClick={() => go(sortBy(state, col.key))}>
                    {col.label()}
                    {ariaSort(state, col.key) === 'descending' ? ' ↓' : ariaSort(state, col.key) === 'ascending' ? ' ↑' : ''}
                  </button>
                </th>
              ))}
              <th className="library__cell--actions" scope="col">
                <span className="visually-hidden">{t('library.col_actions')}</span>
              </th>
            </tr>
          </thead>
          <tbody>
            {rows.map((row) => (
              <LibraryRow
                key={row.id}
                row={row}
                accountZone={user.timezone}
                checked={checked.has(row.id)}
                onToggle={() => toggle(row.id)}
                actions={{ readOnly, busy, onDownload: () => void download([row]), onDelete: () => setDeleting([row]) }}
              />
            ))}
          </tbody>
        </table>
      )}

      {pages !== null && (pages.prev || pages.next) && (
        <nav className="library__pager" aria-label={t('library.pages')}>
          <button type="button" className="settings-page__button" disabled={!pages.prev} onClick={() => go({ ...state, page: state.page - 1 })}>
            {t('library.previous')}
          </button>
          <span className="library__range">
            {t('library.range', {
              from: pages.from,
              to: pages.to,
              total: result?.total ?? 0,
            })}
          </span>
          <button type="button" className="settings-page__button" disabled={!pages.next} onClick={() => go({ ...state, page: state.page + 1 })}>
            {t('library.next')}
          </button>
        </nav>
      )}

      {/* The Checked rows' actions, pinned to the window's foot while any is checked. */}
      {(target.length > 0 || message !== null) && (
        <div className="library__bar" role="region" aria-label={t('library.bar_label')}>
          {message !== null && (
            <p className="library__bar-message" role="status">
              {message}
            </p>
          )}
          {target.length > 0 && (
            <div className="library__bar-row">
              <span className="library__bar-count">{groupSummary(target)}</span>
              <button
                type="button"
                className="library__bar-button"
                disabled={busy || blocked !== null}
                onClick={() => void download(target)}
                title={downloadTitle}
              >
                <Download size={16} aria-hidden="true" />
                {t('library.download')}
              </button>
              {!readOnly && (
                <button
                  type="button"
                  className="library__bar-button library__bar-button--danger"
                  disabled={busy || target.some((row) => row.pending)}
                  onClick={() => setDeleting(target)}
                >
                  <Trash2 size={16} aria-hidden="true" />
                  {t('library.delete')}
                </button>
              )}
              <button
                type="button"
                className="library__bar-clear"
                aria-label={t('tracks.select_none')}
                title={t('tracks.select_none')}
                onClick={() => {
                  setChecked(new Set());
                  setMessage(null);
                }}
              >
                <X size={16} />
              </button>
            </div>
          )}
        </div>
      )}

      {deleting !== null && (
        <ConfirmDialog
          title={deleting.length === 1 ? t('tracks.delete_one_title') : t('tracks.delete_title')}
          message={
            deleting.length === 1
              ? t('tracks.delete_one_body', { group: groupSummary(deleting) })
              : t('tracks.delete_many_body', { group: groupSummary(deleting) })
          }
          confirmLabel={t('tracks.delete_confirm')}
          busyLabel={t('common.deleting')}
          onConfirm={async () => {
            // One at a time, as the panel deletes (TracksToolbar.tsx); those deleted stay deleted
            // when a later one fails, and the dialog's retry deletes only the rest.
            const deleted: string[] = [];
            try {
              for (const row of deleting) {
                if (deleted.includes(row.id)) continue;
                await deleteTrack(row.id);
                deleted.push(row.id);
              }
            } finally {
              if (deleted.length > 0) {
                setChecked((prev) => new Set([...prev].filter((id) => !deleted.includes(id))));
                setReload((n) => n + 1);
              }
            }
          }}
          onClose={() => setDeleting(null)}
        />
      )}
    </div>
  );
}

interface RowActions {
  readOnly: boolean;
  busy: boolean;
  onDownload: () => void;
  onDelete: () => void;
}

function LibraryRow({
  row,
  accountZone,
  checked,
  onToggle,
  actions,
}: {
  row: LibraryTrack;
  accountZone: string | undefined;
  checked: boolean;
  onToggle: () => void;
  actions: RowActions;
}) {
  const system = useUnitSystem();
  const label = rowLabel(row);
  const TypeIcon = typeIcon(row.trackType);
  const day = todayIn(row.timezone, new Date(row.startedAt));
  const href = mapHref(row.id, day);
  return (
    <tr className={row.pending ? 'library__row library__row--pending' : 'library__row'}>
      <td className="library__cell--check">
        <input
          type="checkbox"
          className="tracks-panel__checkbox"
          checked={checked}
          disabled={row.pending && !checked}
          aria-label={checked ? t('tracks.row_uncheck', { label }) : t('tracks.row_check', { label })}
          onChange={onToggle}
        />
      </td>
      <td className="library__track">
        <span className="library__track-inner">
          <TypeIcon className="tracks-panel__type-icon" size={18} aria-hidden="true" />
          <span className="library__track-text">
            <a className="library__title" href={href}>
              {label}
            </a>
            <span className="library__meta">
              {formatTrackType(row.trackType)}
              {row.pending && (
                <span className="tracks-panel__hidden-badge" title={t('tracks.pending_title')}>
                  {t('tracks.pending')}
                </span>
              )}
              {row.private && !row.pending && (
                <span className="tracks-panel__hidden-badge tracks-panel__private-badge" title={t('tracks.private_title')}>
                  <Lock size={10} aria-hidden="true" />
                  {t('tracks.private')}
                </span>
              )}
              {row.trips.map((trip) => (
                <span key={trip.id} className="tracks-panel__hidden-badge library__trip-badge">
                  {trip.name}
                </span>
              ))}
            </span>
          </span>
        </span>
      </td>
      <td className="library__cell--num" data-label={t('library.col_started')}>
        {formatShortDate(day)}
      </td>
      <td className="library__cell--num" data-label={t('library.col_distance')}>
        {row.private ? '' : formatDistance(row.distanceMeters, system)}
      </td>
      <td className="library__cell--num" data-label={t('library.col_moving')}>
        {row.private ? '' : formatDuration(row.movingSeconds)}
      </td>
      <td className="library__cell--num" data-label={t('library.col_added')}>
        {formatShortDate(todayIn(accountZone, new Date(row.addedAt)))}
      </td>
      {/* The row's own Download and Delete. */}
      <td className="library__cell--actions">
        <span className="library__row-actions">
          <button
            type="button"
            className="tracks-panel__download"
            disabled={actions.busy || row.blocked !== null}
            onClick={actions.onDownload}
            aria-label={t('library.download_target', { target: t('tracks.target_one', { label }) })}
            title={
              row.blocked !== null
                ? t('library.download_blocked', { track: label, reason: t(`library.blocked_${row.blocked}`) })
                : t('library.download_target', { target: t('tracks.target_one', { label }) })
            }
          >
            <Download size={16} />
          </button>
          {!actions.readOnly && (
            <button
              type="button"
              className="tracks-panel__delete"
              disabled={actions.busy || row.pending}
              onClick={actions.onDelete}
              aria-label={t('tracks.delete_target', { target: t('tracks.target_one', { label }) })}
              title={t('tracks.delete_target', { target: t('tracks.target_one', { label }) })}
            >
              <Trash2 size={16} />
            </button>
          )}
        </span>
      </td>
    </tr>
  );
}

function EmptyMessage({ state, result, onFirstPage }: { state: LibraryState; result: TrackPageResult; onFirstPage: () => void }) {
  const reason = emptyReason(state, result.total, result.bounds.firstDate !== null);
  return (
    <p className="library__empty">
      {reason === 'no_tracks' && t('library.empty')}
      {reason === 'search' && t('library.no_search_match', { q: state.q })}
      {reason === 'search_and_filters' && `${t('library.no_search_match', { q: state.q })} ${t('library.no_match_filters')}`}
      {reason === 'filters' && t('library.no_match')}
      {reason === 'past_last' && (
        <>
          {t('library.past_last')}{' '}
          <button type="button" className="library__link" onClick={onFirstPage}>
            {t('library.first_page')}
          </button>
        </>
      )}
    </p>
  );
}

/** Library's Trip filter (`docs/SPEC.md` FR-13.4), a dropdown like the panel's filters beside it:
 *  one Trip's tracks, or every track. */
function TripFilter({ trips, value, onChange }: { trips: { id: string; name: string }[]; value: string | null; onChange: (trip: string | null) => void }) {
  // A Trip the URL names but the account no longer has (deleted, or the list didn't load) still
  // shows as set, so it can be cleared.
  const current = trips.find((trip) => trip.id === value);
  return (
    <FilterDropdown
      text={value === null ? t('library.trip_label') : (current?.name ?? t('library.trip_unknown'))}
      set={value !== null}
      onClear={() => onChange(null)}
      clearLabel={t('library.trip_clear')}
      panelLabel={t('library.trip_label')}
      testId="trip-filter"
    >
      {(close) => (
        <div className="library__trip-list">
          {[{ id: null, name: t('library.trip_any') }, ...trips].map((trip) => (
            <button
              key={trip.id ?? ''}
              type="button"
              className="trip-menu__item"
              aria-pressed={trip.id === value}
              onClick={() => {
                close();
                if (trip.id !== value) onChange(trip.id);
              }}
            >
              <span className="trip-menu__name">{trip.name}</span>
            </button>
          ))}
        </div>
      )}
    </FilterDropdown>
  );
}
