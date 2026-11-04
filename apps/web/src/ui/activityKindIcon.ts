import { Bike, Car, Footprints, Route, createLucideIcon, type LucideIcon } from 'lucide-react';
import { typeKind, type ActivityKind } from './activityTypes.ts';

/** A rider leaning forward on a solowheel, which Lucide lacks; drawn on its grid and stroke.
 *  Android: `ic_monowheel.xml`. */
const Solowheel = createLucideIcon('solowheel', [
  ['circle', { cx: '14.5', cy: '4', r: '1', key: 'head' }],
  ['path', { d: 'M13.4 8 12.2 12.5l1.3 2.25-1.75 2.25', key: 'body' }],
  ['path', { d: 'M13.1 9.25l2.9 2.25', key: 'arm' }],
  ['circle', { cx: '11.5', cy: '19.5', r: '2.5', key: 'wheel' }],
]);

/** An e-scooter with a lightning bolt; Lucide's `scooter` is a kick scooter.
 *  Android: `ic_electric_scooter.xml`. */
const EScooter = createLucideIcon('e-scooter', [
  ['circle', { cx: '5', cy: '19', r: '2', key: 'rear' }],
  ['circle', { cx: '19', cy: '19', r: '2', key: 'front' }],
  ['path', { d: 'M7 19h10', key: 'deck' }],
  ['path', { d: 'M19 19 16 5', key: 'stem' }],
  ['path', { d: 'M14.5 5H18', key: 'bar' }],
  ['path', { d: 'M10 7l-2 3.5h3.5l-2 3.5', key: 'bolt' }],
]);

const icons: Record<ActivityKind, LucideIcon> = {
  foot: Footprints,
  wheels: Bike,
  motor: Car,
  solowheel: Solowheel,
  e_scooter: EScooter,
  other: Route,
};

/** The icon on an activity's row: its kind's. Android: `panel/ActivityRows.kt` `kindIcon`. */
export function kindIcon(kind: ActivityKind): LucideIcon {
  return icons[kind];
}

export function typeIcon(activityType: string): LucideIcon {
  return kindIcon(typeKind(activityType));
}