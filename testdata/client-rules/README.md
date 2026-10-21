# Shared client rule cases

Test cases for the rules that every client implements the same way. The web (`apps/web/tests/clientRules.test.mjs`) and Android (`ClientRulesTest.kt`) suites both run every file here and fail on a file they have no implementation for, so a rule cannot change on one platform without the other failing; they are the iOS app's test spec.

Each file holds one rule:

```json
{ "rule": "defaultRange", "description": "…", "cases": [{ "name": "…", "input": { … }, "expected": … }] }
```

The format is platform-neutral: dates are ISO strings, sets are arrays (compared sorted), ids are strings, field names are camelCase, and a missing field means the same as `null`. Timestamps are epoch milliseconds where the rule works in them, ISO strings otherwise. A union is plain JSON: `null`, a string tag such as `"load"`, or an object. A file or a case may set `"tolerance": 1e-6`, and numbers anywhere in the expected value then match within it. `"expected": { "throws": true }` means the rule rejects its input.

| Rule | Input | Expected |
| :-- | :-- | :-- |
| `defaultRange` | `visibleDays` (ascending dates), `earliest`, `today` | `{ from, to }` |
| `pendingChange` | `previous`, `now`, `awaiting` (id sets) | `{ started, finished, left, landed, awaiting }` |
| `pendingCheck` | `listed`, `awaiting`, `stillPending` (ids) | `{ watched, moved }` |
| `toolbarTarget` | `checked` (ids), `focused` | ids |
| `panelState` | `activities` (`{ id, activityType, distanceMeters }`), `state` (`checked`, `focused`, `hidden`, `excludedTypes`, `distanceFilter`), `event` | the state after it |
| `boldTracks` | `checked` (ids), `focused` | ids |
| `targetVisibility` | `hidden`, `target` (ids) | hidden ids |
| `photoScope` | `mode` (`normal`, `fog`, `heatmap`), `editWindowIds`, `focused`, `storyId` | `{ activity }`, `{ story }` or `null` |
| `photoGroup` | `photos` (`{ lat, lon }`) | `"open"` or `{ fit: [west, south, east, north] }` |
| `session` | `state` (`range`, `userPicked`, `storyId`, `checked`, `hidden`, `excludedTypes`), `event` | the state after it, with `flyRequest` |
| `rangeShift` | `days` (ascending dates), `hasEarlier`, `range`, `dir` (`-1`, `1`) | `{ from, to }`, `null` or `"load"` |
| `distanceBounds` | `activities` (`{ activityType, distanceMeters, private }`) | `{ min, max }` or `null` |
| `distanceFilter` | `bounds`, `current` (`{ min, max }`), `knob` (`min`, `max`), `value` | `{ min, max }` or `null` |
| `typeFacets` | `activities`, `distanceFilter` | `[{ type, count }]` |
| `passesFilters` | `activity`, `excludedTypes`, `distanceFilter` | boolean |
| `activityZone` | `own`, `account` (zone ids) | a zone id, or `null` for the device's |
| `photoClusters` | `points` (`{ id, x, y }`), `radius` | `[{ ids, x, y }]` |
| `photoMarkerSize` | `zoom` | `"hidden"`, `"small"` or `"full"` |
| `photoMarkerLayout` | `points` (`{ id, x, y }`), `zoom`, `activeId`, `loneId`, `width`, `height`, `scale` | `[{ ids, x, y, diameter, active, small }]` |
| `photoTrackPoint` | `points` (`{ lon, lat, t }`), `fraction` | `{ lon, lat, t }` |
| `photoTrackFraction` | `points`, `t` | a fraction |
| `photoTrackStart` | `points`, `anchor` (`{ t }`, `{ waiting }` or `null`), `placed`, `anchors` | a fraction |
| `photoFit` | `image`, `stage` (`{ width, height }`) | `{ width, height }` |
| `photoZoom` | `view` (`{ scale, x, y }`), `factor`, `point`, `fitted`, `stage` | a view |
| `photoPan` | `view`, `dx`, `dy`, `fitted`, `stage` | a view |
| `photoClamp` | `view`, `fitted`, `stage` | a view |
| `distanceParts`, `totalDistanceParts` | `meters`, `system` (`metric`, `imperial`) | `{ value, minDecimals, maxDecimals, grouping, unit }` |
| `durationParts` | `seconds` | `{ key, args }` |
| `editTrackFold` | `base` (an edit or `null`), `ops` | an edit `{ keep, remove, drop, move }` |
| `editTrackApply` | `points` (`[lon, lat, t]`), `edit` | points |
| `editTrackChop`, `editTrackCut` | `visible` (points), `lo`, `hi` | an op or `null` |
| `editTrackSplitIndex` | `visible` (points), `lo`, `hi` | an index or `null` |
| `editTrackSplitPoint` | `ops` | a time or `null` |
| `editTrackMove` | `t`, `lon`, `lat` | a `move` op |
| `editTrackDistances` | `points` | meters at each point |
| `layerInsertion` | `current` (layer ids, bottom to top), `order`, `id`, `own`, `fallback` | the id to insert under, or `null` to append |
| `layerLift` | `current`, `id`, `own` | boolean |

A rule only one platform has, or one where the platforms differ on purpose, is tested on that platform alone.