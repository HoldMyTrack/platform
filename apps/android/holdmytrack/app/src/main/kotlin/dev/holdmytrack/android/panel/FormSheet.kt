package dev.holdmytrack.android.panel

import android.annotation.SuppressLint
import android.content.Context
import android.view.LayoutInflater
import android.view.MenuItem
import android.view.View
import android.view.ViewGroup
import android.view.WindowManager
import com.google.android.material.appbar.MaterialToolbar
import com.google.android.material.bottomsheet.BottomSheetBehavior
import com.google.android.material.bottomsheet.BottomSheetDialog
import dev.holdmytrack.android.R

/**
 * A form the user types in as a bottom sheet (`sheet_form`), Trip and Send a copy's: ✕ to cancel,
 * the title, and the form's one action in a `MaterialToolbar` over [body]. It opens expanded,
 * above the keyboard, and only ✕, Back or a swipe close it, so a stray tap on the map can't drop
 * what was typed; [setBusy] holds it open while its request runs.
 *
 * A `BottomSheetDialog`, not the `BottomSheetDialogFragment` around one: the callers hand it
 * callbacks into the screen that opened it, which a fragment recreated after rotation wouldn't
 * have, and the dialogs it replaces didn't outlive a rotation either.
 */
class FormSheet(context: Context, title: String, body: View, onAction: () -> Unit) {
    private val dialog = BottomSheetDialog(context)
    private val toolbar: MaterialToolbar
    private val action: MenuItem
    private var busy = false

    init {
        @SuppressLint("InflateParams") // A dialog's content has no parent to inflate against.
        val content = LayoutInflater.from(context).inflate(R.layout.sheet_form, null)
        toolbar = content.findViewById(R.id.form_sheet_toolbar)
        toolbar.title = title
        toolbar.setNavigationOnClickListener { if (!busy) dialog.cancel() }
        action = toolbar.menu.add(title)
        action.setShowAsAction(MenuItem.SHOW_AS_ACTION_IF_ROOM or MenuItem.SHOW_AS_ACTION_WITH_TEXT)
        toolbar.setOnMenuItemClickListener { onAction(); true }
        content.findViewById<ViewGroup>(R.id.form_sheet_body).addView(body)
        dialog.setContentView(content)
        dialog.setCanceledOnTouchOutside(false)
        dialog.behavior.skipCollapsed = true
        dialog.behavior.state = BottomSheetBehavior.STATE_EXPANDED
        @Suppress("DEPRECATION") // The keyboard lifts the sheet; edge-to-edge insets alone leave it under.
        dialog.window?.setSoftInputMode(WindowManager.LayoutParams.SOFT_INPUT_ADJUST_RESIZE)
    }

    /** The action's words and whether it can be tapped. */
    fun setAction(label: String, enabled: Boolean) {
        action.title = label
        action.isEnabled = enabled
    }

    /** ✕'s spoken label: Cancel, or Close once nothing is left to lose. */
    fun setDismissLabel(label: String) {
        toolbar.navigationContentDescription = label
    }

    /** While a request runs nothing closes the sheet. */
    fun setBusy(busy: Boolean) {
        this.busy = busy
        dialog.setCancelable(!busy)
        dialog.behavior.isDraggable = !busy
        toolbar.navigationIcon?.alpha = if (busy) DISABLED_ALPHA else ENABLED_ALPHA
    }

    fun show() = dialog.show()

    fun dismiss() = dialog.dismiss()

    private companion object {
        const val ENABLED_ALPHA = 255
        const val DISABLED_ALPHA = 97
    }
}
