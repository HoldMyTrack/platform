package dev.holdmytrack.android.panel

import android.widget.ImageButton
import android.widget.PopupMenu
import android.widget.Toast
import androidx.appcompat.widget.TooltipCompat
import dev.holdmytrack.android.R
import dev.holdmytrack.android.net.Track

/**
 * The Tracks toolbar's ⋯ ([TracksPanel]): Download (root `docs/SPEC.md` FR-17.2) and Delete, which
 * don't fit across a phone as buttons beside the others. A blocked one stays tappable and says
 * why, as a disabled menu item can't.
 */
internal class SelectionMoreMenu(
    private val anchor: ImageButton,
    /** Library's too, so a download under way in either blocks the other's. */
    private val download: TrackDownload,
    private val onDelete: () -> Unit,
) {
    private val res = anchor.resources

    private class Item(val text: String, val ready: Boolean)

    private var downloadItem = Item("", false)
    private var deleteItem = Item("", false)
    private var ids: List<String> = emptyList()
    private var open: PopupMenu? = null

    init {
        anchor.setOnClickListener { show() }
    }

    /**
     * The toolbar's [targets], named [targetName] (null with none), and Delete as the toolbar's
     * rules have it: its label or why it can't go.
     */
    fun update(targets: List<Track>, targetName: String?, noTarget: String, deleteText: String, deleteReady: Boolean) {
        ids = targets.map { it.id }
        val label = targetName?.let { res.getString(R.string.panel_more_target, it) } ?: noTarget
        anchor.isEnabled = targetName != null
        anchor.contentDescription = label
        TooltipCompat.setTooltipText(anchor, label)
        deleteItem = Item(deleteText, deleteReady)
        downloadItem = if (targetName == null) Item(noTarget, false) else downloadItem(targets, targetName)
    }

    private fun downloadItem(targets: List<Track>, targetName: String): Item {
        val block = DownloadRules.block(targets.map { DownloadRules.Target(it.id, it.pending, it.isPrivate) })
        fun label(id: String) = PanelFormat.rowLabel(res, targets.first { it.id == id })
        val text = when (block) {
            null -> res.getString(R.string.panel_download_target, targetName)
            is DownloadRules.Block.TooMany -> res.getQuantityString(R.plurals.panel_download_too_many, block.count, DownloadRules.MAX_TRACKS, block.count)
            is DownloadRules.Block.Pending -> res.getString(R.string.panel_download_pending, label(block.id))
            is DownloadRules.Block.Private -> res.getString(R.string.panel_download_private, label(block.id))
        }
        return Item(text, block == null)
    }

    private fun show() {
        val menu = PopupMenu(anchor.context, anchor)
        menu.menu.add(0, DOWNLOAD, 0, R.string.panel_more_download)
        menu.menu.add(0, DELETE, 1, R.string.panel_more_delete)
        menu.setOnMenuItemClickListener { item ->
            val chosen = if (item.itemId == DOWNLOAD) downloadItem else deleteItem
            when {
                !chosen.ready -> say(chosen.text)
                item.itemId == DELETE -> onDelete()
                download.busy -> say(res.getString(R.string.panel_download_busy))
                else -> download.start(ids)
            }
            true
        }
        menu.setOnDismissListener { open = null }
        open = menu
        menu.show()
    }

    fun dismiss() {
        open?.dismiss()
    }

    private fun say(text: String) = Toast.makeText(anchor.context, text, Toast.LENGTH_LONG).show()

    private companion object {
        const val DOWNLOAD = 1
        const val DELETE = 2
    }
}
