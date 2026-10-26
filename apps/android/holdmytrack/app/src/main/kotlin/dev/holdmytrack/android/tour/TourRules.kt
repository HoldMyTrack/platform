package dev.holdmytrack.android.tour

import dev.holdmytrack.android.map.MapMode
import dev.holdmytrack.android.panel.PanelTab

/** A first-time card: a feature's own explanation, shown once per phone. */
enum class TourCard { FOG, HEATMAP, STORIES }

/** What the tour has shown on this phone: [tour] once it was started or its offer answered. */
data class TourSeen(val tour: Boolean = false, val cards: Set<TourCard> = emptySet())

enum class TourStart { START, OFFER, NONE, WAIT }

/** Something the user picked that may earn a card. */
sealed interface TourEvent {
    data class Mode(val mode: MapMode) : TourEvent
    data class Tab(val tab: PanelTab) : TourEvent
}

/**
 * The tour's shared decisions (`docs/SPEC.md` FR-4.18): when it starts by itself or is offered,
 * which card a pick earns, and which step comes next. The web's `tourRules.ts`; both run
 * `testdata/client-rules/tour-*.json`.
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
