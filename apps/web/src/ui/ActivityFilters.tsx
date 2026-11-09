import { useCallback, useEffect, useRef, useState, type ReactNode } from 'react';
import { ChevronDown, X } from 'lucide-react';
import { DistanceFilter } from './DistanceFilter';
import type { DistanceRange, TypeFacet } from './activityFacets';
import { dateFilterLabel, type DateFilter } from './dateFilter';
import { formatActivityType, formatShortDate } from './format';
import { t } from '../i18n';

export interface DatesProps {
  value: DateFilter;
  /** What the pickers allow (dateFilter.ts's dateFilterBounds). */
  bounds: { min: string; max: string };
  /** The first activity's day, for the empty After field's hint; null without one. */
  earliest: string | null;
  /** One end set to a date, or cleared with null. */
  onChange: (end: 'after' | 'before', value: string | null) => void;
  onClear: () => void;
}

export interface ActivityFiltersProps {
  facets: TypeFacet[];
  excludedTypes: ReadonlySet<string>;
  onToggleType: (type: string) => void;
  distanceBounds: DistanceRange | null;
  distanceFilter: DistanceRange | null;
  onChangeDistance: (next: DistanceRange | null) => void;
  onResetFilters: () => void;
  dates: DatesProps;
}

/** A dropdown closed by a press outside it or Escape. */
function useDismiss(open: boolean, close: () => void) {
  const ref = useRef<HTMLDivElement>(null);
  useEffect(() => {
    if (!open) return;
    const onPointerDown = (event: PointerEvent) => {
      if (!ref.current?.contains(event.target as Node)) close();
    };
    const onKeyDown = (event: KeyboardEvent) => {
      if (event.key === 'Escape') close();
    };
    document.addEventListener('pointerdown', onPointerDown);
    document.addEventListener('keydown', onKeyDown);
    return () => {
      document.removeEventListener('pointerdown', onPointerDown);
      document.removeEventListener('keydown', onKeyDown);
    };
  }, [open, close]);
  return ref;
}

/** The trigger every filter dropdown shares: its name, a dot or a value when set, a caret. */
function Trigger({ open, onClick, children, testId }: { open: boolean; onClick: () => void; children: ReactNode; testId?: string }) {
  return (
    <button type="button" className="activities-panel__type-trigger" aria-haspopup="true" aria-expanded={open} onClick={onClick} data-testid={testId}>
      {children}
      <span className="activities-panel__type-trigger-caret" aria-hidden="true">
        <ChevronDown size={14} />
      </span>
    </button>
  );
}

/**
 * The Dates filter (docs/SPEC.md FR-5.20): After and Before, empty for all time. A typed date is
 * applied when the field is left or Enter pressed, not on every keystroke: a year typed digit by
 * digit is a valid date at each step, which the bounds would clamp and the camera fly to.
 */
function DatesFilter({ value, bounds, earliest, onChange, onClear }: DatesProps) {
  const [open, setOpen] = useState(false);
  const ref = useDismiss(open, useCallback(() => setOpen(false), []));
  const label = dateFilterLabel(value);
  const text =
    label.kind === 'all'
      ? t('dates.all_time')
      : label.kind === 'between'
        ? t('dates.between', { after: formatShortDate(label.after), before: formatShortDate(label.before) })
        : label.kind === 'after'
          ? t('dates.after_date', { date: formatShortDate(label.after) })
          : t('dates.before_date', { date: formatShortDate(label.before) });
  const set = label.kind !== 'all';
  return (
    <div className="activities-panel__type-dropdown activities-panel__dates-dropdown" ref={ref}>
      <Trigger open={open} onClick={() => setOpen((o) => !o)} testId="dates-filter">
        <span className={set ? 'activities-panel__dates-value activities-panel__dates-value--set' : 'activities-panel__dates-value'}>{text}</span>
      </Trigger>
      {set && (
        <button type="button" className="activities-panel__dates-clear" aria-label={t('dates.clear')} title={t('dates.clear')} onClick={onClear} data-testid="dates-clear">
          <X size={14} />
        </button>
      )}
      {open && (
        <div className="activities-panel__type-panel activities-panel__dates-panel" role="dialog" aria-label={t('dates.filter')}>
          <DateField
            label={t('dates.after')}
            hint={earliest !== null ? t('dates.first_activity', { date: formatShortDate(earliest) }) : null}
            value={value.after}
            bounds={bounds}
            onCommit={(v) => onChange('after', v)}
            testId="dates-after"
          />
          <DateField label={t('dates.before')} hint={t('dates.today')} value={value.before} bounds={bounds} onCommit={(v) => onChange('before', v)} testId="dates-before" />
          {set && (
            <button
              type="button"
              className="activities-panel__dates-reset"
              onClick={() => {
                onClear();
                setOpen(false);
              }}
            >
              {t('dates.clear')}
            </button>
          )}
        </div>
      )}
    </div>
  );
}

