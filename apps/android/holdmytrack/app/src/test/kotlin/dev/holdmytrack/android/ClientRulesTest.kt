package dev.holdmytrack.android

import dev.holdmytrack.android.map.DateRange
import dev.holdmytrack.android.map.DefaultRange
import dev.holdmytrack.android.map.MapLayersDoc
import dev.holdmytrack.android.map.MapMode
import dev.holdmytrack.android.map.MapSession
import dev.holdmytrack.android.map.PendingDiff
import dev.holdmytrack.android.map.RangeShift
import dev.holdmytrack.android.map.SliderRules
import dev.holdmytrack.android.map.shiftRange
import dev.holdmytrack.android.net.Activity
import dev.holdmytrack.android.net.TrackEdit
import dev.holdmytrack.android.net.TrackPoint
import dev.holdmytrack.android.panel.ActivityFacets
import dev.holdmytrack.android.panel.ActivityZone
import dev.holdmytrack.android.panel.DistanceKnob
import dev.holdmytrack.android.panel.DistanceRange
import dev.holdmytrack.android.panel.DistanceParts
import dev.holdmytrack.android.panel.DurationParts
import dev.holdmytrack.android.panel.EditOp
import dev.holdmytrack.android.panel.EditTrackOps
import dev.holdmytrack.android.panel.FormatParts
import dev.holdmytrack.android.panel.PanelRules
import dev.holdmytrack.android.panel.PanelState
import dev.holdmytrack.android.photos.PhotoClusters
import dev.holdmytrack.android.photos.PhotoMarkerScope
import dev.holdmytrack.android.photos.PhotoTrack
import dev.holdmytrack.android.photos.PhotoZoom
import dev.holdmytrack.android.photos.PlaceAnchor
import dev.holdmytrack.android.photos.ScreenPoint
import dev.holdmytrack.android.photos.TimedPoint
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.boolean
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.buildJsonArray
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.double
import kotlinx.serialization.json.int
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.long
import kotlinx.serialization.json.put
import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File
import java.time.ZoneId

/**
 * The rules every client implements alike, run against the shared cases in
 * `testdata/client-rules` (its README has the format), so a rule can't change here without the
 * web's failing too.
 */
class ClientRulesTest {

    private val dir: File = run {
        var at: File? = File(System.getProperty("user.dir")).absoluteFile
        while (at != null && !File(at, "testdata/client-rules").isDirectory) at = at.parentFile
        File(at ?: error("testdata/client-rules not found above ${System.getProperty("user.dir")}"), "testdata/client-rules")
    }

    private val files: List<File> by lazy { dir.listFiles { file -> file.extension == "json" }.orEmpty().sortedBy { it.name } }

    private fun JsonObject.string(key: String): String? = (this[key] as? JsonPrimitive)?.takeIf { it !is JsonNull }?.content

    private fun JsonObject.strings(key: String): List<String> = (this[key] as? JsonArray)?.map { it.jsonPrimitive.content }.orEmpty()

    private fun ids(values: Collection<String>, sort: Boolean = true): JsonArray =
        buildJsonArray { (if (sort) values.sorted() else values).forEach { add(JsonPrimitive(it)) } }

