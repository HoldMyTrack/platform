package dev.holdmytrack.android.panel

import android.annotation.SuppressLint
import android.view.LayoutInflater
import android.view.View
import android.view.ViewGroup
import android.widget.LinearLayout
import android.widget.PopupWindow
import android.widget.ScrollView
import android.widget.TextView
import com.google.android.material.checkbox.MaterialCheckBox
import com.google.android.material.slider.RangeSlider
import dev.holdmytrack.android.R
import kotlin.math.abs

/**
 * The Tracks tab's TYPE and DISTANCE filters and their Reset, the web's `TrackFilters`: each
 * opens a dropdown under its trigger, and every change goes to [state] and then [onChanged].
 */
class TrackFilters(
    sheet: View,
    private val state: PanelState,
    private val onChanged: () -> Unit,
) {
    private val context = sheet.context
    private val res = context.resources

    private val typeTrigger: View = sheet.findViewById(R.id.panel_type_trigger)
    private val typeDot: View = sheet.findViewById(R.id.panel_type_dot)
    private var typePopup: PopupWindow? = null

    private val distance: View = sheet.findViewById(R.id.panel_distance)
    private val distanceReadout: TextView = sheet.findViewById(R.id.panel_distance_readout)

    /** DISTANCE's popup, inflated once so its slider keeps its listener and its values. */
    @SuppressLint("InflateParams") // A popup's content has no parent to inflate against.
    private val distanceContent: View = LayoutInflater.from(context).inflate(R.layout.popup_distance, null)
    private val distanceSlider: RangeSlider = distanceContent.findViewById(R.id.panel_distance_slider)
    private val distanceMin: TextView = distanceContent.findViewById(R.id.panel_distance_min)
    private val distanceMax: TextView = distanceContent.findViewById(R.id.panel_distance_max)
    private var distancePopup: PopupWindow? = null

    private val resetFilters: View = sheet.findViewById(R.id.panel_reset_filters)

    init {
        typeTrigger.setOnClickListener { showTypeFilter() }
        distance.setOnClickListener { showDistanceFilter() }
        distanceSlider.addOnChangeListener { slider, _, fromUser ->
            if (!fromUser) return@addOnChangeListener
            val bounds = TrackFacets.distanceBounds(state.tracks) ?: return@addOnChangeListener
            // The slider holds Floats, which can't carry every distance exactly: a knob at an
            // end is snapped back onto that end's own track, or the band would leave it out.
            fun snap(value: Float): Double = when {
                abs(value - bounds.min) < SNAP_METERS -> bounds.min
                abs(value - bounds.max) < SNAP_METERS -> bounds.max
                else -> value.toDouble()
            }
            // The slider reports both knobs; the rule takes them one at a time, so both at the ends is no filter.
            val min = TrackFacets.nextDistanceFilter(bounds, state.distanceFilter ?: bounds, DistanceKnob.MIN, snap(slider.values[0]))
            state.setDistanceFilter(TrackFacets.nextDistanceFilter(bounds, min ?: bounds, DistanceKnob.MAX, snap(slider.values[1])))
            onChanged()
        }
        resetFilters.setOnClickListener {
            state.resetFilters()
            onChanged()
        }
    }

    /** The triggers as [state] has them, and an open TYPE dropdown's rows. */
    fun render() {
        typeDot.visibility = if (state.excludedTypes.isNotEmpty()) View.VISIBLE else View.GONE
        renderDistance()
        resetFilters.visibility = if (state.hasActiveFilters) View.VISIBLE else View.GONE
        typePopup?.let { renderTypeRows(it.contentView) }
    }

    fun dismiss() {
        typePopup?.dismiss()
        distancePopup?.dismiss()
    }

    /** DISTANCE, the web's `DistanceFilter`: gone while the list has no spread of distances. */
    private fun renderDistance() {
        val bounds = TrackFacets.distanceBounds(state.tracks)
        if (bounds == null || bounds.min >= bounds.max) {
            distance.visibility = View.GONE
            return
        }
        distance.visibility = View.VISIBLE
        val current = state.distanceFilter ?: bounds
        val lo = current.min.coerceIn(bounds.min, bounds.max).toFloat()
        val hi = current.max.coerceIn(bounds.min, bounds.max).toFloat()
        distanceSlider.valueFrom = bounds.min.toFloat()
        distanceSlider.valueTo = bounds.max.toFloat()
        if (distanceSlider.values != listOf(lo, hi)) distanceSlider.setValues(lo, hi)
        distanceReadout.text = if (state.distanceFilter == null) {
            res.getString(R.string.panel_any_distance_chip)
        } else {
            res.getString(
                R.string.panel_distance_range,
                PanelFormat.distanceValue(res, current.min),
                PanelFormat.distanceValue(res, current.max),
                PanelFormat.unit(res),
            )
        }
        distance.contentDescription = "${res.getString(R.string.panel_distance)}, ${distanceReadout.text}"
        distanceMin.text = PanelFormat.distance(res, bounds.min)
        distanceMax.text = PanelFormat.distance(res, bounds.max)
    }

    private fun showDistanceFilter() {
        if (distancePopup != null) return
        (distanceContent.parent as? ViewGroup)?.removeView(distanceContent)
        // A fixed width, as a popup's content has no parent to take one from.
        val width = (DISTANCE_POPUP_DP * res.displayMetrics.density).toInt()
        val popup = PopupWindow(distanceContent, width, ViewGroup.LayoutParams.WRAP_CONTENT, true)
        popup.elevation = res.getDimension(R.dimen.hmt_space_8)
        popup.setOnDismissListener { distancePopup = null }
        distancePopup = popup
        popup.showAsDropDown(distance, 0, res.getDimensionPixelSize(R.dimen.hmt_space_8))
    }

    /** The Type dropdown, anchored under its trigger, closed by a tap outside it. */
    @SuppressLint("InflateParams") // A popup's content has no parent to inflate against.
    private fun showTypeFilter() {
        if (typePopup != null) return
        val content = LayoutInflater.from(context).inflate(R.layout.popup_type_filter, null)
        content.findViewById<View>(R.id.type_filter_all).apply {
            findViewById<TextView>(R.id.type_filter_label).apply {
                setText(R.string.panel_all_types)
                setTypeface(typeface, android.graphics.Typeface.BOLD)
            }
            findViewById<TextView>(R.id.type_filter_count).visibility = View.GONE
            setOnClickListener {
                state.includeAllTypes()
                onChanged()
            }
        }
        renderTypeRows(content)
        val popup = PopupWindow(content, ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT, true)
        popup.elevation = res.getDimension(R.dimen.hmt_space_8)
        popup.setOnDismissListener { typePopup = null }
        typePopup = popup
        popup.showAsDropDown(typeTrigger, 0, res.getDimensionPixelSize(R.dimen.hmt_space_8))
    }

    private fun renderTypeRows(content: View) {
        val facets = TrackFacets.typeFacets(state.tracks, state.distanceFilter)
        content.findViewById<View>(R.id.type_filter_empty).visibility = if (facets.isEmpty()) View.VISIBLE else View.GONE
        content.findViewById<View>(R.id.type_filter_body).visibility = if (facets.isEmpty()) View.GONE else View.VISIBLE
        content.findViewById<View>(R.id.type_filter_all)
            .findViewById<MaterialCheckBox>(R.id.type_filter_check).isChecked = state.excludedTypes.isEmpty()
        val rows = content.findViewById<LinearLayout>(R.id.type_filter_rows)
        rows.removeAllViews()
        val inflater = LayoutInflater.from(context)
        for (facet in facets) {
            val row = inflater.inflate(R.layout.item_type_filter, rows, false)
            val label = TrackTypes.label(facet.type)
            val shown = facet.type !in state.excludedTypes
            row.findViewById<MaterialCheckBox>(R.id.type_filter_check).isChecked = shown
            row.findViewById<TextView>(R.id.type_filter_label).text = label
            row.findViewById<TextView>(R.id.type_filter_count).text = PanelFormat.count(res, facet.count)
            row.contentDescription = "$label, ${facet.count}"
            row.isSelected = shown
            row.setOnClickListener {
                state.toggleType(facet.type)
                onChanged()
            }
            rows.addView(row)
        }
        // About twelve rows, then the list scrolls (.track-filters__type-list's max-height).
        val scroll = content.findViewById<ScrollView>(R.id.type_filter_scroll)
        rows.measure(View.MeasureSpec.UNSPECIFIED, View.MeasureSpec.UNSPECIFIED)
        val max = (TracksPanel.TYPE_LIST_MAX_DP * res.displayMetrics.density).toInt()
        scroll.layoutParams = scroll.layoutParams.apply {
            height = if (rows.measuredHeight > max) max else ViewGroup.LayoutParams.WRAP_CONTENT
        }
    }

    private companion object {
        const val DISTANCE_POPUP_DP = 288
        const val SNAP_METERS = 1.0
    }
}
