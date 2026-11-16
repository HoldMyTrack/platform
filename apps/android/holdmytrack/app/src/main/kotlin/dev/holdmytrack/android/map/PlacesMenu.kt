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
 * The Places button on the map's rail and the menu it opens, the web's `PlacesMenu` (root
 * `docs/SPEC.md` FR-14.2): one entry per [MapSpots.Category], each picked over any mode, under a
 * switch that shows or hides them all at once and keeps the picks ([shown]). Picking one while
 * it's off turns it back on, or the pick would seem to do nothing. The button, badge and popup
 * work as [LayersMenu]'s.
 */
class PlacesMenu(
    private val button: MaterialButton,
    private val count: TextView,
    private val spots: () -> List<MapSpots.Category>,
    private val shown: () -> Boolean,
    private val onSpots: (List<MapSpots.Category>) -> Unit,
    private val onShown: (Boolean) -> Unit,
) {
    private val res = button.resources
    private var master: MaterialSwitch? = null
    private val popup = MenuPopup(button.parent as View, Gravity.END, capHeld = true, build = ::build, onClosed = { master = null })

    init {
        button.setOnClickListener {
            render()
            popup.open()
        }
        render()
    }

    /** The filled look, the badge and the open menu's switch, from the saved choice. */
    fun render() {
        val picked = spots().size
        val look = RailLook.of(picked, shown())
        master?.let {
            it.isChecked = shown()
            it.isEnabled = look.switchEnabled
            it.tooltipText = if (look.switchEnabled) null else res.getString(R.string.places_master_empty)
        }
        button.isChecked = look.filled
        count.isVisible = look.badge
        count.alpha = look.badgeAlpha
        count.text = picked.toString()
        val label = res.getString(R.string.places_button)
        button.contentDescription = if (picked > 0) "$label, $picked" else label
    }

    fun dismiss() = popup.dismiss()

    /** The open menu's content, for the tour's spotlight. */
    val content: View? get() = popup.content

    /** Holds the menu open for the tour, or lets go of it ([MenuPopup.hold]). */
    fun hold(open: Boolean) = popup.hold(open)

    @SuppressLint("InflateParams") // A popup's content has no parent to inflate against.
    private fun build(): View {
        val content = LayoutInflater.from(button.context).inflate(R.layout.popup_places, null)
        master = content.findViewById<MaterialSwitch>(R.id.places_master).apply {
            setOnClickListener {
                onShown(isChecked)
                render()
            }
        }
        for ((category, id) in BOXES) {
            content.findViewById<CheckBox>(id).apply {
                isChecked = category in spots()
                setOnCheckedChangeListener { _, on ->
                    if (on && !shown()) onShown(true)
                    val before = spots()
                    onSpots(MapSpots.Category.entries.filter { if (it == category) on else it in before })
                    render()
                }
            }
        }
        render()
        return content
    }

    private companion object {
        val BOXES = listOf(
            MapSpots.Category.PLAYGROUND to R.id.places_playground,
            MapSpots.Category.DOG_PARK to R.id.places_dog_park,
            MapSpots.Category.MONUMENT to R.id.places_monument,
            MapSpots.Category.VIEWPOINT to R.id.places_viewpoint,
            MapSpots.Category.WATERFALL to R.id.places_waterfall,
            MapSpots.Category.HISTORY to R.id.places_history,
        )
    }
}