    /** Each rule, from a case's input to the JSON its expected value is written in. */
    private val rules: Map<String, (JsonObject) -> JsonElement> = mapOf(
        "defaultRange" to { input ->
            val range = DefaultRange.of(input.strings("visibleDays"), input.string("earliest"), input.string("today")!!)
            buildJsonObject {
                put("from", range.from)
                put("to", range.to)
            }
        },
        "pendingChange" to { input ->
            val change = PendingDiff.of(input.strings("previous").toSet(), input.strings("now").toSet(), input.strings("awaiting").toSet())
            buildJsonObject {
                put("started", change.started)
                put("finished", change.finished)
                put("left", ids(change.left))
                put("landed", ids(change.landed))
                put("awaiting", ids(change.awaiting))
            }
        },
        "boldTracks" to { input -> ids(PanelRules.boldIds(input.strings("checked").toSet(), input.string("focused"))) },
        "pendingCheck" to { input ->
            val watched = PendingDiff.watched(input.strings("listed"), input.strings("awaiting"))
            buildJsonObject {
                put("watched", ids(watched, sort = false))
                put("moved", PendingDiff.moved(watched, input.strings("stillPending")))
            }
        },
        "toolbarTarget" to { input -> ids(PanelRules.targetIds(input.strings("checked").toSet(), input.string("focused"))) },
        "targetVisibility" to { input -> ids(PanelRules.toggledVisibility(input.strings("hidden").toSet(), input.strings("target").toSet())) },
        "photoScope" to { input ->
            val edit = (input["editWindowIds"] as? JsonArray)?.map { it.jsonPrimitive.content }
            val scope = PhotoMarkerScope.scope(
                MapMode.valueOf(input.string("mode")!!.uppercase()),
                editOpen = edit != null,
                editSingleId = edit?.singleOrNull(),
                focused = input.string("focused"),
                storyId = input.string("storyId"),
            )
            scope?.split(':', limit = 2)?.let { (kind, id) -> buildJsonObject { put(kind, id) } } ?: JsonNull
        },
        "photoGroup" to { input ->
            val points = input["photos"]!!.jsonArray.map { it.jsonObject["lat"]!!.jsonPrimitive.double to it.jsonObject["lon"]!!.jsonPrimitive.double }
            PhotoMarkerScope.groupFit(points)?.let { box ->
                buildJsonObject { put("fit", buildJsonArray { box.forEach { add(JsonPrimitive(it)) } }) }
            } ?: JsonPrimitive("open")
        },
        "rangeShift" to { input ->
            when (val shift = shiftRange(input.strings("days"), input["hasEarlier"]!!.jsonPrimitive.booleanOrNull!!, range(input["range"]!!.jsonObject), input["dir"]!!.jsonPrimitive.int)) {
                is RangeShift.Shifted -> rangeJson(shift.range)
                RangeShift.None -> JsonNull
                RangeShift.Load -> JsonPrimitive("load")
            }
        },
        "distanceBounds" to { input -> distanceJson(ActivityFacets.distanceBounds(activities(input["activities"]))) },
        "distanceFilter" to { input ->
            val knob = DistanceKnob.valueOf(input.string("knob")!!.uppercase())
            distanceJson(ActivityFacets.nextDistanceFilter(distance(input["bounds"])!!, distance(input["current"])!!, knob, input.number("value")))
        },
        "typeFacets" to { input ->
            buildJsonArray {
                ActivityFacets.typeFacets(activities(input["activities"]), distance(input["distanceFilter"])).forEach { facet ->
                    add(buildJsonObject { put("type", facet.type); put("count", facet.count) })
                }
            }
        },
        "passesFilters" to { input ->
            JsonPrimitive(ActivityFacets.passesFilters(facetActivity(input["activity"]!!.jsonObject), input.strings("excludedTypes").toSet(), distance(input["distanceFilter"])))
        },
        "activityZone" to { input ->
            // A phone zone no case names, so falling through to it reads as null.
            val phone = ZoneId.of("Pacific/Kiritimati")
            JsonPrimitive(ActivityZone.of(input.string("own"), input.string("account"), phone).takeIf { it != phone }?.id)
        },
        "photoClusters" to { input ->
            val points = input["points"]!!.jsonArray.map { it.jsonObject }.map { ScreenPoint(it.string("id")!!, it.number("x").toFloat(), it.number("y").toFloat()) }
            buildJsonArray {
                PhotoClusters.cluster(points, input.number("radius").toFloat()).forEach { group ->
                    add(buildJsonObject { put("ids", ids(group.ids, sort = false)); put("x", group.x); put("y", group.y) })
                }
            }
        },
        "photoMarkerSize" to { input -> JsonPrimitive(PhotoClusters.markerSize(input.number("zoom")).name.lowercase()) },
        "photoMarkerLayout" to { input ->
            val points = input["points"]!!.jsonArray.map { it.jsonObject }.map { ScreenPoint(it.string("id")!!, it.number("x").toFloat(), it.number("y").toFloat()) }
            val placed = PhotoClusters.layout(
                points, input.number("zoom"), input.string("activeId"), input.string("loneId"),
                input.number("width").toFloat(), input.number("height").toFloat(), input.number("scale").toFloat(),
            )
            buildJsonArray {
                placed.forEach { m ->
                    add(buildJsonObject {
                        put("ids", ids(m.ids, sort = false)); put("x", m.x); put("y", m.y); put("diameter", m.diameter)
                        put("active", m.active); put("small", m.small)
                    })
                }
            }
        },
        "photoTrackPoint" to { input ->
            val point = photoTrack(input).pointAt(input.number("fraction"))
            buildJsonObject { put("lon", point.lon); put("lat", point.lat); put("t", point.t) }
        },
        "photoTrackFraction" to { input -> JsonPrimitive(photoTrack(input).fractionAt(input["t"]!!.jsonPrimitive.long)) },
        "photoTrackStart" to { input ->
            val placed = input["placed"]!!.jsonObject.mapValues { (it.value as? JsonPrimitive)?.takeIf { v -> v !is JsonNull }?.double }
            val anchors = input["anchors"]!!.jsonObject.mapValues { anchor(it.value) }
            JsonPrimitive(photoTrack(input).startFraction(anchor(input["anchor"]), placed, anchors))
        },
        "photoFit" to { input -> sizeJson(PhotoZoom.fitSize(size(input["image"]), size(input["stage"]))) },
        "photoZoom" to { input ->
            val point = input["point"]!!.jsonObject
            viewJson(PhotoZoom.zoomAt(view(input), input.number("factor").toFloat(), point.number("x").toFloat(), point.number("y").toFloat(), size(input["fitted"]), size(input["stage"])))
        },
        "photoPan" to { input ->
            viewJson(PhotoZoom.panBy(view(input), input.number("dx").toFloat(), input.number("dy").toFloat(), size(input["fitted"]), size(input["stage"])))
        },
        "photoClamp" to { input -> viewJson(PhotoZoom.clamp(view(input), size(input["fitted"]), size(input["stage"]))) },
        "distanceParts" to { input -> partsJson(FormatParts.distance(input.number("meters"), input.string("system") == "imperial")) },
        "totalDistanceParts" to { input -> partsJson(FormatParts.totalDistance(input.number("meters"), input.string("system") == "imperial")) },
        "durationParts" to { input ->
            val (key, args) = when (val parts = FormatParts.duration(input["seconds"]!!.jsonPrimitive.long)) {
                is DurationParts.HoursMinutes -> "duration.hm" to buildJsonObject { put("h", parts.h); put("m", parts.m) }
                is DurationParts.Minutes -> "duration.m" to buildJsonObject { put("m", parts.m) }
                is DurationParts.Seconds -> "duration.s" to buildJsonObject { put("s", parts.s) }
            }
            buildJsonObject { put("key", key); put("args", args) }
        },
        "editTrackFold" to { input -> editJson(EditTrackOps.fold(edit(input["base"]), ops(input))) },
        "editTrackApply" to { input -> buildJsonArray { EditTrackOps.apply(points(input["points"]), edit(input["edit"])!!).forEach { add(pointJson(it)) } } },
        "editTrackChop" to { input -> opJson(EditTrackOps.chop(points(input["visible"]), input.int("lo"), input.int("hi"))) },
        "editTrackCut" to { input -> opJson(EditTrackOps.cut(points(input["visible"]), input.int("lo"), input.int("hi"))) },
        "editTrackSplitIndex" to { input -> JsonPrimitive(EditTrackOps.splitIndex(points(input["visible"]), input.int("lo"), input.int("hi"))) },
        "editTrackSplitPoint" to { input -> JsonPrimitive(EditTrackOps.splitPoint(ops(input))) },
        "editTrackMove" to { input -> opJson(EditTrackOps.move(input["t"]!!.jsonPrimitive.long, input.number("lon"), input.number("lat"))) },
        "editTrackDistances" to { input -> buildJsonArray { EditTrackOps.cumulativeDistances(points(input["points"])).forEach { add(JsonPrimitive(it)) } } },
        "layerInsertion" to { input ->
            MapLayersDoc.insertionPoint(input.strings("current"), input.strings("order"), input.string("id")!!, input.strings("own").toSet(), input.string("fallback"))
                ?.let(::JsonPrimitive) ?: JsonNull
        },
        "layerLift" to { input -> JsonPrimitive(MapLayersDoc.needsLift(input.strings("current"), input.string("id")!!, input.strings("own").toSet())) },
        "panelState" to { input ->
            val all = input["activities"]!!.jsonArray.map { it.jsonObject }.map { facetActivity(it).copy(id = it.string("id")!!) }
            val state = input["state"]!!.jsonObject
            val panel = PanelState()
            panel.setActivities(all)
            // Hidden first: hiding goes through the toolbar's target, the checked group.
            state.strings("hidden").forEach { panel.toggleChecked(it) }
            panel.toggleTargetVisibility()
            panel.clearChecked()
            state.strings("checked").forEach { panel.toggleChecked(it) }
            state.string("focused")?.let(panel::focus)
            state.strings("excludedTypes").forEach(panel::toggleType)
            panel.setDistanceFilter(distance(state["distanceFilter"]))
            val event = input["event"]!!.jsonObject
            when (val type = event.string("type")) {
                "checkToggled" -> panel.toggleChecked(event.string("id")!!)
                "checkAll" -> panel.checkAll()
                "checksCleared" -> panel.clearChecked()
                "checksInverted" -> panel.invertChecked()
                "visibilityToggled" -> panel.toggleTargetVisibility()
                "typeToggled" -> panel.toggleType(event.string("activityType")!!)
                "distanceSet" -> panel.setDistanceFilter(distance(event["filter"]))
                "filtersReset" -> panel.resetFilters()
                "listLoaded" -> event.strings("ids").toSet().let { ids -> panel.setActivities(all.filter { it.id in ids }) }
                "rangePicked" -> panel.resetForNewRange()
                else -> error("no Android event $type")
            }
            buildJsonObject {
                put("checked", ids(panel.checked))
                put("focused", panel.focused?.let(::JsonPrimitive) ?: JsonNull)
                put("hidden", ids(panel.hidden))
                put("excludedTypes", ids(panel.excludedTypes))
                put("distanceFilter", distanceJson(panel.distanceFilter))
            }
        },
        "sliderLayout" to { input ->
            val layout = SliderRules.layout(input.int("width"), input["finePointer"]!!.jsonPrimitive.boolean)
            buildJsonObject { put("buttons", layout.buttons); put("days", layout.days) }
        },
        "sliderBoundaries" to { input ->
            val (start, end) = SliderRules.boundaries(sliderWindow(input), range(input["range"]!!.jsonObject))
            buildJsonObject { put("start", start); put("end", end) }
        },
        "sliderMoveKnob" to { input ->
            val knob = if (input.string("knob") == "start") SliderRules.Knob.START else SliderRules.Knob.END
            rangeJson(SliderRules.moveKnob(sliderWindow(input), range(input["range"]!!.jsonObject), knob, input.int("boundary")))
        },
        "sliderTicks" to { input ->
            buildJsonArray {
                SliderRules.ticks(input.strings("days")).forEach { tick ->
                    add(buildJsonObject {
                        put("boundary", tick.boundary)
                        put("kind", if (tick.monthStart) "month" else "day")
                        put("month", tick.month?.let(::JsonPrimitive) ?: JsonNull)
                    })
                }
            }
        },
        "sliderPanLand" to { input ->
            val pulled = { key: String -> input[key]!!.jsonPrimitive.boolean }
            rangeJson(SliderRules.panLand(input.strings("days"), range(input["range"]!!.jsonObject), pulled("start"), pulled("end")))
        },
        "sliderWindowFit" to { input ->
            JsonPrimitive(SliderRules.windowFit(input.int("count"), input.int("windowDays"), input.int("left"), input.int("first"), input.int("last"), input.int("dir")))
        },
        "session" to { input ->
            val state = input["state"]!!.jsonObject
            val panel = PanelState()
            val session = MapSession(panel)
            (state["range"] as? JsonObject)?.let { session.restore(range(it), state["userPicked"]?.jsonPrimitive?.booleanOrNull ?: false) }
            // The Story first: opening one resets the selection set up below.
            state.string("storyId")?.let { session.enterStory(it); session.consumeFly() }
            val ids = (state.strings("checked") + state.strings("hidden")).distinct()
            panel.setActivities(ids.map(::activity))
            // Hidden first: hiding goes through the toolbar's target, the checked group.
            state.strings("hidden").forEach { panel.toggleChecked(it) }
            panel.toggleTargetVisibility()
            panel.clearChecked()
            state.strings("checked").forEach { panel.toggleChecked(it) }
            state.strings("excludedTypes").forEach(panel::toggleType)
            val event = input["event"]!!.jsonObject
            when (val type = event.string("type")) {
                "rangePicked" -> session.pickRange(range(event["range"]!!.jsonObject))
                "defaultRange" -> session.offerDefault(range(event["range"]!!.jsonObject), event["editOpen"]?.jsonPrimitive?.booleanOrNull ?: false)
                "storyEntered" -> session.enterStory(event.string("id")!!)
                "storyExited" -> session.exitStory()
                else -> error("no Android event $type")
            }
            buildJsonObject {
                session.range?.let { put("range", rangeJson(it)) }
                put("userPicked", session.userPicked)
                session.storyId?.let { put("storyId", it) }
                put("checked", ids(panel.checked))
                put("hidden", ids(panel.hidden))
                put("excludedTypes", ids(panel.excludedTypes))
                put("flyRequest", session.flyRequest)
            }
        },
    )

