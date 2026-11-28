package dev.holdmytrack.android.panel

import dev.holdmytrack.android.trimWhiteSpace

/**
 * Whether a Trip sheet's action can be tapped ([TripSheet]'s Create trip or Save, [SendCopySheet]'s
 * Send), `testdata/client-rules/trip-form-action.json`: its field needs text besides whitespace,
 * and no request may be running.
 */
object TripForms {
    fun actionEnabled(text: String, busy: Boolean): Boolean = !busy && text.trimWhiteSpace().isNotEmpty()
}
