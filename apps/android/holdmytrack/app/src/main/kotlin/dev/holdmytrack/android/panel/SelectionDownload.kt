package dev.holdmytrack.android.panel

import android.widget.ImageButton
import android.widget.Toast
import androidx.appcompat.widget.TooltipCompat
import dev.holdmytrack.android.R
import dev.holdmytrack.android.net.Track

/**
 * The selection bar's Download ([TracksPanel], root `docs/SPEC.md` FR-5.14): the checked tracks as
 * GPX, or a zip of them. Disabled, saying why in its tooltip, for a target the server would refuse.
 */
internal class SelectionDownload(
    private val button: ImageButton,
    /** Library's too, so a download under way in either holds the other's back. */
    private val download: TrackDownload,
) {
    private val res = button.resources
    private var ids: List<String> = emptyList()

    init {
        button.setOnClickListener {
            if (download.busy) Toast.makeText(button.context, R.string.panel_download_busy, Toast.LENGTH_LONG).show() else download.start(ids)
        }
    }

    /** The toolbar's [targets], named [targetName], or none ([noTarget]). */
    fun update(targets: List<Track>, targetName: String?, noTarget: String) {
        ids = targets.map { it.id }
        if (targetName == null) {
            describe(noTarget, false)
            return
        }
        val block = DownloadRules.block(targets.map { DownloadRules.Target(it.id, it.pending, it.isPrivate) })
        fun label(id: String) = PanelFormat.rowLabel(res, targets.first { it.id == id })
        val text = when (block) {
            null -> res.getString(R.string.panel_download_target, targetName)
            is DownloadRules.Block.TooMany -> res.getQuantityString(R.plurals.panel_download_too_many, block.count, DownloadRules.MAX_TRACKS, block.count)
            is DownloadRules.Block.Pending -> res.getString(R.string.panel_download_pending, label(block.id))
            is DownloadRules.Block.Private -> res.getString(R.string.panel_download_private, label(block.id))
        }
        describe(text, block == null)
    }

    private fun describe(text: String, enabled: Boolean) {
        button.isEnabled = enabled
        button.contentDescription = text
        TooltipCompat.setTooltipText(button, text)
    }
}
