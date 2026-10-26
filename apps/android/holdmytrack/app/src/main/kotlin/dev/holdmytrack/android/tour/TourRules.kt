package dev.holdmytrack.android.tour

import dev.holdmytrack.android.MainActivity
import dev.holdmytrack.android.map.MapMode
import dev.holdmytrack.android.panel.PanelTab

/** A first-time card: a feature's own explanation, shown once per phone. */
enum class TourCard { FOG, HEATMAP, STORIES }

/** What the tour has shown on this phone: [tour] once it was started or its offer answered. */
data class TourSeen(val tour: Boolean = false, val cards: Set<TourCard> = emptySet())

enum class TourStart { START, OFFER, NONE, WAIT }

/** The camera through the tour: the view before its first move, and the one it last moved to, null where the map took it somewhere unknown. */
data class TourCamera(val start: TourView? = null, val shown: TourView? = null)

/** What a step changes, or the end puts back: the mode and tab where they differ, else null, and the card the step counts as seen. */
data class TourChanges(val mode: MapMode?, val tab: MainActivity.Tab?, val card: TourCard?)

/** Something the user picked that may earn a card. */
sealed interface TourEvent {
    data class Mode(val mode: MapMode) : TourEvent
    data class Tab(val tab: PanelTab) : TourEvent
}

/**
 * The tour's shared decisions (`docs/SPEC.md` FR-4.18): when it starts by itself or is offered,
 * which card a pick earns, which step comes next, what a step changes and where the camera goes.
 * The web's `tourRules.ts`; both run `testdata/client-rules/tour-*.json`.
 */
object TourRules {
    /** [hasActivities] is null until the account's history is known. */
    fun start(requested: Boolean, isDemo: Boolean, hasActivities: Boolean?, seen: TourSeen): TourStart = when {
        hasActivities == null -> TourStart.WAIT
        requested -> TourStart.START
        seen.tour -> TourStart.NONE
        isDemo -> TourStart.START
        hasActivities -> TourStart.OFFER
        else -> TourStart.NONE
    }

    /** The card [event] earns, once, and never while the tour runs, whose steps say the same. */
    fun card(event: TourEvent, seen: TourSeen, touring: Boolean): TourCard? {
        if (touring) return null
        val card = when (event) {
            is TourEvent.Mode -> when (event.mode) {
                MapMode.FOG -> TourCard.FOG
                MapMode.HEATMAP -> TourCard.HEATMAP
                MapMode.NORMAL -> null
            }
            is TourEvent.Tab -> TourCard.STORIES.takeIf { event.tab == PanelTab.STORIES }
        }
        return card?.takeUnless { it in seen.cards }
    }

    /**
     * Where the camera goes for a step with [view] on [tab], [current] being the map's view now.
     * The first step with its own view or on Stories keeps [current] as the start, since the map's
     * own first flight may still be under way when the tour starts; Stories frames its Story
     * itself, so after it the camera is unknown. The second value is the move, null for none.
     */
    fun camera(camera: TourCamera, view: TourView?, tab: MainActivity.Tab, current: TourView): Pair<TourCamera, TourView?> {
        val stories = tab == MainActivity.Tab.STORIES
        var start = camera.start
        var shown = camera.shown
        if (start == null && (view != null || stories)) {
            start = current
            shown = current
        }
        if (view == null && stories) return TourCamera(start, null) to null
        val target = view ?: start
        if (target == null || shown?.sameSpot(target) == true) return TourCamera(start, shown) to null
        return TourCamera(start, target) to target
    }

    /** Where the camera goes when the tour ends: back to the start, unless it's there. */
    fun cameraEnd(camera: TourCamera): TourView? {
        val start = camera.start ?: return null
        return start.takeUnless { camera.shown?.sameSpot(it) == true }
    }

    /** What [step] changes from [mode] and [tab], or the end (null) puts back from [restoreMode] and [restoreTab]. */
    fun changes(mode: MapMode, tab: MainActivity.Tab, step: TourStep?, restoreMode: MapMode, restoreTab: MainActivity.Tab): TourChanges {
        val wantMode = step?.mode ?: restoreMode
        val wantTab = step?.tab ?: restoreTab
        return TourChanges(wantMode.takeIf { it != mode }, wantTab.takeIf { it != tab }, step?.card)
    }

    /** The step after [from] in direction [dir] that [shown] says is on screen, or null past either end. */
    fun nextStep(shown: List<Boolean>, from: Int, dir: Int): Int? {
        var i = from + dir
        while (i in shown.indices) {
            if (shown[i]) return i
            i += dir
        }
        return null
    }
}
