package dev.holdmytrack.android.map

import android.annotation.SuppressLint
import android.os.SystemClock
import android.view.Gravity
import android.view.LayoutInflater
import android.view.View
import android.view.ViewGroup
import android.widget.CheckBox
import android.widget.PopupWindow
import android.widget.TextView
import androidx.core.view.isVisible
import com.google.android.material.button.MaterialButton
import com.google.android.material.materialswitch.MaterialSwitch
import dev.holdmytrack.android.R

/**
 * The Places button on the map's rail and the menu it opens, the web's `PlacesMenu` (root
 * `docs/SPEC.md` FR-14.2): one entry per [MapSpots.Category], each picked over any mode, under a
 * switch that shows or hides them all at once and keeps the picks ([shown]). Picking one while
 * it's off turns it back on, or the pick would seem to do nothing. The button, badge and
 * open/close rules are [LayersMenu]'s.
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
    private var popup: PopupWindow? = null
    private var master: MaterialSwitch? = null
    private var closedAt = 0L
    private var held = false

    init {
        button.setOnClickListener {
            render()
            if (SystemClock.uptimeMillis() - closedAt < REOPEN_GUARD_MS) return@setOnClickListener
            show()
        }
        render()
    }

    /** The filled look, the badge and the open menu's switch, from the saved choice. */
    fun render() {
        val picked = spots().size
        val on = shown()
        master?.let {
            it.isChecked = on
            it.isEnabled = picked > 0
            it.tooltipText = if (picked > 0) null else res.getString(R.string.places_master_empty)
        }
        button.isChecked = on && picked > 0
        count.isVisible = picked > 0
        count.alpha = if (on) 1f else OFF_ALPHA
        count.text = picked.toString()
        val label = res.getString(R.string.places_button)
        button.contentDescription = if (picked > 0) "$label, $picked" else label
    }

    fun dismiss() {
        popup?.dismiss()
    }

    /** The open menu's content, for the tour's spotlight. */
    val content: View? get() = popup?.contentView

    /** Holds the menu open, view-only, for the tour to point at, or closes it ([LayersMenu.hold]). */
    fun hold(open: Boolean) {
        if (!open) {
            if (held) dismiss()
            return
        }
        if (popup == null) show(interactive = false)
    }

    @SuppressLint("InflateParams") // A popup's content has no parent to inflate against.
    private fun show(interactive: Boolean = true) {
        if (popup != null) return
        val content = LayoutInflater.from(button.context).inflate(R.layout.popup_places, null)
        master = content.findViewById<MaterialSwitch>(R.id.places_master).apply {
            setOnClickListener {
                onShown(isChecked)
                render()
            }
        }
        for ((category, id) in SPOT_BOXES) {
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
        val width = (MENU_WIDTH_DP * res.displayMetrics.density).toInt()
        // Held for the tour, it's capped so the tour's card below it stays in view; it scrolls.
        val height = if (interactive) ViewGroup.LayoutParams.WRAP_CONTENT else (res.displayMetrics.heightPixels * HELD_HEIGHT).toInt()
        val window = PopupWindow(content, width, height, interactive)
        window.isTouchable = interactive
        window.elevation = res.getDimension(R.dimen.hmt_space_8)
        held = !interactive
        window.setOnDismissListener {
            popup = null
            master = null
            held = false
            closedAt = SystemClock.uptimeMillis()
        }
        popup = window
        render()
        window.showAsDropDown(button.parent as View, 0, res.getDimensionPixelSize(R.dimen.hmt_space_6), Gravity.END)
    }

    private companion object {
        val SPOT_BOXES = listOf(
            MapSpots.Category.PLAYGROUND to R.id.layers_spots_playground,
            MapSpots.Category.DOG_PARK to R.id.layers_spots_dog_park,
            MapSpots.Category.MONUMENT to R.id.layers_spots_monument,
            MapSpots.Category.VIEWPOINT to R.id.layers_spots_viewpoint,
            MapSpots.Category.WATERFALL to R.id.layers_spots_waterfall,
            MapSpots.Category.HISTORY to R.id.layers_spots_history,
        )

        const val REOPEN_GUARD_MS = 300L
        const val MENU_WIDTH_DP = 224
        const val OFF_ALPHA = 0.55f

        /** The share of the screen's height the tour's held menu takes, as [LayersMenu]'s. */
        const val HELD_HEIGHT = 0.4f
    }
}
