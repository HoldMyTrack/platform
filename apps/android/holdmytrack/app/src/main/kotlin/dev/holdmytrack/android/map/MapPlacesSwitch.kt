package dev.holdmytrack.android.map

import android.content.Context
import androidx.core.content.edit

/**
 * Show places, the Places menu's switch (root `docs/SPEC.md` FR-4.9, [PlacesMenu]): whether the
 * picked place categories ([MapSpots]) are drawn at all. Off hides them and keeps the picks. A
 * per-device choice, kept beside Show layers ([MapLayersSwitch]).
 */
object MapPlacesSwitch {

    private const val PREFS = "map_layers"
    private const val KEY = "places_shown"

    /** Read before it was ever set, the value [initial] gives is saved at once, so from then on it
     *  no longer follows Show layers. */
    fun isOn(context: Context): Boolean {
        val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        val stored = if (prefs.contains(KEY)) prefs.getBoolean(KEY, true) else null
        val on = initial(stored, MapLayersSwitch.isOn(context))
        if (stored == null) set(context, on)
        return on
    }

    fun set(context: Context, on: Boolean) {
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit { putBoolean(KEY, on) }
    }

    /** The switch from what's [stored], or, before it was ever set, Show layers' [layersOn]: places
     *  had no switch of their own, and one turned off with the rest stays off. */
    fun initial(stored: Boolean?, layersOn: Boolean): Boolean = stored ?: layersOn
}
