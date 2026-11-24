package dev.holdmytrack.android.panel

import android.annotation.SuppressLint
import android.content.Context
import android.view.LayoutInflater
import android.view.MenuItem
import android.view.View
import android.view.ViewGroup
import com.google.android.material.appbar.MaterialToolbar
import com.google.android.material.bottomsheet.BottomSheetBehavior
import com.google.android.material.bottomsheet.BottomSheetDialog
import dev.holdmytrack.android.R

/**
 * A sheet over the map whose changes apply at once (`sheet_map`), Dates' and Similar tracks': the
 * title and one action, Done or Close, that closes it, over [body]. Nothing dims what's behind it,
 * so the map or list it changes stays in view; a tap outside, Back or a swipe close it too.
 *
 * A `BottomSheetDialog`, not the in-layout `BottomSheetBehavior` the Tracks sheet uses: neither
 * sheet needs the map moved while it's open, and a dialog needs no placement, Back or bottom bar
 * rules in `MapFragment`. Not the `BottomSheetDialogFragment` around one, as [FormSheet] says.
 */
class MapSheet(context: Context, title: String, action: String, body: View) {
    private val dialog = BottomSheetDialog(context)

    init {
        @SuppressLint("InflateParams") // A dialog's content has no parent to inflate against.
        val content = LayoutInflater.from(context).inflate(R.layout.sheet_map, null)
        val toolbar: MaterialToolbar = content.findViewById(R.id.map_sheet_toolbar)
        toolbar.title = title
        toolbar.menu.add(action).setShowAsAction(MenuItem.SHOW_AS_ACTION_ALWAYS or MenuItem.SHOW_AS_ACTION_WITH_TEXT)
        toolbar.setOnMenuItemClickListener { dialog.dismiss(); true }
        content.findViewById<ViewGroup>(R.id.map_sheet_body).addView(body)
        dialog.setContentView(content)
        dialog.behavior.skipCollapsed = true
        dialog.behavior.state = BottomSheetBehavior.STATE_EXPANDED
        dialog.behavior.maxHeight = (context.resources.displayMetrics.heightPixels * MAX_HEIGHT_FRACTION).toInt()
        dialog.window?.setDimAmount(0f)
    }

    /** Closed by any means. */
    fun setOnDismiss(listener: () -> Unit) = dialog.setOnDismissListener { listener() }

    /** The sheet's top on screen, or null while it isn't showing. */
    fun topOnScreen(): Int? {
        if (!dialog.isShowing) return null
        val sheet = dialog.findViewById<View>(com.google.android.material.R.id.design_bottom_sheet) ?: return null
        return IntArray(2).also(sheet::getLocationOnScreen)[1]
    }

    fun show() = dialog.show()

    fun dismiss() = dialog.dismiss()

    private companion object {
        /** The map keeps at least the rest of the screen. */
        const val MAX_HEIGHT_FRACTION = 0.6f
    }
}