    private fun range(json: JsonObject) = DateRange(json.string("from")!!, json.string("to")!!)

    private fun sliderWindow(input: JsonObject) = SliderRules.Window(
        input.strings("days"),
        input["canPanEarlier"]!!.jsonPrimitive.boolean,
        input["canPanLater"]!!.jsonPrimitive.boolean,
    )

    private fun rangeJson(range: DateRange) = buildJsonObject {
        put("from", range.from)
        put("to", range.to)
    }

    private fun JsonObject.int(key: String): Int = this[key]!!.jsonPrimitive.int

    private fun JsonObject.number(key: String): Double = this[key]!!.jsonPrimitive.double

    private fun partsJson(parts: DistanceParts) = buildJsonObject {
        put("value", parts.value)
        put("minDecimals", parts.minDecimals)
        put("maxDecimals", parts.maxDecimals)
        put("grouping", parts.grouping)
        put("unit", parts.unit.name.lowercase())
    }

    private fun distance(json: JsonElement?): DistanceRange? = (json as? JsonObject)?.let { DistanceRange(it.number("min"), it.number("max")) }

    private fun distanceJson(range: DistanceRange?): JsonElement = range?.let { buildJsonObject { put("min", it.min); put("max", it.max) } } ?: JsonNull

    private fun activities(json: JsonElement?) = json!!.jsonArray.map { facetActivity(it.jsonObject) }

