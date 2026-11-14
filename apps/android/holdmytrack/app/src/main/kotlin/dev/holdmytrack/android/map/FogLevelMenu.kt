package dev.holdmytrack.android.map

import android.os.SystemClock
import android.text.SpannableStringBuilder
import android.text.Spanned
import android.text.style.ImageSpan
import android.view.Gravity
import android.view.LayoutInflater
import android.view.View
import android.view.ViewGroup
import android.widget.LinearLayout
import android.widget.PopupWindow
import android.widget.RadioButton
import android.widget.TextView
import androidx.core.content.ContextCompat
import com.google.android.material.button.MaterialButton
import dev.holdmytrack.android.R
import dev.holdmytrack.android.net.Explored
import dev.holdmytrack.android.net.HoldMyTrackApi
import java.text.NumberFormat

/**
 * Fog's level control on the Fog button, the web's `ui/FogLevelMenu.tsx` (`docs/SPEC.md` FR-4.2):
 * while Fog is on, the button names the level in view, changing as the zoom does, with a lock when
 * one is locked, and a tap on it opens a menu of Auto, which follows the zoom, and every level with
 * how many of its places the account has explored. Picking a level locks it at every zoom, zooming
 * out to its band when zoomed in past it ([FogLevels.pick]), until Auto is picked. The lock is
 * [MapLayers.State.fogLevel], so it outlasts a style swap and a trip out of Fog; a new process
 * releases it. Open and close as the Layers menu ([LayersMenu]).
 */
