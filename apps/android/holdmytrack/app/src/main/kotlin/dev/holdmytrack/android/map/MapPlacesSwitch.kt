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

    fun isOn(context: Context): Boolean {
        val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        return initial(if (prefs.contains(KEY)) prefs.getBoolean(KEY, true) else null, MapLayersSwitch.isOn(context))
    }

    fun set(context: Context, on: Boolean) {
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit { putBoolean(KEY, on) }
    }

    /** The switch from what's [stored], or, before it was ever set, Show layers' [layersOn]: places
     *  had no switch of their own, and one turned off with the rest stays off. */
    fun initial(stored: Boolean?, layersOn: Boolean): Boolean = stored ?: layersOn
}