    private fun facetActivity(json: JsonObject) = activity("a").copy(
        activityType = json.string("activityType")!!,
        distanceMeters = (json["distanceMeters"] as? JsonPrimitive)?.takeIf { it !is JsonNull }?.double,
        isPrivate = json["private"]?.jsonPrimitive?.booleanOrNull ?: false,
    )

    private fun photoTrack(input: JsonObject) = PhotoTrack(
        input["points"]!!.jsonArray.map { it.jsonObject }.map { TimedPoint(it.number("lon"), it.number("lat"), it["t"]!!.jsonPrimitive.long) },
    )

    private fun anchor(json: JsonElement?): PlaceAnchor? = (json as? JsonObject)?.let {
        it.string("waiting")?.let(PlaceAnchor::Waiting) ?: PlaceAnchor.At(it["t"]!!.jsonPrimitive.long)
    }

    private fun size(json: JsonElement?) = json!!.jsonObject.let { PhotoZoom.Size(it.number("width").toFloat(), it.number("height").toFloat()) }

    private fun sizeJson(size: PhotoZoom.Size) = buildJsonObject { put("width", size.width); put("height", size.height) }

    private fun view(input: JsonObject) = input["view"]!!.jsonObject.let { PhotoZoom.View(it.number("scale").toFloat(), it.number("x").toFloat(), it.number("y").toFloat()) }

