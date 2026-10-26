package dev.holdmytrack.android.tour

import dev.holdmytrack.android.MainActivity
import dev.holdmytrack.android.map.MapMode

/** What a step points at, found by `TourHost`; null centers nothing and puts the card at the bottom. */
enum class TourTarget { SHEET, RANGE, LAYERS, EXPORT, MODES, RECORD, YOU_TOUR }

/** A camera: [lon], [lat], [zoom], then a slow pan through each point of [pan], if any. */
data class TourView(val lon: Double, val lat: Double, val zoom: Double, val pan: List<Pair<Double, Double>> = emptyList()) {
    fun sameSpot(other: TourView) = lon == other.lon && lat == other.lat && zoom == other.zoom
}

/**
 * One step of the tour. [tab] is the bottom bar's tab for the step, [mode] the map's, [sheet]
 * whether the panel's sheet is open and [layers] whether the Layers menu is; the user's own come
 * back when the tour ends. [view] is the camera, null for the one before the tour's first move.
 * [card] is the first-time card the step stands in for, and [text] the string resources'
 * `<text>_title` and `<text>_body`.
 */
data class TourStep(
    val id: String,
    val target: TourTarget?,
    val tab: MainActivity.Tab = MainActivity.Tab.MAP,
    val mode: MapMode = MapMode.NORMAL,
    val sheet: Boolean = false,
    val layers: Boolean = false,
    val view: TourView? = null,
    val card: TourCard? = null,
    val text: String = "tour_$id",
)

/**
 * The Android tour's steps (`apps/android/docs/SPEC.md` FR-2.12): the web's (`apps/web/src/ui/tour/tourRules.ts`)
 * with the bottom bar's own, Record and Sync, and the You tab's Take a tour to end on.
 */
object TourSteps {
    /**
     * The demo's views over its fixed history (`services/server/internal/httpapi/demo_data`), the
     * web's `DEMO_VIEWS`: Cleveland, where Fog clears along the tracks (zoom 7 up); the eastern US,
     * where it clears states (3–6); and the world, where it clears countries (0–2). A phone shows
     * one country at a time there, so the camera pans from the US over Europe to Vietnam, each leg
     * east and under 180°.
     */
    val CITY = TourView(-81.72, 41.42, 9.0)
    val REGIONS = TourView(-82.0, 36.0, 3.6)
    val COUNTRIES = TourView(-80.0, 38.0, 1.5, pan = listOf(15.0 to 45.0, 106.0 to 25.0))
    val HEATMAP_CITY = TourView(-81.72, 41.42, 10.0)

    fun of(isDemo: Boolean): List<TourStep> {
        val fog = if (isDemo) {
            listOf(
                TourStep("fog", TourTarget.MODES, mode = MapMode.FOG, view = CITY, card = TourCard.FOG, text = "tour_fog_city"),
                TourStep("fog_regions", TourTarget.MODES, mode = MapMode.FOG, view = REGIONS),
                TourStep("fog_countries", TourTarget.MODES, mode = MapMode.FOG, view = COUNTRIES),
            )
        } else {
            listOf(TourStep("fog", TourTarget.MODES, mode = MapMode.FOG, card = TourCard.FOG))
        }
        return listOf(
            TourStep("welcome", null),
            TourStep("activities", TourTarget.SHEET, sheet = true),
            TourStep("range", TourTarget.RANGE),
            TourStep("stories", TourTarget.SHEET, tab = MainActivity.Tab.STORIES, sheet = true, card = TourCard.STORIES),
            TourStep("layers", TourTarget.LAYERS, layers = true),
            TourStep("export", TourTarget.EXPORT),
        ) + fog + listOf(
            TourStep("heatmap", TourTarget.MODES, mode = MapMode.HEATMAP, view = HEATMAP_CITY.takeIf { isDemo }, card = TourCard.HEATMAP),
            TourStep("record", TourTarget.RECORD),
            TourStep("sync", TourTarget.SHEET, tab = MainActivity.Tab.SYNC, sheet = true, text = if (isDemo) "tour_sync_demo" else "tour_sync"),
            TourStep("done", TourTarget.YOU_TOUR, tab = MainActivity.Tab.YOU),
        )
    }

    /** Whether a step moves the camera: its own view, or the Stories tab, whose Story the map frames. */
    fun movesCamera(step: TourStep) = step.view != null || step.tab == MainActivity.Tab.STORIES

    enum class Edge { TOP, BOTTOM }

    /**
     * Where the step's card goes: across the top, under [topInset], when it fits above the target
     * (`[targetTop]`), else across the bottom, over what's least needed. The web's phone sheet
     * (`placePopover`).
     */
    fun edge(targetTop: Int?, cardHeight: Int, topInset: Int, gap: Int): Edge =
        if (targetTop != null && targetTop - topInset >= cardHeight + gap) Edge.TOP else Edge.BOTTOM
}