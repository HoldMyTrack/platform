import { distanceBandValue, unitLabel } from './format.ts';
import { useUnitSystem } from './units.ts';
import { bandWithin, nextDistanceFilter, unitMeters, wholeDistanceBounds, type DistanceRange } from './trackFacets.ts';
import { t } from '../i18n/index.ts';

/**
 * The Tracks panel's DISTANCE dual slider (docs/SPEC.md FR-5.3), inside the filter row's
 * Distance dropdown (TrackFilters.tsx).
 *
 * It moves in whole kilometers or miles: its ends are the tracks' bounds rounded outward
 * (wholeDistanceBounds), its step is one unit, which from a whole-unit end lands on every one,
 * so an arrow key moves a knob a whole unit, and nextDistanceFilter snaps what a drag reports.
 */
interface DistanceFilterProps {
  bounds: DistanceRange | null;
  value: DistanceRange | null;
  onChangeDistance: (next: DistanceRange | null) => void;
}

export function DistanceFilter({ bounds, value, onChangeDistance }: DistanceFilterProps) {
  const system = useUnitSystem();
  // Offered while the tracks themselves span distances, whatever their rounded ends.
  if (!bounds || bounds.min >= bounds.max) return null;
  const ends = wholeDistanceBounds(bounds, system)!;
  // The knobs and fill, inside the ends; the readout says the band as it filters.
  const current = bandWithin(ends, value ?? ends);

  return (
    <div className="track-filters" data-testid="distance-filter">
      <div className="track-filters__section">
        <div className="track-filters__head">
          <span className="track-filters__label">{t('filters.distance')}</span>
          <span className="track-filters__readout" data-testid="distance-readout">
            {value === null
              ? t('filters.any_distance')
              : `${distanceBandValue(value.min, system)} – ${distanceBandValue(value.max, system)} ${unitLabel(system)}`}
          </span>
        </div>
        <div className="track-filters__track-wrap">
          <div className="track-filters__track" />
          <div
            className="track-filters__fill"
            style={{
              left: `${((current.min - ends.min) / (ends.max - ends.min)) * 100}%`,
              right: `${100 - ((current.max - ends.min) / (ends.max - ends.min)) * 100}%`,
            }}
          />
          <input
            type="range"
            className="track-filters__range track-filters__range--min"
            aria-label={t('filters.min_distance')}
            min={ends.min}
            max={ends.max}
            step={unitMeters(system)}
            value={current.min}
            onChange={(event) => onChangeDistance(nextDistanceFilter(ends, current, 'min', Number(event.target.value), system))}
          />
          <input
            type="range"
            className="track-filters__range track-filters__range--max"
            aria-label={t('filters.max_distance')}
            min={ends.min}
            max={ends.max}
            step={unitMeters(system)}
            value={current.max}
            onChange={(event) => onChangeDistance(nextDistanceFilter(ends, current, 'max', Number(event.target.value), system))}
          />
        </div>
        <div className="track-filters__bounds">
          <span>
            {distanceBandValue(ends.min, system)} {unitLabel(system)}
          </span>
          <span>
            {distanceBandValue(ends.max, system)} {unitLabel(system)}
          </span>
        </div>
      </div>
    </div>
  );
}