    private fun viewJson(view: PhotoZoom.View) = buildJsonObject { put("scale", view.scale); put("x", view.x); put("y", view.y) }

    private fun points(json: JsonElement?): List<TrackPoint> = json!!.jsonArray.map { point ->
        val (lon, lat, t) = point.jsonArray.map { it.jsonPrimitive }
        TrackPoint(lon.double, lat.double, t.long)
    }

    private fun pointJson(point: TrackPoint) = buildJsonArray {
        add(JsonPrimitive(point.lon))
        add(JsonPrimitive(point.lat))
        add(JsonPrimitive(point.t))
    }

    private fun span(json: JsonElement): Pair<Long, Long> = json.jsonArray.let { it[0].jsonPrimitive.long to it[1].jsonPrimitive.long }

    private fun spanJson(span: Pair<Long, Long>) = buildJsonArray {
        add(JsonPrimitive(span.first))
        add(JsonPrimitive(span.second))
    }

    private fun edit(json: JsonElement?): TrackEdit? = (json as? JsonObject)?.let { edit ->
        TrackEdit(
            keep = (edit["keep"] as? JsonArray)?.let(::span),
            remove = (edit["remove"] as? JsonArray)?.map(::span).orEmpty(),
            drop = (edit["drop"] as? JsonArray)?.map { it.jsonPrimitive.long }.orEmpty(),
            move = (edit["move"] as? JsonObject)?.entries?.associate { (t, to) -> t.toLong() to (to.jsonArray[0].jsonPrimitive.double to to.jsonArray[1].jsonPrimitive.double) }.orEmpty(),
        )
    }