function DateField({ label, hint, value, bounds, onCommit, testId }: { label: string; hint: string | null; value: string | null; bounds: { min: string; max: string }; onCommit: (value: string | null) => void; testId: string }) {
  const [draft, setDraft] = useState(value ?? '');
  useEffect(() => setDraft(value ?? ''), [value]);
  const commit = () => {
    if (draft !== (value ?? '')) onCommit(draft === '' ? null : draft);
  };
  return (
    <label className="activities-panel__date-field">
      <span className="activities-panel__date-label">{label}</span>
      <input
        type="date"
        value={draft}
        min={bounds.min}
        max={bounds.max}
        onChange={(e) => setDraft(e.target.value)}
        onBlur={commit}
        onKeyDown={(e) => {
          if (e.key === 'Enter') commit();
        }}
        data-testid={testId}
      />
      {value === null && hint !== null && <span className="activities-panel__date-hint">{hint}</span>}
    </label>
  );
}

/** The Activities tab's filter row: Type's dropdown, Dates', then Distance's slider taking the rest. */
export function ActivityFilters({ facets, excludedTypes, onToggleType, distanceBounds, distanceFilter, onChangeDistance, onResetFilters, dates }: ActivityFiltersProps) {
  const [typeOpen, setTypeOpen] = useState(false);
  const typeRef = useDismiss(typeOpen, useCallback(() => setTypeOpen(false), []));
  const hasActiveFilters = excludedTypes.size > 0 || distanceFilter !== null;
  return (
    <div className="activities-panel__filters">
      <div className="activities-panel__type-dropdown" ref={typeRef}>
        <Trigger open={typeOpen} onClick={() => setTypeOpen((o) => !o)}>
          {t('activities.type')}
          {excludedTypes.size > 0 && <span className="activities-panel__type-trigger-dot" aria-hidden="true" />}
        </Trigger>
        {typeOpen && (
          <div className="activities-panel__type-panel" role="dialog" aria-label={t('activities.filter_by_type')}>
            {facets.length === 0 ? (
              <p className="activities-panel__type-panel-empty">{t('activities.type_empty')}</p>
            ) : (
              <>
                {/* Only ever clears every exclusion, like Reset filters. */}
                <label htmlFor="activities-toolbar-type-all" className="activity-filters__type-item activity-filters__type-item--all">
                  <input
                    id="activities-toolbar-type-all"
                    type="checkbox"
                    checked={excludedTypes.size === 0}
                    onChange={() => {
                      for (const type of excludedTypes) onToggleType(type);
                    }}
                  />
                  <span className="activity-filters__type-label">{t('activities.all_types')}</span>
                </label>
                <div className="activities-panel__type-panel-divider" aria-hidden="true" />
                <div className="activity-filters__type-list">
                  {facets.map((facet) => {
                    const inputId = `activities-toolbar-type-${facet.type}`;
                    return (
                      <label key={facet.type} htmlFor={inputId} className="activity-filters__type-item">
                        <input id={inputId} type="checkbox" checked={!excludedTypes.has(facet.type)} onChange={() => onToggleType(facet.type)} />
                        <span className="activity-filters__type-label">{formatActivityType(facet.type)}</span>
                        <span className="activity-filters__type-count">{facet.count}</span>
                      </label>
                    );
                  })}
                </div>
              </>
            )}
          </div>
        )}
      </div>
      <DatesFilter {...dates} />
      <DistanceFilter bounds={distanceBounds} value={distanceFilter} onChangeDistance={onChangeDistance} onReset={onResetFilters} hasActiveFilters={hasActiveFilters} />
    </div>
  );
}