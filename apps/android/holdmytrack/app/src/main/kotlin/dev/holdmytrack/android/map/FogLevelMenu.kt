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

    private val locked: String? get() = MapLayers.state.fogLevel

    /** The button's text while Fog is on: "Fog · City", a lock when one is locked, and the chevron
     *  saying it opens a menu; just "Fog" before the document has levels. */
    fun label(): CharSequence {
        val all = levels()
        val fog = res.getString(R.string.mode_fog)
        val z = zoom() ?: return fog
        if (all.isEmpty()) return fog
        val text = SpannableStringBuilder(fog).append(" · ").append(levelName(all, FogLevels.inView(all, z, locked)))
        if (locked != null) icon(text, R.drawable.ic_lock)
        icon(text, R.drawable.ic_chevron_down)
        return text
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

    private fun icon(text: SpannableStringBuilder, id: Int) {
        val drawable = ContextCompat.getDrawable(button.context, id)?.mutate() ?: return
        val size = (button.textSize * ICON_SCALE).toInt()
        drawable.setBounds(0, 0, size, size)
        drawable.setTint(button.currentTextColor)
        val start = text.length
        text.append("  ")
        text.setSpan(ImageSpan(drawable, ImageSpan.ALIGN_CENTER), start + 1, start + 2, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
    }

    private fun levelName(all: List<FogLevels.Level>, level: String): String =
        res.getString(levelLabel(level, all.firstOrNull { it.level == level }?.word))

    private fun show() {
        val inflater = LayoutInflater.from(button.context)
        val content = inflater.inflate(R.layout.popup_fog_level, null as ViewGroup?)
        val rows = content.findViewById<LinearLayout>(R.id.fog_level_rows)
        val all = levels()
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
        if (level == locked) return
        val next = FogLevels.pick(levels(), zoom() ?: return, locked, level)
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
         * else the generic name — the web's `levelLabelKey`.
         */
        fun levelLabel(level: String, word: String?): Int {
            if ((level == "region" || level == "county") && word != null) WORDS[word]?.let { return it }
            return when (level) {
                "country" -> R.string.fog_level_country
                "region" -> R.string.fog_level_region
                "county" -> R.string.fog_level_county
                "city" -> R.string.fog_level_city
                else -> R.string.fog_level_exact
            }
        }

        /** The words a level can be named with, as the web's `map.fog.type.*`. */
        private val WORDS: Map<String, Int> = mapOf(
        "allotments" to R.string.fog_type_allotments,
        "archipelago" to R.string.fog_type_archipelago,
        "area" to R.string.fog_type_area,
        "atoll" to R.string.fog_type_atoll,
        "canton" to R.string.fog_type_canton,
        "cercle" to R.string.fog_type_cercle,
        "city" to R.string.fog_type_city,
        "civil_parish" to R.string.fog_type_civil_parish,
        "commune" to R.string.fog_type_commune,
        "community" to R.string.fog_type_community,
        "constituency" to R.string.fog_type_constituency,
        "council" to R.string.fog_type_council,
        "country" to R.string.fog_type_country,
        "county" to R.string.fog_type_county,
        "department" to R.string.fog_type_department,
        "district" to R.string.fog_type_district,
        "division" to R.string.fog_type_division,
        "emirate" to R.string.fog_type_emirate,
        "entity" to R.string.fog_type_entity,
        "federal subject" to R.string.fog_type_federal_subject,
        "governorate" to R.string.fog_type_governorate,
        "hamlet" to R.string.fog_type_hamlet,
        "industrial" to R.string.fog_type_industrial,
        "island" to R.string.fog_type_island,
        "islet" to R.string.fog_type_islet,
        "isolated_dwelling" to R.string.fog_type_isolated_dwelling,
        "locality" to R.string.fog_type_locality,
        "municipal_federation" to R.string.fog_type_municipal_federation,
        "municipality" to R.string.fog_type_municipality,
        "parish" to R.string.fog_type_parish,
        "prefecture" to R.string.fog_type_prefecture,
        "province" to R.string.fog_type_province,
        "regency" to R.string.fog_type_regency,
        "region" to R.string.fog_type_region,
        "sector" to R.string.fog_type_sector,
        "state" to R.string.fog_type_state,
        "subcounty" to R.string.fog_type_subcounty,
        "subdistrict" to R.string.fog_type_subdistrict,
        "subprefecture" to R.string.fog_type_subprefecture,
        "subregion" to R.string.fog_type_subregion,
        "suburb" to R.string.fog_type_suburb,
        "territory" to R.string.fog_type_territory,
        "town" to R.string.fog_type_town,
        "township" to R.string.fog_type_township,
        "village" to R.string.fog_type_village,
        "zone" to R.string.fog_type_zone
        )
    }
}