class FogLevelMenu(
    private val button: MaterialButton,
    /** Fog's levels in the layers document applied, empty before it is. */
    private val levels: () -> List<FogLevels.Level>,
    /** The camera's zoom, or null before the map is ready. */
    private val zoom: () -> Double?,
    /** The level locked, or null to follow the zoom, and the zoom to ease out to, or null to stay. */
    private val onLock: (locked: String?, zoomTo: Double?) -> Unit,
) {
    private val res = button.resources
    private var popup: PopupWindow? = null
    private var closedAt = 0L

    /** The lock, when the document applied has its level: a lock on one it lacks follows the
     *  zoom, as [FogLevels.inView] and [FogLevels.zoomRanges] treat it. */
    private fun locked(all: List<FogLevels.Level>): String? = MapLayers.state.fogLevel?.takeIf { l -> all.any { it.level == l } }

    /** The button's text and what TalkBack reads for it. */
    data class Label(val text: CharSequence, val description: String)

    private var last: Pair<String, Label>? = null

    /** The button's label while Fog is on: "Fog · City", a lock when one holds, and the chevron
     *  saying it opens a menu; just "Fog" before the document has levels. Built again only when the
     *  level or the lock changes: it's asked on every frame of a pinch. */
    fun label(): Label {
        val all = levels()
        val fog = res.getString(R.string.mode_fog)
        val z = zoom()
        if (z == null || all.isEmpty()) return Label(fog, fog)
        val lock = locked(all)
        val name = levelName(all, FogLevels.inView(all, z, lock))
        val key = "$name|${lock != null}|${ink()}"
        last?.takeIf { it.first == key }?.let { return it.second }
        val text = SpannableStringBuilder(fog).append(" · ").append(name)
        if (lock != null) icon(text, R.drawable.ic_lock)
        icon(text, R.drawable.ic_chevron_down)
        val description = "$fog · $name" + if (lock != null) ", " + res.getString(R.string.fog_level_locked) else ""
        return Label(text, description).also { last = key to it }
    }

    /** Opens the menu, or does nothing when a tap just closed it (the tap outside landed on the button). */
    fun toggle() {
        if (popup != null) return dismiss()
        if (SystemClock.uptimeMillis() - closedAt < REOPEN_GUARD_MS) return
        if (levels().isNotEmpty()) show()
    }

    fun dismiss() {
        popup?.dismiss()
    }

    /** The checked button's text color: the label shows only while Fog is on, and is built before
     *  the button's state may have caught up. */
    private fun ink(): Int = button.textColors.getColorForState(intArrayOf(android.R.attr.state_checked, android.R.attr.state_enabled), button.currentTextColor)

    private fun icon(text: SpannableStringBuilder, id: Int) {
        val drawable = ContextCompat.getDrawable(button.context, id)?.mutate() ?: return
        val size = (button.textSize * ICON_SCALE).toInt()
        drawable.setBounds(0, 0, size, size)
        drawable.setTint(ink())
        val start = text.length
        text.append("  ")
        text.setSpan(ImageSpan(drawable, ImageSpan.ALIGN_CENTER), start + 1, start + 2, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
    }

    /** A level this build has no name for, one the server added since, shows as its id. */
    private fun levelName(all: List<FogLevels.Level>, level: String): String =
        levelLabel(level, all.firstOrNull { it.level == level }?.word)?.let(res::getString) ?: level

    private fun show() {
        val inflater = LayoutInflater.from(button.context)
        val content = inflater.inflate(R.layout.popup_fog_level, null as ViewGroup?)
        val rows = content.findViewById<LinearLayout>(R.id.fog_level_rows)
        val all = levels()
        val locked = locked(all)
        val counts = mutableMapOf<String, TextView>()

        fun row(name: CharSequence, checked: Boolean, onPick: () -> Unit): View {
            val view = inflater.inflate(R.layout.item_fog_level, rows, false)
            view.findViewById<RadioButton>(R.id.fog_level_radio).apply {
                text = name
                isChecked = checked
                setOnClickListener { onPick() }
            }
            rows.addView(view)
            return view
        }

        val auto = SpannableStringBuilder(res.getString(R.string.fog_level_auto))
            .append("  ").append(res.getString(R.string.fog_level_auto_hint))
        auto.setSpan(
            android.text.style.ForegroundColorSpan(ContextCompat.getColor(button.context, R.color.hmt_ink_muted)),
            auto.length - res.getString(R.string.fog_level_auto_hint).length, auto.length, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE,
        )
        row(auto, locked == null) { pick(null) }
        for (level in all) {
            val view = row(levelName(all, level.level), locked == level.level) { pick(level.level) }
            counts[level.level] = view.findViewById(R.id.fog_level_count)
        }

        // The counts change only with the account's tiles: read once per opening.
        HoldMyTrackApi.coverageStatus { result ->
            val explored: Explored = result.getOrNull()?.explored ?: return@coverageStatus
            val format = NumberFormat.getIntegerInstance()
            counts.forEach { (level, view) ->
                val n = FogLevels.exploredCount(explored, level) ?: return@forEach
                view.text = format.format(n)
                view.visibility = View.VISIBLE
            }
        }

        val width = (MENU_WIDTH_DP * res.displayMetrics.density).toInt()
        val window = PopupWindow(content, width, ViewGroup.LayoutParams.WRAP_CONTENT, true)
        window.elevation = res.getDimension(R.dimen.hmt_space_8)
        window.setOnDismissListener {
            popup = null
            closedAt = SystemClock.uptimeMillis()
        }
        popup = window
        // Under the mode bar, lined up with its start edge, 6dp below it.
        window.showAsDropDown(button.parent as View, 0, res.getDimensionPixelSize(R.dimen.hmt_space_6), Gravity.START)
    }

    private fun pick(level: String?) {
        dismiss()
        if (level == null) return onLock(null, null)
        val all = levels()
        val locked = locked(all)
        if (level == locked) return
        val next = FogLevels.pick(all, zoom() ?: return, locked, level)
        onLock(next.locked, next.zoom)
    }

    companion object {
        private const val REOPEN_GUARD_MS = 300L
        /** The web's panel width, as the Layers menu's. */
        private const val MENU_WIDTH_DP = 224
        /** The lock and chevron, a little under the label's text height. */
        private const val ICON_SCALE = 1.05f

        /**
         * The string naming [level] in the control: what the account's country calls its places
         * ([word], Overture's local_type) where there's a word for it, for regions and counties,
         * else the generic name — the web's `levelLabelKey`; null for a level this build doesn't know.
         */
        fun levelLabel(level: String, word: String?): Int? {
            if ((level == "region" || level == "county") && word != null) FogWords.type(word)?.let { return it }
            return when (level) {
                "country" -> R.string.fog_level_country
                "region" -> R.string.fog_level_region
                "county" -> R.string.fog_level_county
                "city" -> R.string.fog_level_city
                FogLevels.EXACT -> R.string.fog_level_exact
                else -> null
            }
        }
    }
}