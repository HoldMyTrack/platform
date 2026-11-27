package dev.holdmytrack.android.panel

import android.annotation.SuppressLint
import android.content.Context
import android.content.res.ColorStateList
import android.view.LayoutInflater
import android.view.View
import android.view.ViewGroup
import android.widget.LinearLayout
import android.widget.TextView
import androidx.core.graphics.toColorInt
import com.google.android.material.bottomsheet.BottomSheetDialog
import dev.holdmytrack.android.R
import dev.holdmytrack.android.net.FailureText
import dev.holdmytrack.android.net.HoldMyTrackApi
import dev.holdmytrack.android.net.TrackInfo

/**
 * The toolbar's Info (root `docs/SPEC.md` FR-5.8) as a bottom sheet: the server's lines for the
 * toolbar's target (`POST /v2/tracks/info`), the pace bands' legend in [bandColors] while the map
 * draws them, and the server's note under them.
 */
class TrackInfoSheet(private val context: Context, trackIds: List<String>, private val bandColors: List<String>?) {
    private val res = context.resources
    private val dialog = BottomSheetDialog(context)

    @SuppressLint("InflateParams") // A dialog's content has no parent to inflate against.
    private val content: View = LayoutInflater.from(context).inflate(R.layout.sheet_track_info, null)
    private val status: TextView = content.findViewById(R.id.info_status)
    private val lines: LinearLayout = content.findViewById(R.id.info_lines)
    private val note: TextView = content.findViewById(R.id.info_note)

    init {
        dialog.setContentView(content)
        HoldMyTrackApi.trackInfo(trackIds) { result ->
            if (!dialog.isShowing) return@trackInfo
            result.onSuccess(::show).onFailure { failure ->
                val why = FailureText.of(failure, res.getString(R.string.something_went_wrong), res.getString(R.string.network_error))
                status.text = res.getString(R.string.info_failed, why)
                status.setTextColor(context.getColor(R.color.hmt_danger))
            }
        }
    }

    fun show() = dialog.show()

    fun dismiss() = dialog.dismiss()

    private fun show(info: TrackInfo) {
        status.visibility = View.GONE
        val inflater = LayoutInflater.from(context)
        for (line in info.lines) {
            val row = inflater.inflate(R.layout.item_info_line, lines, false)
            row.findViewById<TextView>(R.id.info_label).text = line.label
            row.findViewById<TextView>(R.id.info_value).text = line.value
            lines.addView(row)
        }
        note.text = info.note
        note.visibility = if (info.note.isEmpty()) View.GONE else View.VISIBLE
        bandColors?.let(::showBands)
    }

    private fun showBands(colors: List<String>) {
        content.findViewById<View>(R.id.info_bands).visibility = View.VISIBLE
        val steps: LinearLayout = content.findViewById(R.id.info_band_steps)
        val gap = res.getDimensionPixelSize(R.dimen.hmt_space_2)
        colors.forEachIndexed { i, color ->
            steps.addView(View(context).apply {
                setBackgroundResource(R.drawable.bg_pace_band)
                backgroundTintList = ColorStateList.valueOf(color.toColorInt())
            }, LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.MATCH_PARENT, 1f).apply {
                if (i > 0) marginStart = gap
            })
        }
    }
}
