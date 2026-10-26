package dev.holdmytrack.android.tour

import android.content.Context
import androidx.core.content.edit

/**
 * What the tour has shown on this phone (`apps/android/docs/SPEC.md` FR-2.12): kept by the phone, not the
 * account, as the web keeps it by browser, since the demo is one account every visitor shares.
 */
class TourStore(context: Context) {
    private val prefs = context.applicationContext.getSharedPreferences(FILE, Context.MODE_PRIVATE)

    fun load(): TourSeen = TourSeen(
        tour = prefs.getBoolean(KEY_TOUR, false),
        cards = prefs.getStringSet(KEY_CARDS, emptySet()).orEmpty().mapNotNull { name -> TourCard.entries.firstOrNull { it.name == name } }.toSet(),
    )

    fun save(seen: TourSeen) = prefs.edit {
        putBoolean(KEY_TOUR, seen.tour)
        putStringSet(KEY_CARDS, seen.cards.map { it.name }.toSet())
    }

    private companion object {
        const val FILE = "tour"
        const val KEY_TOUR = "tour"
        const val KEY_CARDS = "cards"
    }
}