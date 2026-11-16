package dev.holdmytrack.android.map

import android.annotation.SuppressLint
import android.view.Gravity
import android.view.LayoutInflater
import android.view.View
import android.widget.CheckBox
import android.widget.TextView
import androidx.core.view.isVisible
import com.google.android.material.button.MaterialButton
import com.google.android.material.materialswitch.MaterialSwitch
import dev.holdmytrack.android.R

/**
 * The Layers button on the map's rail and the menu it opens — the web's `OverlaysMenu`
 * (`docs/SPEC.md` FR-4.9): Paths — Bike paths, Shared paths and Mountain bike trails — each
 * picked over any mode. Places have a menu of their own ([PlacesMenu]).
 *
 * The button is filled like the active map mode while picks show, with a badge on its corner
 * counting them, greyed while they're hidden. The menu opens with a switch that shows or hides
 * every pick at once and keeps them ([shown]) — picking an entry while it's off turns it back on,
 * or the pick would seem to do nothing; with nothing picked it can't be changed — and, where the
 * served style has imagery ([satellite] isn't null), Satellite (`MapSatellite`). Roads
 * (`MapRoads`) is a pick like the paths, on until unpicked. A tap on the
 * button toggles the menu, and a tap outside it or Back closes it, like the Activities panel's
 * Type dropdown.
 */
class LayersMenu(
    private val button: MaterialButton,
    private val count: TextView,
    private val paths: () -> MapPaths.Paths,
    private val shown: () -> Boolean,
    private val onPaths: (MapPaths.Paths) -> Unit,
    private val onShown: (Boolean) -> Unit,
    private val satellite: () -> Boolean?,
    private val onSatellite: (Boolean) -> Unit,
    /** Roads is picked ([MapRoads]). */
    private val roads: () -> Boolean,
    private val onRoads: (Boolean) -> Unit,
    /** The layers document's path legend, by entry (`bike-paths`), or empty before it's loaded. */
    private val legend: () -> Map<String, MapLayersDoc.Legend>,
) {
    private val res = button.resources
    private var master: MaterialSwitch? = null
    private val popup = MenuPopup(button.parent as View, Gravity.END, capHeld = true, build = ::build, onClosed = { master = null })

    init {
        button.setOnClickListener {
            // The button is checkable for the filled look, so a tap just flipped it; that follows
            // the paths, not taps.
            render()
            popup.open()
        }
        render()
    }

    /** The filled look, the badge and the open menu's switch, from the saved choice. */
    fun render() {
        val picked = (if (roads()) 1 else 0) + paths().count
        val look = RailLook.of(picked, shown())
        master?.let {
            it.isChecked = shown()
            it.isEnabled = look.switchEnabled
            it.tooltipText = if (look.switchEnabled) null else res.getString(R.string.layers_master_empty)
        }
        button.isChecked = look.filled
        count.isVisible = look.badge
        count.alpha = look.badgeAlpha
        count.text = picked.toString()
        val label = res.getString(R.string.layers_button)
        button.contentDescription = if (picked > 0) "$label, $picked" else label
    }

    /** A pick turns the checkbox back on before it's applied, so it shows. */
    private fun picked(on: Boolean) {
        if (on && !shown()) onShown(true)
    }

    fun dismiss() = popup.dismiss()

    /** The open menu's content, for the tour's spotlight. */
    val content: View? get() = popup.content

    /** Holds the menu open for the tour to point at (`tour/TourController`), or lets go of it ([MenuPopup.hold]). */
    fun hold(open: Boolean) = popup.hold(open)

    @SuppressLint("InflateParams") // A popup's content has no parent to inflate against.
    private fun build(): View {
        val content = LayoutInflater.from(button.context).inflate(R.layout.popup_layers, null)

        // A click, not a checked-change listener: render() sets the switch from the saved choice.
        master = content.findViewById<MaterialSwitch>(R.id.layers_master).apply {
            setOnClickListener {
                onShown(isChecked)
                render()
            }
        }
        content.findViewById<MaterialSwitch>(R.id.layers_satellite).apply {
            val on = satellite()
            isVisible = on != null
            isChecked = on == true
            setOnClickListener { onSatellite(isChecked) }
        }
        content.findViewById<CheckBox>(R.id.layers_roads).apply {
            isChecked = roads()
            setOnCheckedChangeListener { _, on ->
                picked(on)
                onRoads(on)
                render()
            }
        }

        val current = paths()
        fun bind(id: Int, checked: Boolean, next: (MapPaths.Paths, Boolean) -> MapPaths.Paths) {
            content.findViewById<CheckBox>(id).apply {
                isChecked = checked
                setOnCheckedChangeListener { _, on ->
                    picked(on)
                    onPaths(next(paths(), on))
                    render()
                }
            }
        }
        bind(R.id.layers_bike_paths, current.bikePaths) { p, on -> p.copy(bikePaths = on) }
        bind(R.id.layers_shared_paths, current.sharedPaths) { p, on -> p.copy(sharedPaths = on) }
        bind(R.id.layers_mtb_trails, current.mtbTrails) { p, on -> p.copy(mtbTrails = on) }

        // The legend: each bike entry's line at its end, and the trails and tracks the map always
        // draws, as the layers document draws them.
        val entries = legend()
        val density = res.displayMetrics.density
        fun TextView.swatch(key: String, atEnd: Boolean) {
            val entry = entries[key] ?: return
            val drawable = PathSwatch(entry.color, entry.dash, density)
            if (atEnd) setCompoundDrawablesRelativeWithIntrinsicBounds(null, null, drawable, null)
            else setCompoundDrawablesRelativeWithIntrinsicBounds(drawable, null, null, null)
        }
        content.findViewById<TextView>(R.id.layers_bike_paths).swatch("bikePaths", atEnd = true)
        content.findViewById<TextView>(R.id.layers_shared_paths).swatch("sharedPaths", atEnd = true)
        content.findViewById<TextView>(R.id.layers_mtb_trails).swatch("mtbTrails", atEnd = true)
        content.findViewById<TextView>(R.id.layers_key_trails).swatch("trails", atEnd = false)
        content.findViewById<TextView>(R.id.layers_key_tracks).swatch("tracks", atEnd = false)

        render()
        return content
    }
}
