# Shared client rule cases

Test cases for the rules that every client implements the same way. The web (`apps/web/tests/clientRules.test.mjs`), Android (`ClientRulesTest.kt`) and iOS (`ClientRulesTests.swift`) suites each run every file here and fail on a file they have no implementation for, so a rule cannot change on one platform without the others failing. ADR-0049 says why each platform implements them natively.

A rule changes in its file first, then in every implementation, in the same pull request. A bug in a rule is fixed by adding the case that fails.

Each file holds one rule:

```json
{ "rule": "defaultRange", "description": "…", "cases": [{ "name": "…", "input": { … }, "expected": … }] }
```

A rule only some clients have names them in `"clients"` (`web`, `android`, `ios`), and the others' suites skip its file; with no `clients`, every client runs it.

The format is platform-neutral: dates are ISO strings, sets are arrays (compared sorted), ids are strings, field names are camelCase, and a missing field means the same as `null`. Timestamps are epoch milliseconds where the rule works in them, ISO strings otherwise. A union is plain JSON: `null`, a string tag such as `"load"`, or an object. A file or a case may set `"tolerance": 1e-6`, and numbers anywhere in the expected value then match within it. `"expected": { "throws": true }` means the rule rejects its input.

The geometric and numeric rules (`editTrack*`, `photoClusters`, `photoMarkerLayout`, `photoTrack*`, `slider*`) also have a `generated` list, run like `cases`: seeded random inputs with the web implementation's answers, written by `npm run gen:rule-cases` in `apps/web`. They catch rounding and boundary differences no hand-written case reaches. `cases` stay the reviewed spec; regenerate only after a deliberate rule change, and review the diff, since the script writes whatever the web code answers. CI never runs it.

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
| `sliderLayout` | `width`, `finePointer` | `{ buttons, days }` |
| `sliderBoundaries` | `days` (ascending dates), `canPanEarlier`, `canPanLater`, `range` | `{ start, end }`, each -1..n + 1 |
| `sliderMoveKnob` | the same, `knob` (`start`, `end`), `boundary` | `{ from, to }` |
| `sliderTicks` | `days` | `[{ boundary, kind, month }]`, `kind` `day` or `month` |
| `sliderPanLand` | `days` (the new window), `range`, `start`, `end` (knobs pulled) | `{ from, to }` |
| `sliderWindowFit` | `count`, `windowDays`, `left`, `first`, `last` (indices), `dir` | the new `left` |
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
| `basemapStatus` (web) | `loaded`, `failed`, `waitedMs` (on screen) | `"loading"`, `"loaded"` or `"unreachable"` |
| `tourStart` (web and Android) | `requested`, `isDemo`, `hasActivities` (or `null`), `seen` (`tour`, `cards`) | `"start"`, `"offer"`, `"none"` or `"wait"` |
| `tourCard` (web and Android) | `event` (`{ kind: "mode", mode }` or `{ kind: "tab", tab }`), `seen`, `touring` | `"fog"`, `"heatmap"`, `"stories"` or `null` |
| `tourNextStep` (web and Android) | `shown` (a flag per step), `from`, `dir` (`-1`, `1`) | an index or `null` |
| `tourCamera` (web and Android) | `start`, `shown` (views `{ lon, lat, zoom }` or `null`), `current`, `step` (`{ view, tab }` or `null` for the end) | `{ start, shown, move }` |
| `tourStep` (web and Android) | `now` (`mode`, `tab`), `step` (`mode`, `tab`, `card`, or `null` for the end), `restore` (`mode`, `tab`) | `{ mode, tab, card }` |
| `webPageRoute` (Android and iOS) | `link` (`scheme`, `authority`, `path`, the `activity` and `day` query parameters), `base` (`scheme`, `authority`), `page`, `leaving`, `onboarding` | `"stay"`, `"outside"`, `"ignore"`, `"close"`, `"onboarded"` or `{ viewOnMap: { activity, day } }` |

A rule only one platform has, or one where the platforms differ on purpose, has no file and is tested on that platform alone.