    /** The edit with its empty fields left out, as the web folds it. */
    private fun editJson(edit: TrackEdit) = buildJsonObject {
        edit.keep?.let { put("keep", spanJson(it)) }
        if (edit.remove.isNotEmpty()) put("remove", buildJsonArray { edit.remove.forEach { add(spanJson(it)) } })
        if (edit.drop.isNotEmpty()) put("drop", buildJsonArray { edit.drop.forEach { add(JsonPrimitive(it)) } })
        if (edit.move.isNotEmpty()) {
            put("move", buildJsonObject { edit.move.forEach { (t, to) -> put(t.toString(), buildJsonArray { add(JsonPrimitive(to.first)); add(JsonPrimitive(to.second)) }) } })
        }
    }

    private fun ops(input: JsonObject): List<EditOp> = input["ops"]!!.jsonArray.map { it.jsonObject }.map { op ->
        when (val kind = op.string("kind")) {
            "chop" -> EditOp.Chop(span(op["keep"]!!))
            "cut" -> EditOp.Cut(span(op["remove"]!!))
            "drop" -> EditOp.Drop(op["t"]!!.jsonPrimitive.long)
            "move" -> op["to"]!!.jsonArray.let { EditOp.Move(op["t"]!!.jsonPrimitive.long, it[0].jsonPrimitive.double, it[1].jsonPrimitive.double) }
            "reset" -> EditOp.Reset
            "split" -> EditOp.Split(op["t"]!!.jsonPrimitive.long)
            else -> error("no Android op $kind")
        }
    }

