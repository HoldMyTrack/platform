import { distanceValue, unitLabel } from './format.ts';
import { useUnitSystem } from './units.ts';
import { bandWithin, nextDistanceFilter, type DistanceRange } from './activityFacets.ts';
import { t } from '../i18n/index.ts';

/**
 * The Activities panel's DISTANCE dual slider (docs/SPEC.md FR-5.3), inside the filter row's
 * Distance dropdown (ActivityFilters.tsx).
 *
 * `step="any"`: the bounds are real distances in meters with centimeters (a 16093.44 m ride),
 * and the default step of 1, counted from the minimum, can't land on the maximum — a knob
 * dragged back to the end stopped just short of the longest activity and kept it filtered out.
 */
interface DistanceFilterProps {
  bounds: DistanceRange | null;
  value: DistanceRange | null;
  onChangeDistance: (next: DistanceRange | null) => void;
}

export function DistanceFilter({ bounds, value, onChangeDistance }: DistanceFilterProps) {
  const system = useUnitSystem();
  if (!bounds || bounds.min >= bounds.max) return null;
  // The knobs and fill, inside the bounds; the readout says the band as it filters.
  const current = bandWithin(bounds, value ?? bounds);

  return (
    <div className="activity-filters" data-testid="distance-filter">
      <div className="activity-filters__section">
        <div className="activity-filters__head">
          <span className="activity-filters__label">{t('filters.distance')}</span>
          <span className="activity-filters__readout" data-testid="distance-readout">
            {value === null
              ? t('filters.any_distance')
              : `${distanceValue(value.min, system)} – ${distanceValue(value.max, system)} ${unitLabel(system)}`}
          </span>
        </div>
        <div className="activity-filters__track-wrap">
          <div className="activity-filters__track" />
          <div
            className="activity-filters__fill"
            style={{
              left: `${((current.min - bounds.min) / (bounds.max - bounds.min)) * 100}%`,
              right: `${100 - ((current.max - bounds.min) / (bounds.max - bounds.min)) * 100}%`,
            }}
          />
          <input
            type="range"
            className="activity-filters__range activity-filters__range--min"
            aria-label={t('filters.min_distance')}
            min={bounds.min}
            max={bounds.max}
            step="any"
            value={current.min}
            onChange={(event) => onChangeDistance(nextDistanceFilter(bounds, current, 'min', Number(event.target.value)))}
          />
          <input
            type="range"
            className="activity-filters__range activity-filters__range--max"
            aria-label={t('filters.max_distance')}
            min={bounds.min}
            max={bounds.max}
            step="any"
            value={current.max}
            onChange={(event) => onChangeDistance(nextDistanceFilter(bounds, current, 'max', Number(event.target.value)))}
          />
        </div>
        <div className="activity-filters__bounds">
          <span>
            {distanceValue(bounds.min, system)} {unitLabel(system)}
          </span>
          <span>
            {distanceValue(bounds.max, system)} {unitLabel(system)}
          </span>
        </div>
      </div>
    </div>
  );
}
