package dev.holdmytrack.android

import dev.holdmytrack.android.export.ExportStatsRules
import dev.holdmytrack.android.imports.UploadPlan
import dev.holdmytrack.android.map.BasemapStatus
import dev.holdmytrack.android.map.FitBoxes
import dev.holdmytrack.android.map.FogLevels
import dev.holdmytrack.android.map.FogPlaceLabel
import dev.holdmytrack.android.map.MapLayersDoc
import dev.holdmytrack.android.map.MapMode
import dev.holdmytrack.android.map.AreaLoad
import dev.holdmytrack.android.map.DateFilter
import dev.holdmytrack.android.map.MapSession
import dev.holdmytrack.android.map.OpeningView
import dev.holdmytrack.android.map.PendingDiff
import dev.holdmytrack.android.map.SatelliteStatus
import dev.holdmytrack.android.net.AttachmentName
import dev.holdmytrack.android.net.deleteDone
import dev.holdmytrack.android.net.Track
import dev.holdmytrack.android.net.RouteEdit
import dev.holdmytrack.android.net.RoutePoint
import dev.holdmytrack.android.panel.DownloadRules
import dev.holdmytrack.android.panel.LibraryRules
import dev.holdmytrack.android.panel.TrackFacets
import dev.holdmytrack.android.recording.RecordingTypes
import dev.holdmytrack.android.sync.Similar
import kotlinx.serialization.json.longOrNull
import java.time.LocalDate
import dev.holdmytrack.android.profile.YouRefresh
import dev.holdmytrack.android.profile.ProfileStats
import dev.holdmytrack.android.net.TrackDay
import java.time.Instant
import dev.holdmytrack.android.recording.TypeCount
import dev.holdmytrack.android.recording.TypeSearch
import dev.holdmytrack.android.panel.TrackZone
import dev.holdmytrack.android.panel.DistanceKnob
import dev.holdmytrack.android.panel.DistanceRange
import dev.holdmytrack.android.panel.DistanceParts
import dev.holdmytrack.android.panel.DurationParts
import dev.holdmytrack.android.panel.EditOp
import dev.holdmytrack.android.map.Circle
import dev.holdmytrack.android.map.PrivateLocationsOverlay
import dev.holdmytrack.android.panel.EditRouteOps
import dev.holdmytrack.android.panel.FormatParts
import dev.holdmytrack.android.panel.PanelRules
import dev.holdmytrack.android.panel.PanelState
import dev.holdmytrack.android.panel.PanelTab
import dev.holdmytrack.android.photos.PhotoClusters
import dev.holdmytrack.android.photos.PhotoMarkerScope
import dev.holdmytrack.android.photos.PhotoRoute
import dev.holdmytrack.android.photos.PhotoZoom
import dev.holdmytrack.android.photos.PlaceAnchor
import dev.holdmytrack.android.photos.ScreenPoint
import dev.holdmytrack.android.photos.TimedPoint
import dev.holdmytrack.android.web.WebRoute
import dev.holdmytrack.android.tour.TourCamera
import dev.holdmytrack.android.tour.TourCard
import dev.holdmytrack.android.tour.TourEvent
import dev.holdmytrack.android.tour.TourRules
import dev.holdmytrack.android.tour.TourSeen
import dev.holdmytrack.android.tour.TourStep
import dev.holdmytrack.android.tour.TourView
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
import kotlinx.serialization.json.doubleOrNull
import kotlinx.serialization.json.int
import kotlinx.serialization.json.intOrNull
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

    /** Every file whose `clients`, when it names any, include Android. */
    private val files: List<File> by lazy {
        dir.listFiles { file -> file.extension == "json" }.orEmpty().sortedBy { it.name }.filter { file ->
            val clients = Json.parseToJsonElement(file.readText()).jsonObject["clients"]?.jsonArray
            clients == null || clients.any { it.jsonPrimitive.content == "android" }
        }
    }

    private fun JsonObject.string(key: String): String? = (this[key] as? JsonPrimitive)?.takeIf { it !is JsonNull }?.content

    private fun typeCountList(json: JsonElement?): List<TypeCount> =
        (json as? JsonArray).orEmpty().map { it.jsonObject.let { o -> TypeCount(o.string("type")!!, o["count"]!!.jsonPrimitive.int) } }

    private fun typeCounts(list: List<TypeCount>): JsonArray =
        buildJsonArray { list.forEach { add(buildJsonObject { put("type", it.type); put("count", it.count) }) } }

    private fun JsonObject.strings(key: String): List<String> = (this[key] as? JsonArray)?.map { it.jsonPrimitive.content }.orEmpty()

    private fun JsonObject.bool(key: String): Boolean = (this[key] as? JsonPrimitive)?.booleanOrNull ?: false

    /** A case's Fog levels, each a band without layers. */
    private fun fogLevels(input: JsonObject): List<FogLevels.Level> = input["levels"]!!.jsonArray.map {
        val l = it.jsonObject
        FogLevels.Level(l.string("level")!!, (l["from"] as? JsonPrimitive)?.doubleOrNull, (l["below"] as? JsonPrimitive)?.doubleOrNull)
    }

    /** A case's Library state; a field it leaves out is at its default. */
    private fun libraryState(json: JsonObject) = LibraryRules.State(
        sort = json.string("sort")?.let { LibraryRules.Sort.valueOf(enumName(it)) } ?: LibraryRules.Sort.STARTED,
        desc = (json["desc"] as? JsonPrimitive)?.booleanOrNull ?: true,
        page = (json["page"] as? JsonPrimitive)?.intOrNull ?: 1,
        q = json.string("q").orEmpty(),
        exclude = json.strings("exclude").toSet(),
        distance = (json["distance"] as? JsonObject)?.let { LibraryRules.Distance(it.number("min"), (it["max"] as? JsonPrimitive)?.doubleOrNull) },
        after = json.string("after"),
        before = json.string("before"),
        trip = json.string("trip"),
    )

    private fun enumName(name: String) = name.uppercase()
    private fun caseName(enumName: String) = enumName.lowercase()

    /** A case's tab: the web's panel tabs, which Android's bottom bar names alike. */
    private fun tourTab(name: String) = MainActivity.Tab.valueOf(enumName(name))

    private fun tourSeen(seen: JsonObject) = TourSeen(seen.bool("tour"), seen.strings("cards").map { TourCard.valueOf(enumName(it)) }.toSet())

    private fun ids(values: Collection<String>, sort: Boolean = true): JsonArray =
        buildJsonArray { (if (sort) values.sorted() else values).forEach { add(JsonPrimitive(it)) } }

    /** Each rule, from a case's input to the JSON its expected value is written in. */
    private val rules: Map<String, (JsonObject) -> JsonElement> = mapOf(
        "tourStart" to { input ->
            val hasTracks = (input["hasTracks"] as? JsonPrimitive)?.takeIf { it !is JsonNull }?.boolean
            JsonPrimitive(TourRules.start(input.bool("requested"), input.bool("isDemo"), hasTracks, tourSeen(input["seen"]!!.jsonObject)).name.lowercase())
        },
        "tourCard" to { input ->
            val event = input["event"]!!.jsonObject
            val tourEvent = when (event.string("kind")) {
                "mode" -> TourEvent.Mode(MapMode.valueOf(event.string("mode")!!.uppercase()))
                else -> TourEvent.Tab(PanelTab.valueOf(enumName(event.string("tab")!!)))
            }
            JsonPrimitive(TourRules.card(tourEvent, tourSeen(input["seen"]!!.jsonObject), input.bool("touring"))?.name?.let(::caseName))
        },
        "tourCamera" to { input ->
            fun view(element: JsonElement?): TourView? = (element as? JsonObject)?.let { TourView(it.number("lon"), it.number("lat"), it.number("zoom")) }
            fun json(v: TourView?): JsonElement = v?.let { buildJsonObject { put("lon", it.lon); put("lat", it.lat); put("zoom", it.zoom) } } ?: JsonNull
            val camera = TourCamera(view(input["start"]), view(input["shown"]))
            val step = input["step"] as? JsonObject
            if (step == null) {
                buildJsonObject { put("start", JsonNull); put("shown", JsonNull); put("move", json(TourRules.cameraEnd(camera))) }
            } else {
                val (next, move) = TourRules.camera(camera, view(step["view"]), tourTab(step.string("tab")!!), view(input["current"])!!)
                buildJsonObject { put("start", json(next.start)); put("shown", json(next.shown)); put("move", json(move)) }
            }
        },
        "tourStep" to { input ->
            val now = input["now"]!!.jsonObject
            val restore = input["restore"]!!.jsonObject
            val step = (input["step"] as? JsonObject)?.let {
                TourStep("case", null, tab = tourTab(it.string("tab")!!), mode = MapMode.valueOf(it.string("mode")!!.uppercase()), card = it.string("card")?.let { c -> TourCard.valueOf(enumName(c)) })
            }
            val changes = TourRules.changes(
                MapMode.valueOf(now.string("mode")!!.uppercase()), tourTab(now.string("tab")!!), step,
                MapMode.valueOf(restore.string("mode")!!.uppercase()), tourTab(restore.string("tab")!!),
            )
            buildJsonObject {
                put("mode", changes.mode?.name?.lowercase())
                put("tab", changes.tab?.name?.let(::caseName))
                put("card", changes.card?.name?.let(::caseName))
            }
        },
        "tourNextStep" to { input ->
            JsonPrimitive(TourRules.nextStep(input["shown"]!!.jsonArray.map { it.jsonPrimitive.boolean }, input.number("from").toInt(), input.number("dir").toInt()))
        },
        "pendingChange" to { input ->
            val change = PendingDiff.of(input.strings("previous").toSet(), input.strings("now").toSet(), input.strings("awaiting").toSet(), input.strings("listed").toSet())
            buildJsonObject {
                put("started", change.started)
                put("finished", change.finished)
                put("left", ids(change.left))
                put("landed", ids(change.landed))
                put("awaiting", ids(change.awaiting))
                put("pending", ids(change.pending))
            }
        },
        "boldTracks" to { input -> ids(PanelRules.boldIds(input.strings("checked").toSet(), input.string("focused"))) },
        "attachmentName" to { input -> JsonPrimitive(AttachmentName.of(input.string("header"))) },
        "libraryPageQuery" to { input ->
            LibraryRules.pageQuery(libraryState(input["state"]!!.jsonObject), input.strings("allTypes"))?.let { q ->
                buildJsonObject {
                    put("page", q.page)
                    put("sort", q.sort)
                    q.q?.let { put("q", it) }
                    q.types?.let { put("types", buildJsonArray { it.forEach { t -> add(JsonPrimitive(t)) } }) }
                    q.minDistance?.let { put("minDistance", it) }
                    q.maxDistance?.let { put("maxDistance", it) }
                    q.from?.let { put("from", it) }
                    q.to?.let { put("to", it) }
                    q.trip?.let { put("trip", it) }
                }
            } ?: JsonNull
        },
        "downloadBlock" to { input ->
            val target = input["tracks"]?.jsonArray?.map {
                val t = it.jsonObject
                DownloadRules.Target(t.string("id")!!, t.bool("pending"), t.bool("private"))
            } ?: List(input.int("plainTracks")) { DownloadRules.Target(it.toString(), pending = false, private = false) }
            val block = if (input.containsKey("max")) DownloadRules.block(target, input.int("max")) else DownloadRules.block(target)
            when (block) {
                null -> JsonNull
                is DownloadRules.Block.TooMany -> buildJsonObject { put("kind", "too_many"); put("count", block.count) }
                is DownloadRules.Block.Pending -> buildJsonObject { put("kind", "pending"); put("track", block.id) }
                is DownloadRules.Block.Private -> buildJsonObject { put("kind", "private"); put("track", block.id) }
            }
        },
        "libraryPager" to { input ->
            LibraryRules.pager(input.int("page"), input.int("total"), input.int("pageSize"))?.let {
                buildJsonObject { put("from", it.from); put("to", it.to); put("prev", it.prev); put("next", it.next) }
            } ?: JsonNull
        },
        "libraryEmptyReason" to { input ->
            JsonPrimitive(caseName(LibraryRules.emptyReason(libraryState(input["state"]!!.jsonObject), input.int("total"), input.bool("anyTrack")).name))
        },
        "deleteDone" to { input -> JsonPrimitive(deleteDone(input.int("status"))) },
        "privateDrawOrder" to { input ->
            val circle = { id: String -> Circle(id, 0.0, 0.0, 200) }
            ids(PrivateLocationsOverlay.drawOrder(input.strings("saved").map(circle), input.string("editing")?.let(circle)).map { it.id!! }, sort = false)
        },
        "profileStats" to { input ->
            val days = input["days"]!!.jsonArray.map { it.jsonObject }.map { TrackDay(it.string("date")!!, it.int("count"), it["distanceMeters"]!!.jsonPrimitive.double) }
            val totals = ProfileStats.statsOf(days)
            val weeks = ProfileStats.recentWeeks(days, LocalDate.parse(input.string("today")!!), input.int("weeks"))
            buildJsonObject {
                put("count", totals.count)
                put("distanceMeters", totals.distanceMeters)
                put("activeDays", totals.activeDays)
                put("longestStreakDays", totals.longestStreakDays)
                put("weeks", buildJsonArray { weeks.forEach { add(JsonPrimitive(it)) } })
            }
        },
        "youRefresh" to { input ->
            fun mark(json: JsonElement?): YouRefresh.Mark? = (json as? JsonObject)?.let {
                YouRefresh.Mark(it["atMs"]!!.jsonPrimitive.long, it.string("tileVersion")!!, LocalDate.parse(it.string("today")!!))
            }
            val reads = YouRefresh.of(mark(input["numbers"]), input["accountAtMs"]?.jsonPrimitive?.longOrNull, mark(input["now"])!!, input["resumed"]!!.jsonPrimitive.boolean)
            buildJsonObject {
                put("account", reads.account)
                put("numbers", reads.numbers)
            }
        },
        "similarSpans" to { input ->
            fun at(span: String, end: String) = Instant.EPOCH.plusNanos(Math.round(input[span]!!.jsonObject[end]!!.jsonPrimitive.double * 1_000_000))
            JsonPrimitive(Similar.overlaps(at("a", "start"), at("a", "end"), at("b", "start"), at("b", "end")))
        },
        "verifyAction" to { input ->
            when (val action = VerifyAction.of(input.string("typed")!!)) {
                VerifyAction.Check -> JsonPrimitive("check")
                is VerifyAction.Submit -> buildJsonObject { put("submit", action.code) }
            }
        },
        "uploadPlan" to { input ->
            val files = input["files"]!!.jsonArray.map { it.jsonObject }.map { UploadPlan.Picked(it.string("name")!!, it.int("size").toLong()) }
            val plan = UploadPlan.of(files)
            buildJsonObject {
                put("send", JsonArray(plan.send.map { JsonPrimitive(it) }))
                put("refusals", JsonArray(plan.refusals.map { refusal ->
                    when (refusal) {
                        is UploadPlan.Refusal.Zip -> buildJsonObject { put("kind", "zip"); put("name", refusal.name) }
                        is UploadPlan.Refusal.WrongType -> buildJsonObject { put("kind", "wrongType"); put("name", refusal.name) }
                        is UploadPlan.Refusal.TooMany -> buildJsonObject { put("kind", "tooMany"); put("count", refusal.count) }
                        is UploadPlan.Refusal.TooLarge -> buildJsonObject { put("kind", "tooLarge"); put("name", refusal.name) }
                    }
                }))
            }
        },
        "pendingBatches" to { input ->
            JsonArray(PendingDiff.batches(input.strings("ids"), input.int("size")).map { ids(it, sort = false) })
        },
        "pendingCheck" to { input ->
            val watched = PendingDiff.watched(input.strings("pending"), input.strings("awaiting"))
            val answer = PendingDiff.answer(watched, input.strings("stillPending"), input.strings("listed").toSet())
            buildJsonObject {
                put("watched", ids(watched, sort = false))
                put("moved", answer.moved)
                put("finished", ids(answer.finished))
            }
        },
        "toolbarTarget" to { input -> ids(PanelRules.targetIds(input.strings("checked").toSet(), input.string("focused"))) },
        "satelliteStatus" to { input ->
            val status = SatelliteStatus.of(input.bool("loaded"), input.bool("failed"), input.number("waitedMs").toLong())
            buildJsonObject { put("status", status.name.lowercase()); put("look", SatelliteStatus.look(input.bool("on"), status)) }
        },
        "statsOffered" to { input -> JsonPrimitive(ExportStatsRules.offered(input.strings("checked").toSet(), input.string("tripId"))) },
        "statsCardPlacement" to { input ->
            val card = input["card"]!!.jsonObject
            val (x, y) = ExportStatsRules.placement(input.int("width"), input.int("height"), card.int("width"), card.int("height"))
            buildJsonObject { put("x", x); put("y", y) }
        },
        "targetVisibility" to { input -> ids(PanelRules.toggledVisibility(input.strings("hidden").toSet(), input.strings("target").toSet())) },
        "photoScope" to { input ->
            val edit = (input["editWindowIds"] as? JsonArray)?.map { it.jsonPrimitive.content }
            val scope = PhotoMarkerScope.scope(
                MapMode.valueOf(input.string("mode")!!.uppercase()),
                editOpen = edit != null,
                editSingleId = edit?.singleOrNull(),
                focused = input.string("focused"),
                tripId = input.string("tripId"),
            )
            scope?.split(':', limit = 2)?.let { (kind, id) -> buildJsonObject { put(kind, id) } } ?: JsonNull
        },
        "photoGroup" to { input ->
            val points = input["photos"]!!.jsonArray.map { it.jsonObject["lat"]!!.jsonPrimitive.double to it.jsonObject["lon"]!!.jsonPrimitive.double }
            PhotoMarkerScope.groupFit(points)?.let { box ->
                buildJsonObject { put("fit", buildJsonArray { box.forEach { add(JsonPrimitive(it)) } }) }
            } ?: JsonPrimitive("open")
        },
        "distanceBounds" to { input -> distanceJson(TrackFacets.distanceBounds(tracks(input["tracks"]))) },
        "distanceFilter" to { input ->
            val knob = DistanceKnob.valueOf(input.string("knob")!!.uppercase())
            distanceJson(TrackFacets.nextDistanceFilter(distance(input["bounds"])!!, distance(input["current"])!!, knob, input.number("value")))
        },
        "typeFacets" to { input ->
            buildJsonArray {
                TrackFacets.typeFacets(tracks(input["tracks"]), distance(input["distanceFilter"])).forEach { facet ->
                    add(buildJsonObject { put("type", facet.type); put("count", facet.count) })
                }
            }
        },
        "typeSearch" to { input ->
            val options = input["options"]!!.jsonArray.map { it.jsonObject.let { o -> TypeSearch.Option(o.string("value")!!, o.string("label")!!) } }
            val result = TypeSearch.search(options, input.string("query")!!, input["maxLength"]!!.jsonPrimitive.int)
            buildJsonObject {
                put("shown", buildJsonArray { result.shown.forEach { add(JsonPrimitive(it.value)) } })
                put("add", result.add?.let(::JsonPrimitive) ?: JsonNull)
            }
        },
        "typeOptions" to { input ->
            typeCounts(TypeSearch.options(input.string("current")!!, typeCountList(input["known"])))
        },
        "recordingTypes" to { input ->
            val server = LinkedHashMap<String, Int>().apply { typeCountList(input["server"]).forEach { put(it.type, it.count) } }
            typeCounts(RecordingTypes.known(server, input.strings("local")))
        },
        "passesFilters" to { input ->
            JsonPrimitive(TrackFacets.passesFilters(facetTrack(input["track"]!!.jsonObject), input.strings("excludedTypes").toSet(), distance(input["distanceFilter"])))
        },
        "trackZone" to { input ->
            // A phone zone no case names, so falling through to it reads as null.
            val phone = ZoneId.of("Pacific/Kiritimati")
            JsonPrimitive(TrackZone.of(input.string("own"), input.string("account"), phone).takeIf { it != phone }?.id)
        },
        "photoClusters" to { input ->
            val points = input["points"]!!.jsonArray.map { it.jsonObject }.map { ScreenPoint(it.string("id")!!, it.number("x").toFloat(), it.number("y").toFloat()) }
            buildJsonArray {
                PhotoClusters.cluster(points, input.number("radius").toFloat()).forEach { group ->
                    add(buildJsonObject { put("ids", ids(group.ids, sort = false)); put("x", group.x); put("y", group.y) })
                }
            }
        },
        "fogLevelInView" to { input -> JsonPrimitive(FogLevels.inView(fogLevels(input), input.number("zoom"), input.string("locked"))) },
        "fogLevelPick" to { input ->
            val pick = FogLevels.pick(fogLevels(input), input.number("zoom"), input.string("locked"), input.string("picked")!!)
            buildJsonObject {
                put("locked", pick.locked?.let(::JsonPrimitive) ?: JsonNull)
                put("zoom", pick.zoom?.let(::JsonPrimitive) ?: JsonNull)
            }
        },
        "fogPlaceLabel" to { input ->
            val catalog = input.strings("catalog").toSet()
            val props = input["props"]!!.jsonObject.mapValues { (_, v) ->
                (v as? JsonPrimitive)?.let { p -> p.booleanOrNull ?: p.doubleOrNull ?: p.content }
            }
            val label = FogPlaceLabel.of(props) { it in catalog }
            label?.let { l ->
                buildJsonObject {
                    put("name", l.name)
                    put("kindKey", l.kindKey)
                    put("within", l.within)
                    put("visitedKey", l.visitedKey)
                    put("counts", buildJsonArray {
                        l.counts.forEach { c -> add(buildJsonObject { put("key", c.key); put("explored", c.explored); put("total", c.total) }) }
                    })
                }
            } ?: JsonNull
        },
        "basemapStatus" to { input -> JsonPrimitive(BasemapStatus.of(input.bool("loaded"), input.bool("failed"), input.number("waitedMs").toLong()).name.lowercase()) },
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
        "photoRoutePoint" to { input ->
            val point = photoRoute(input).pointAt(input.number("fraction"))
            buildJsonObject { put("lon", point.lon); put("lat", point.lat); put("t", point.t) }
        },
        "photoRouteFraction" to { input -> JsonPrimitive(photoRoute(input).fractionAt(input["t"]!!.jsonPrimitive.long)) },
        "photoRouteStart" to { input ->
            val placed = input["placed"]!!.jsonObject.mapValues { (it.value as? JsonPrimitive)?.takeIf { v -> v !is JsonNull }?.double }
            val anchors = input["anchors"]!!.jsonObject.mapValues { anchor(it.value) }
            JsonPrimitive(photoRoute(input).startFraction(anchor(input["anchor"]), placed, anchors))
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
        "editRouteFold" to { input -> editJson(EditRouteOps.fold(edit(input["base"]), ops(input))) },
        "editRouteApply" to { input -> buildJsonArray { EditRouteOps.apply(points(input["points"]), edit(input["edit"])!!).forEach { add(pointJson(it)) } } },
        "editRouteChop" to { input -> opJson(EditRouteOps.chop(points(input["visible"]), input.int("lo"), input.int("hi"))) },
        "editRouteCut" to { input -> opJson(EditRouteOps.cut(points(input["visible"]), input.int("lo"), input.int("hi"))) },
        "editRouteSplitIndex" to { input -> JsonPrimitive(EditRouteOps.splitIndex(points(input["visible"]), input.int("lo"), input.int("hi"))) },
        "editRouteSplitPoint" to { input -> JsonPrimitive(EditRouteOps.splitPoint(ops(input))) },
        "editRouteMove" to { input -> opJson(EditRouteOps.move(input["t"]!!.jsonPrimitive.long, input.number("lon"), input.number("lat"))) },
        "editRouteDistances" to { input -> buildJsonArray { EditRouteOps.cumulativeDistances(points(input["points"])).forEach { add(JsonPrimitive(it)) } } },
        "layerInsertion" to { input ->
            MapLayersDoc.insertionPoint(input.strings("current"), input.strings("order"), input.string("id")!!, input.strings("own").toSet(), input.string("fallback"))
                ?.let(::JsonPrimitive) ?: JsonNull
        },
        "webPageRoute" to { input ->
            val link = input["link"]!!.jsonObject
            val base = input["base"]!!.jsonObject
            val route = WebRoute.of(
                link.string("scheme"), link.string("authority"), link.string("path"), link.string("track"), link.string("day"),
                base.string("scheme"), base.string("authority"), input.string("page")!!,
                input["leaving"]?.jsonPrimitive?.booleanOrNull == true, input["onboarding"]?.jsonPrimitive?.booleanOrNull == true,
                input["post"]?.jsonPrimitive?.booleanOrNull == true,
            )
            when (route) {
                WebRoute.Route.Stay -> JsonPrimitive("stay")
                WebRoute.Route.Outside -> JsonPrimitive("outside")
                WebRoute.Route.Ignore -> JsonPrimitive("ignore")
                WebRoute.Route.Close -> JsonPrimitive("close")
                WebRoute.Route.Onboarded -> JsonPrimitive("onboarded")
                is WebRoute.Route.ViewOnMap -> buildJsonObject {
                    put("viewOnMap", buildJsonObject { put("track", route.track); put("day", route.day) })
                }
            }
        },
        "layerLift" to { input -> JsonPrimitive(MapLayersDoc.needsLift(input.strings("current"), input.string("id")!!, input.strings("own").toSet())) },
        "panelState" to { input ->
            val all = input["tracks"]!!.jsonArray.map { it.jsonObject }.map { facetTrack(it).copy(id = it.string("id")!!) }
            val state = input["state"]!!.jsonObject
            val panel = PanelState()
            panel.setTracks(all)
            // Hidden first: hiding goes through the toolbar's target, the checked group.
            state.strings("hidden").forEach { panel.toggleChecked(it) }
            panel.toggleTargetVisibility()
            panel.clearChecked()
            // Filters before checks: setting a filter unchecks what it hides.
            state.strings("excludedTypes").forEach(panel::toggleType)
            panel.setDistanceFilter(distance(state["distanceFilter"]))
            state.strings("checked").forEach { panel.toggleChecked(it) }
            state.string("focused")?.let(panel::focus)
            val event = input["event"]!!.jsonObject
            when (val type = event.string("type")) {
                "checkToggled" -> panel.toggleChecked(event.string("id")!!)
                "checkAll" -> panel.checkAll()
                "checksCleared" -> panel.clearChecked()
                "checksInverted" -> panel.invertChecked()
                "visibilityToggled" -> panel.toggleTargetVisibility()
                "typeToggled" -> panel.toggleType(event.string("trackType")!!)
                "distanceSet" -> panel.setDistanceFilter(distance(event["filter"]))
                "filtersReset" -> panel.resetFilters()
                "listLoaded" -> event.strings("ids").toSet().let { ids -> panel.setTracks(all.filter { it.id in ids }) }
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
        "areaLoad" to { input ->
            val total = (input["total"] as? JsonPrimitive)?.takeIf { it !is JsonNull }?.int
            val result = AreaLoad.of(input.number("zoom"), input.int("listed"), total)
            buildJsonObject {
                put("load", result.load.name.lowercase())
                put("capped", result.capped)
            }
        },
        "fitBoxes" to { input -> boxesJson(FitBoxes.of(framable(input))) },
        "selectionBoxes" to { input -> boxesJson(FitBoxes.selection(framable(input))) },
        "openingView" to { input ->
            val boxes = input["boxes"]!!.jsonArray.map { box -> box.jsonArray.map { it.jsonPrimitive.double } }
            val viewport = input["viewport"]!!.jsonObject
            OpeningView.of(boxes, viewport.number("width"), viewport.number("height"))?.let { view ->
                buildJsonObject {
                    put("center", buildJsonArray { add(JsonPrimitive(view.lon)); add(JsonPrimitive(view.lat)) })
                    put("zoom", view.zoom)
                }
            } ?: JsonNull
        },
        "dateFilterBounds" to { input ->
            val bounds = DateFilter.bounds(input.string("earliest"), input.string("latest"), input.string("today")!!)
            buildJsonObject {
                put("min", bounds.min)
                put("max", bounds.max)
            }
        },
        "dateFilterLabel" to { input ->
            when (val label = DateFilter(input.string("after"), input.string("before")).label) {
                DateFilter.Label.All -> buildJsonObject { put("kind", "all") }
                is DateFilter.Label.Between -> buildJsonObject {
                    put("kind", "between")
                    put("after", label.after)
                    put("before", label.before)
                }
                is DateFilter.Label.After -> buildJsonObject {
                    put("kind", "after")
                    put("after", label.after)
                }
                is DateFilter.Label.Before -> buildJsonObject {
                    put("kind", "before")
                    put("before", label.before)
                }
            }
        },
        "dateFilterSet" to { input ->
            val bounds = input["bounds"]!!.jsonObject
            val end = if (input.string("end") == "after") DateFilter.End.AFTER else DateFilter.End.BEFORE
            val change = dates(input["current"]!!.jsonObject).setting(end, input.string("value"), DateFilter.Bounds(bounds.string("min")!!, bounds.string("max")!!))
            buildJsonObject {
                put("filter", datesJson(change.filter))
                put("fly", change.fly)
            }
        },
        "webSession" to { input ->
            val state = input["state"]!!.jsonObject
            val panel = PanelState()
            val session = MapSession(panel)
            // The Trip first: opening one starts the selection set up below over.
            state.string("tripId")?.let { session.enterTrip(it); session.consumeFly() }
            (state["dates"] as? JsonObject)?.let { session.setDates(dates(it), fly = false) }
            (state["area"] as? JsonArray)?.let { area -> session.areaLoaded(area.map { it.jsonPrimitive.double }) }
            val ids = (state.strings("checked") + state.strings("hidden")).distinct()
            panel.setTracks(ids.map(::track))
            // Hidden first: hiding goes through the toolbar's target, the checked group.
            state.strings("hidden").forEach { panel.toggleChecked(it) }
            panel.toggleTargetVisibility()
            panel.clearChecked()
            state.strings("checked").forEach { panel.toggleChecked(it) }
            state.strings("excludedTypes").forEach(panel::toggleType)
            val event = input["event"]!!.jsonObject
            when (val type = event.string("type")) {
                "datesSet" -> session.setDates(dates(event["dates"]!!.jsonObject), event.bool("fly"))
                "areaLoaded" -> session.areaLoaded(event["area"]!!.jsonArray.map { it.jsonPrimitive.double })
                "dayViewed" -> session.viewDay(event.string("day")!!)
                "tripEntered" -> session.enterTrip(event.string("id")!!)
                "tripExited" -> session.exitTrip()
                else -> error("no Android event $type")
            }
            buildJsonObject {
                put("dates", datesJson(session.dates))
                put("area", session.area?.let { area -> buildJsonArray { area.forEach { add(JsonPrimitive(it)) } } } ?: JsonNull)
                session.tripId?.let { put("tripId", it) }
                put("checked", ids(panel.checked))
                put("hidden", ids(panel.hidden))
                put("excludedTypes", ids(panel.excludedTypes))
                put("flyRequest", session.flyRequest)
            }
        },
    )

    private fun dates(json: JsonObject) = DateFilter(json.string("after"), json.string("before"))

    private fun datesJson(filter: DateFilter) = buildJsonObject {
        put("after", filter.after?.let(::JsonPrimitive) ?: JsonNull)
        put("before", filter.before?.let(::JsonPrimitive) ?: JsonNull)
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

    private fun tracks(json: JsonElement?) = json!!.jsonArray.map { facetTrack(it.jsonObject) }

    private fun framable(input: JsonObject) = input["tracks"]!!.jsonArray.map { it.jsonObject }.map { json ->
        track("a").copy(
            bbox = (json["bbox"] as? JsonArray)?.map { it.jsonPrimitive.double },
            pending = json.bool("pending"),
            isPrivate = json.bool("private"),
        )
    }

    private fun boxesJson(boxes: List<List<Double>>) = buildJsonArray { boxes.forEach { box -> add(buildJsonArray { box.forEach { add(JsonPrimitive(it)) } }) } }

    private fun facetTrack(json: JsonObject) = track("a").copy(
        trackType = json.string("trackType")!!,
        distanceMeters = (json["distanceMeters"] as? JsonPrimitive)?.takeIf { it !is JsonNull }?.double,
        isPrivate = json["private"]?.jsonPrimitive?.booleanOrNull ?: false,
    )

    private fun photoRoute(input: JsonObject) = PhotoRoute(
        input["points"]!!.jsonArray.map { it.jsonObject }.map { TimedPoint(it.number("lon"), it.number("lat"), it["t"]!!.jsonPrimitive.long) },
    )

    private fun anchor(json: JsonElement?): PlaceAnchor? = (json as? JsonObject)?.let {
        it.string("waiting")?.let(PlaceAnchor::Waiting) ?: PlaceAnchor.At(it["t"]!!.jsonPrimitive.long)
    }

    private fun size(json: JsonElement?) = json!!.jsonObject.let { PhotoZoom.Size(it.number("width").toFloat(), it.number("height").toFloat()) }

    private fun sizeJson(size: PhotoZoom.Size) = buildJsonObject { put("width", size.width); put("height", size.height) }

    private fun view(input: JsonObject) = input["view"]!!.jsonObject.let { PhotoZoom.View(it.number("scale").toFloat(), it.number("x").toFloat(), it.number("y").toFloat()) }

    private fun viewJson(view: PhotoZoom.View) = buildJsonObject { put("scale", view.scale); put("x", view.x); put("y", view.y) }

    private fun points(json: JsonElement?): List<RoutePoint> = json!!.jsonArray.map { point ->
        val (lon, lat, t) = point.jsonArray.map { it.jsonPrimitive }
        RoutePoint(lon.double, lat.double, t.long)
    }

    private fun pointJson(point: RoutePoint) = buildJsonArray {
        add(JsonPrimitive(point.lon))
        add(JsonPrimitive(point.lat))
        add(JsonPrimitive(point.t))
    }

    private fun span(json: JsonElement): Pair<Long, Long> = json.jsonArray.let { it[0].jsonPrimitive.long to it[1].jsonPrimitive.long }

    private fun spanJson(span: Pair<Long, Long>) = buildJsonArray {
        add(JsonPrimitive(span.first))
        add(JsonPrimitive(span.second))
    }

    private fun edit(json: JsonElement?): RouteEdit? = (json as? JsonObject)?.let { edit ->
        RouteEdit(
            keep = (edit["keep"] as? JsonArray)?.let(::span),
            remove = (edit["remove"] as? JsonArray)?.map(::span).orEmpty(),
            drop = (edit["drop"] as? JsonArray)?.map { it.jsonPrimitive.long }.orEmpty(),
            move = (edit["move"] as? JsonObject)?.entries?.associate { (t, to) -> t.toLong() to (to.jsonArray[0].jsonPrimitive.double to to.jsonArray[1].jsonPrimitive.double) }.orEmpty(),
        )
    }

    /** The edit with its empty fields left out, as the web folds it. */
    private fun editJson(edit: RouteEdit) = buildJsonObject {
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

    private fun track(id: String) = Track(
        id = id, startedAt = "2026-10-01T08:00:00Z", trackType = "walking", name = null, distanceMeters = 1000.0,
        movingSeconds = 600, description = null, bbox = listOf(0.0, 0.0, 1.0, 1.0), pending = false, edited = false,
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
