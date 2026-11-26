# Shared client rule cases

Test cases for the rules that every client implements the same way. The web (`apps/web/tests/clientRules.test.mjs`), Android (`ClientRulesTest.kt`) and iOS (`ClientRulesTests.swift`) suites each run every file here and fail on a file they have no implementation for, so a rule cannot change on one platform without the others failing. ADR-0049 says why each platform implements them natively.

A rule changes in its file first, then in every implementation, in the same pull request. A bug in a rule is fixed by adding the case that fails.

Each file holds one rule:

```json
{ "rule": "defaultRange", "description": "…", "cases": [{ "name": "…", "input": { … }, "expected": … }] }
```

A rule only some clients have names them in `"clients"` (`web`, `android`, `ios`), and the others' suites skip its file; with no `clients`, every client runs it.

The format is platform-neutral: dates are ISO strings, sets are arrays (compared sorted), ids are strings, field names are camelCase, and a missing field means the same as `null`. Timestamps are epoch milliseconds where the rule works in them, ISO strings otherwise. A union is plain JSON: `null`, a string tag such as `"load"`, or an object. A file or a case may set `"tolerance": 1e-6`, and numbers anywhere in the expected value then match within it. `"expected": { "throws": true }` means the rule rejects its input.

The geometric and numeric rules (`editRoute*`, `photoClusters`, `photoMarkerLayout`, `photoRoute*`) also have a `generated` list, run like `cases`: seeded random inputs with the web implementation's answers, written by `npm run gen:rule-cases` in `apps/web`. They catch rounding and boundary differences no hand-written case reaches. `cases` stay the reviewed spec; regenerate only after a deliberate rule change, and review the diff, since the script writes whatever the web code answers. CI never runs it.