    private fun opJson(op: EditOp?): JsonElement = when (op) {
        null -> JsonNull
        is EditOp.Chop -> buildJsonObject { put("kind", "chop"); put("keep", spanJson(op.keep)) }
        is EditOp.Cut -> buildJsonObject { put("kind", "cut"); put("remove", spanJson(op.remove)) }
        is EditOp.Drop -> buildJsonObject { put("kind", "drop"); put("t", op.t) }
        is EditOp.Move -> buildJsonObject {
            put("kind", "move")
            put("t", op.t)
            put("to", buildJsonArray { add(JsonPrimitive(op.lon)); add(JsonPrimitive(op.lat)) })
        }
        EditOp.Reset -> buildJsonObject { put("kind", "reset") }
        is EditOp.Split -> buildJsonObject { put("kind", "split"); put("t", op.t) }
    }

    private fun activity(id: String) = Activity(
        id = id, startedAt = "2026-10-01T08:00:00Z", activityType = "walking", name = null, distanceMeters = 1000.0,
        durationSeconds = 600, description = null, bbox = listOf(0.0, 0.0, 1.0, 1.0), pending = false, edited = false,
    )

    /** Numbers compared as numbers, so 24.75 and 24.750 agree; a missing field means the same as null. */
    private fun normalized(element: JsonElement): JsonElement = when (element) {
        is JsonObject -> JsonObject(element.filterValues { it !is JsonNull }.mapValues { normalized(it.value) })
        is JsonArray -> JsonArray(element.map(::normalized))
        is JsonPrimitive -> if (element.isString || element.booleanOrNull != null || element is JsonNull) element else JsonPrimitive(element.double)
    }

    /** Equal as JSON, numbers within [tolerance]. */
    private fun assertClose(message: String, expected: JsonElement, actual: JsonElement, tolerance: Double) {
        when {
            expected is JsonPrimitive && !expected.isString && expected !is JsonNull && expected.booleanOrNull == null -> {
                val value = (actual as? JsonPrimitive)?.takeIf { !it.isString && it !is JsonNull && it.booleanOrNull == null }
                    ?: throw AssertionError("$message: $actual is not a number")
                assertTrue("$message: ${value.double} is not within $tolerance of ${expected.double}", kotlin.math.abs(value.double - expected.double) <= tolerance)
            }
            expected is JsonArray -> {
                val items = actual as? JsonArray
                assertTrue("$message: $actual is not $expected", items != null && items.size == expected.size)
                expected.forEachIndexed { i, item -> assertClose("$message[$i]", item, items!![i], tolerance) }
            }
            expected is JsonObject -> {
                val fields = actual as? JsonObject ?: throw AssertionError("$message: $actual is not an object")
                for (key in expected.keys + fields.keys) assertClose("$message.$key", expected[key] ?: JsonNull, fields[key] ?: JsonNull, tolerance)
            }
            else -> assertEquals(message, expected, actual)
        }
    }

    private fun JsonElement?.double(): Double? = (this as? JsonPrimitive)?.takeIf { it !is JsonNull }?.double

    @Test
    fun `every shared rule file has an Android implementation`() {
        assertTrue("no cases in $dir", files.isNotEmpty())
        for (file in files) {
            val rule = Json.parseToJsonElement(file.readText()).jsonObject.string("rule")
            assertTrue("${file.name}: no Android implementation of $rule", rule in rules)
        }
    }

    @Test
    fun `every shared case holds`() {
        for (file in files) {
            val doc = Json.parseToJsonElement(file.readText()).jsonObject
            val rule = doc.string("rule")!!
            val run = rules[rule] ?: continue
            val cases = doc["cases"]!!.jsonArray + (doc["generated"]?.jsonArray ?: JsonArray(emptyList()))
            for (case in cases.map { it.jsonObject }) {
                val message = "$rule: ${case.string("name")}"
                val expected = case["expected"] ?: JsonNull
                val input = case["input"]!!.jsonObject
                if ((expected as? JsonObject)?.get("throws")?.jsonPrimitive?.booleanOrNull == true) {
                    assertThrows(message, Throwable::class.java) { run(input) }
                    continue
                }
                val tolerance = case["tolerance"].double() ?: doc["tolerance"].double()
                if (tolerance == null) assertEquals(message, normalized(expected), normalized(run(input)))
                else assertClose(message, normalized(expected), normalized(run(input)), tolerance)
            }
        }
    }
}
