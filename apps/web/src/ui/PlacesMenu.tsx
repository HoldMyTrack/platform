import { MapPin } from 'lucide-react';
import { togglePlace, type Overlays } from '../map/overlays';
import { SPOT_CATEGORIES, type SpotCategory } from '../map/spots';
import { t } from '../i18n';
import type { MessageKey } from '../i18n/en';
import { PickItem, PickMenu } from './PickMenu';

export interface PlacesMenuProps {
  overlays: Overlays;
  onChange: (next: Overlays) => void;
  /** Held open from outside, whatever the button says: the tour's Places step. */
  forceOpen?: boolean;
}

const CATEGORY_LABELS: Record<SpotCategory, MessageKey> = {
  playground: 'overlays.playgrounds',
  dog_park: 'overlays.dog_parks',
  monument: 'overlays.monuments',
  viewpoint: 'overlays.viewpoints',
  waterfall: 'overlays.waterfalls',
  history: 'overlays.history',
};

/**
 * The Places dropdown beside Layers: each Spots category (FR-14.2), picked over any mode. Picking
 * one while the checkbox is off turns it back on, or the pick would seem to do nothing.
 */
export function PlacesMenu({ overlays, onChange, forceOpen = false }: PlacesMenuProps) {
  return (
    <PickMenu
      testId="map-places"
      label={t('map.places')}
      icon={<MapPin size={14} aria-hidden="true" />}
      count={overlays.spots.length}
      enabled={overlays.placesEnabled}
      onEnabledChange={(placesEnabled) => onChange({ ...overlays, placesEnabled })}
      masterId="places-master"
      masterLabel={t('places.master')}
      emptyHint={t('places.master_empty')}
      forceOpen={forceOpen}
    >
      {SPOT_CATEGORIES.map((category) => (
        <PickItem key={category} id={`overlay-spots-${category}`} label={t(CATEGORY_LABELS[category])} checked={overlays.spots.includes(category)} onToggle={() => onChange(togglePlace(overlays, category))} />
      ))}
    </PickMenu>
  );
}