| Rule | Input | Expected |
| :-- | :-- | :-- |
| `pendingChange` | `previous`, `now`, `awaiting`, `listed` (id sets) | `{ started, finished, left, landed, awaiting, pending }` |
| `pendingCheck` | `pending`, `awaiting`, `listed`, `stillPending` (ids) | `{ watched, moved, finished }` |
| `pendingBatches` | `ids`, `size` | the ids in consecutive batches of at most `size` |
| `attachmentName` | `header` (a Content-Disposition value, or null) | string |
| `deleteDone` | `status` (a DELETE's HTTP status) | boolean |
| `libraryEmptyReason` | `state` (`q`, `exclude`, `distance`, `after`, `before`, `trip`), `total`, `anyTrack` | `"no_tracks"`, `"past_last"`, `"search"`, `"search_and_filters"` or `"filters"` |
| `libraryPageQuery` | `state` (`sort`, `desc`, `page`, `q`, `exclude`, `distance` with `min` and `max`, null for unbounded; `after`, `before`, `trip`), `allTypes` | the query (`page`, `sort`, and `q`, `types`, `minDistance`, `maxDistance`, `from`, `to`, `trip` when set), or null |
| `libraryPager` | `page`, `total`, `pageSize` | `{ from, to, prev, next }` or null |
| `downloadBlock` | `tracks` (`{ id, pending, private }`) or `plainTracks` (a count of ordinary ones), `max` (the client's own, 100, when missing) | `{ kind: "too_many", count }`, `{ kind: "pending" \| "private", track }` (an id) or null |
| `tripFormAction` (Android and iOS) | `text` (a field as typed), `busy` | boolean |
| `largeText` (Android and iOS) | `scale` (the text size over its default) | boolean |
| `tripFold` | `foldedId`, `openId`, `clicked` (Trip ids, or null) | `{ foldedId, open, folded }` |
| `verifyAction` | `typed` (the code field's text) | `"check"` or `{ submit }` |
| `similarSpans` | `a`, `b` (`{ start, end }`, epoch ms, maybe fractional) | boolean |
| `profileStats` | `days` (`{ date, count, distanceMeters }`), `today`, `weeks` | `{ count, distanceMeters, activeDays, longestStreakDays, weeks }` |
| `youRefresh` | `numbers` (`{ atMs, tileVersion, today }` or null), `accountAtMs`, `now`, `resumed` | `{ account, numbers }` |
| `uploadPlan` | `files` (`{ name, size }`, size -1 when unknown) | `{ send, refusals }`, each refusal `{ kind, name }` or `{ kind: "tooMany", count }` |
| `toolbarTarget` | `checked` (ids), `focused` | ids |
| `statsOffered` | `checked` (ids), `tripId` | boolean |
| `statsCardPlacement` | `width`, `height` (the image), `card` (`{ width, height }`) | `{ x, y }` |
| `panelState` | `tracks` (`{ id, trackType, distanceMeters }`), `state` (`checked`, `focused`, `hidden`, `excludedTypes`, `distanceFilter`), `event` | the state after it |
| `boldTracks` | `checked` (ids), `focused` | ids |
| `targetVisibility` | `hidden`, `target` (ids) | hidden ids |
| `photoScope` | `mode` (`normal`, `fog`), `editWindowIds`, `focused`, `tripId` | `{ track }`, `{ trip }` or `null` |
| `photoGroup` | `photos` (`{ lat, lon }`) | `"open"` or `{ fit: [west, south, east, north] }` |
| `webSession` | `state` (`dates`, `area`, `tripId`, `checked`, `hidden`, `excludedTypes`), `event` | the state after it, with `flyRequest` |
| `distanceBounds` | `tracks` (`{ trackType, distanceMeters, private }`) | `{ min, max }` or `null` |
| `distanceFilter` | `bounds`, `current` (`{ min, max }`), `knob` (`min`, `max`), `value` | `{ min, max }` or `null` |
| `typeFacets` | `tracks`, `distanceFilter` | `[{ type, count }]` |
| `typeSearch` | `options` (`{ value, label, count }`), `query`, `maxLength` | `{ shown, add }`: values, and the text offered as a new type or `null` |
| `typeOptions` | `current`, `known` (`{ type, count }`) | `[{ type, count }]` |
| `recordingTypes` | `server` (`{ type, count }`), `local` (types) | `[{ type, count }]` |
| `recordingSendAllowed` (Android and iOS) | `emailVerified`, `isDemo` | boolean |
| `recordingSendOrder` (Android and iOS) | `recordings` (`{ id, startedAt, sent }`), `hidden`, `held`, `refused`, `setBack`, `retry` | ids, in order |
| `recordingSendFailure` (Android and iOS) | `answer` (a status, `"none"` or `"unreadable"`), `afterUnanswered` | `{ outcome, unanswered }` |
| `recordingSendDeletion` (Android and iOS) | `stored`, `going`, `landed` | `"deleted"`, `"sending"` or `"landed"` |
| `recordingSendNote` (Android and iOS) | `sent`, `sending`, `hidden`, `refused`, `isDemo` | a tag or null |
| `recordingSendWaiting` (Android and iOS) | `recordings` (`{ id, sent }`), `hidden`, `isDemo` | count |
| `passesFilters` | `track`, `excludedTypes`, `distanceFilter` | boolean |
| `fitBoxes` | `tracks` (`{ bbox, pending, private }`) | the boxes, in order |
| `selectionBoxes` | `tracks` (`{ bbox, pending, private }`) | the boxes, in order |
| `openingMove` (Android and iOS) | `found`, `recording`, `tripOpen`, `flightAsked`, `moved` | `"move"`, `"hold"` or `"stay"` |
| `tripListAnswer` (Android and iOS) | `quiet`, `ready`, `open` (an id or null), `listed` (ids), `failed` | `{ openGone, showsError }` |
| `uploadWatch` (Android and iOS) | `status` (an uploaded file's state) | `{ landed, done }` |
| `framePadding` (Android and iOS) | `height`, `top`, `coveredBelow`, `pad`, `minSpan` | `{ top, bottom }` |
| `importRetry` (Android and iOS) | `failures` (rounds in a row with a failed read), `watched` (seconds since the watch started) | seconds, or `null` to give up |
| `openingView` | `boxes` (`[west, south, east, north]`, newest first), `viewport` (`{ width, height }`) | `{ center: [lon, lat], zoom }` or `null` |
| `areaLoad` | `zoom`, `listed`, `total` | `{ load, capped }`, `load` `auto` or `none` |
| `fogLevelInView` | `levels` (`{ level, from, below }`), `zoom`, `locked` | a level |
| `fogLevelPick` | `levels`, `zoom`, `locked`, `picked` | `{ locked, zoom }`, `zoom` null to stay |
| `dateFilterSet` | `current` (`{ after, before }`), `end` (`after`, `before`), `value`, `bounds` (`{ min, max }`) | `{ filter, fly }` |
| `dateFilterLabel` | `after`, `before` | `{ kind }`: `all`, `between`, `after` or `before`, with the ends set |
| `dateFilterBounds` | `earliest`, `latest`, `today` | `{ min, max }` |
| `trackZone` | `own`, `account` (zone ids) | a zone id, or `null` for the device's |
| `photoClusters` | `points` (`{ id, x, y }`), `radius` | `[{ ids, x, y }]` |
| `photoMarkerSize` | `zoom` | `"hidden"`, `"small"` or `"full"` |
| `photoMarkerLayout` | `points` (`{ id, x, y }`), `zoom`, `activeId`, `loneId`, `width`, `height`, `scale` | `[{ ids, x, y, diameter, active, small }]` |
| `photoRoutePoint` | `points` (`{ lon, lat, t }`), `fraction` | `{ lon, lat, t }` |
| `photoRouteFraction` | `points`, `t` | a fraction |
| `photoRouteStart` | `points`, `anchor` (`{ t }`, `{ waiting }` or `null`), `placed`, `anchors` | a fraction |
| `photoFit` | `image`, `stage` (`{ width, height }`) | `{ width, height }` |
| `photoZoom` | `view` (`{ scale, x, y }`), `factor`, `point`, `fitted`, `stage` | a view |
| `photoPan` | `view`, `dx`, `dy`, `fitted`, `stage` | a view |
| `photoClamp` | `view`, `fitted`, `stage` | a view |
| `distanceParts`, `totalDistanceParts` | `meters`, `system` (`metric`, `imperial`) | `{ value, minDecimals, maxDecimals, grouping, unit }` |
| `durationParts` | `seconds` | `{ key, args }` |
| `editWrites` | `tracks`, `written` (`{ id, trackType, name, description }`), `type`, `name`, `description` (the form's), `unsure` (ids) | `[{ id, trackType, name, description }]` |
| `editRouteFold` | `base` (an edit or `null`), `ops` | an edit `{ keep, remove, drop, move }` |
| `editRouteApply` | `points` (`[lon, lat, t]`), `edit` | points |
| `editRouteChop`, `editRouteCut` | `visible` (points), `lo`, `hi` | an op or `null` |
| `editRouteSplitIndex` | `visible` (points), `lo`, `hi` | an index or `null` |
| `editRouteSplitPoint` | `ops` | a time or `null` |
| `editRouteMove` | `t`, `lon`, `lat` | a `move` op |
| `editRouteDistances` | `points` | meters at each point |
| `layerInsertion` | `current` (layer ids, bottom to top), `order`, `id`, `own`, `fallback` | the id to insert under, or `null` to append |
| `layerLift` | `current`, `id`, `own` | boolean |
| `basemapStatus` (web and Android) | `loaded`, `failed`, `waitedMs` (on screen) | `"loading"`, `"loaded"` or `"unreachable"` |
| `satelliteStatus` (web and Android) | `on`, `loaded`, `failed`, `waitedMs` (Satellite on screen) | `{ status: "loading", "loaded" or "failed", look }` |
| `tourStart` (web and Android) | `requested`, `isDemo`, `hasTracks` (or `null`), `seen` (`tour`, `cards`) | `"start"`, `"offer"`, `"none"` or `"wait"` |
| `tourCard` (web and Android) | `event` (`{ kind: "mode", mode }` or `{ kind: "tab", tab }`), `seen`, `touring` | `"fog"`, `"trips"` or `null` |
| `tourNextStep` (web and Android) | `shown` (a flag per step), `from`, `dir` (`-1`, `1`) | an index or `null` |
| `tourCamera` (web and Android) | `start`, `shown` (views `{ lon, lat, zoom }` or `null`), `current`, `step` (`{ view, tab }` or `null` for the end) | `{ start, shown, move }` |
| `tourStep` (web and Android) | `now` (`mode`, `tab`), `step` (`mode`, `tab`, `card`, or `null` for the end), `restore` (`mode`, `tab`) | `{ mode, tab, card }` |
| `webPageRoute` (Android and iOS) | `link` (`scheme`, `authority`, `path`, the `track` and `day` query parameters), `base` (`scheme`, `authority`), `page`, `leaving`, `onboarding` | `"stay"`, `"outside"`, `"ignore"`, `"close"`, `"onboarded"` or `{ viewOnMap: { track, day } }` |

A rule only one platform has, or one where the platforms differ on purpose, has no file and is tested on that platform alone.