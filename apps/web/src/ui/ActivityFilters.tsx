import { useCallback, useEffect, useRef, useState, type ReactNode } from 'react';
import { ChevronDown, X } from 'lucide-react';
import { DistanceFilter } from './DistanceFilter';
import type { DistanceRange, TypeFacet } from './activityFacets';
import { dateFilterLabel, type DateFilter } from './dateFilter';
import { distanceValue, formatActivityType, formatFilterDate, formatShortDate, unitLabel } from './format';
import { useUnitSystem } from './units';
import { t } from '../i18n';

export interface DatesProps {
  value: DateFilter;
  /** What the pickers allow (dateFilter.ts's dateFilterBounds). */
  bounds: { min: string; max: string };
  /** The first activity's day, for the empty After field's hint; null without one. */
  earliest: string | null;
  /** The account's today: the button leaves this year out of its dates. */
  today: string;
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
 * A filter's dropdown: its trigger says what's set, a ✕ beside it clears it, and the panel holds
 * the control. Type's keeps its own trigger, a dot, since its value is a list.
 */
function FilterDropdown({ text, set, onClear, clearLabel, panelLabel, testId, children }: { text: string; set: boolean; onClear: () => void; clearLabel: string; panelLabel: string; testId: string; children: ReactNode }) {
  const [open, setOpen] = useState(false);
  const ref = useDismiss(open, useCallback(() => setOpen(false), []));
  return (
    <div className={`activities-panel__type-dropdown activities-panel__filter-dropdown${set ? ' activities-panel__filter-dropdown--set' : ''}`} ref={ref}>
      <Trigger open={open} onClick={() => setOpen((o) => !o)} testId={testId}>
        <span className={set ? 'activities-panel__filter-value activities-panel__filter-value--set' : 'activities-panel__filter-value'}>{text}</span>
      </Trigger>
      {set && (
        <button type="button" className="activities-panel__filter-clear" aria-label={clearLabel} title={clearLabel} onClick={onClear} data-testid={`${testId}-clear`}>
          <X size={14} />
        </button>
      )}
      {open && (
        <div className="activities-panel__type-panel activities-panel__filter-panel" role="dialog" aria-label={panelLabel}>
          {children}
        </div>
      )}
    </div>
  );
}

/** The Dates filter (docs/SPEC.md FR-5.12): From and To, empty for all time. */
function DatesFilter({ value, bounds, earliest, today, onChange, onClear }: DatesProps) {
  const label = dateFilterLabel(value);
  const text =
    label.kind === 'all'
      ? t('dates.name')
      : label.kind === 'between'
        ? t('dates.between', { after: formatFilterDate(label.after, today), before: formatFilterDate(label.before, today) })
        : label.kind === 'after'
          ? t('dates.after_date', { date: formatFilterDate(label.after, today) })
          : t('dates.before_date', { date: formatFilterDate(label.before, today) });
  return (
    <FilterDropdown text={text} set={label.kind !== 'all'} onClear={onClear} clearLabel={t('dates.clear')} panelLabel={t('dates.filter')} testId="dates-filter">
      <DateField
        label={t('dates.after')}
        hint={earliest !== null ? t('dates.first_activity', { date: formatShortDate(earliest) }) : null}
        value={value.after}
        bounds={bounds}
        onCommit={(v) => onChange('after', v)}
        testId="dates-after"
      />
      <DateField label={t('dates.before')} hint={t('dates.today')} value={value.before} bounds={bounds} onCommit={(v) => onChange('before', v)} testId="dates-before" />
    </FilterDropdown>
  );
}

/**
 * One end of Dates. A date picked from the calendar applies at once; a typed one once its year has
 * four digits, since a year typed digit by digit is a valid date at each step (0002, 0020, …),
 * which the bounds would clamp and the camera fly to. A field emptied, or left half typed, applies
 * when it's left or Enter is pressed.
 */
function DateField({ label, hint, value, bounds, onCommit, testId }: { label: string; hint: string | null; value: string | null; bounds: { min: string; max: string }; onCommit: (value: string | null) => void; testId: string }) {
  const [draft, setDraft] = useState(value ?? '');
  useEffect(() => setDraft(value ?? ''), [value]);
  const commit = (next: string) => {
    if (next !== (value ?? '')) onCommit(next === '' ? null : next);
  };
  return (
    <label className="activities-panel__date-field">
      <span className="activities-panel__date-label">{label}</span>
      <input
        type="date"
        value={draft}
        min={bounds.min}
        max={bounds.max}
        onChange={(e) => {
          const next = e.target.value;
          setDraft(next);
          if (/^[1-9]\d{3}-/.test(next)) commit(next);
        }}
        onBlur={() => commit(draft)}
        onKeyDown={(e) => {
          if (e.key === 'Enter') commit(draft);
        }}
        data-testid={testId}
      />
      {value === null && hint !== null && <span className="activities-panel__date-hint">{hint}</span>}
    </label>
  );
}

/** The Activities tab's filter row: Type's, Dates' and Distance's dropdowns. Distance is offered
 *  only while the listed activities span distances (FR-5.3). */
export function ActivityFilters({ facets, excludedTypes, onToggleType, distanceBounds, distanceFilter, onChangeDistance, dates }: ActivityFiltersProps) {
  const [typeOpen, setTypeOpen] = useState(false);
  const typeRef = useDismiss(typeOpen, useCallback(() => setTypeOpen(false), []));
  const system = useUnitSystem();
  const distanceText =
    distanceFilter === null
      ? t('filters.distance')
      : t('filters.distance_between', { min: distanceValue(distanceFilter.min, system), max: distanceValue(distanceFilter.max, system), unit: unitLabel(system) });
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
      {distanceBounds !== null && distanceBounds.min < distanceBounds.max && (
        <FilterDropdown
          text={distanceText}
          set={distanceFilter !== null}
          onClear={() => onChangeDistance(null)}
          clearLabel={t('filters.clear_distance')}
          panelLabel={t('filters.distance')}
          testId="distance-dropdown"
        >
          <DistanceFilter bounds={distanceBounds} value={distanceFilter} onChangeDistance={onChangeDistance} />
        </FilterDropdown>
      )}
    </div>
  );
}