package dev.holdmytrack.android.map

import android.os.SystemClock
import android.view.View
import android.view.ViewGroup
import android.widget.PopupWindow
import dev.holdmytrack.android.R

/**
 * A map menu's popup: the Layers, Places and Fog level menus. A tap on its button toggles it, a tap
 * outside or Back closes it, and the tour can hold it open view-only ([hold]): neither focusable nor
 * touchable, so the tour's own buttons under it keep working, and, with [capHeld], at most 40% of
 * the screen tall so it can't cover the tour's card. [build] makes the content on each opening, and
 * [canOpen] says whether there is anything to show; a hold asked for before there is waits for
 * [retry].
 */
class MenuPopup(
    private val anchor: View,
    private val gravity: Int,
    private val capHeld: Boolean,
    private val canOpen: () -> Boolean = { true },
    private val build: () -> View,
    private val onClosed: () -> Unit = {},
) {
    private val res = anchor.resources
    private var window: PopupWindow? = null
    private var held = false
    private var wantHeld = false
    private var closedAt = 0L

    val isOpen: Boolean get() = window != null

    /** The open menu's content, for the tour's spotlight. */
    val content: View? get() = window?.contentView

    /** Opens the menu for the user, unless a tap just closed it: a tap on its button while it's
     *  open closes it as a tap outside first, and reopening would leave the button unable to close it. */
    fun open() {
        if (window == null && SystemClock.uptimeMillis() - closedAt >= REOPEN_GUARD_MS && canOpen()) show(interactive = true)
    }

    fun toggle() = if (window != null) dismiss() else open()

    fun dismiss() {
        window?.dismiss()
    }

    /** Holds the menu open for the tour, or lets go of it ([MenuHold.next]). */
    fun hold(open: Boolean) {
        wantHeld = open
        apply()
    }

    /** Applies a hold that had nothing to show when asked, once there is. */
    fun retry() {
        if (wantHeld) apply()
    }

    private fun apply() {
        when (MenuHold.next(isOpen = window != null, held = held, want = wantHeld, canOpen = canOpen())) {
            MenuHold.Action.NONE -> Unit
            MenuHold.Action.CLOSE -> dismiss()
            MenuHold.Action.OPEN_HELD -> show(interactive = false)
            MenuHold.Action.REOPEN_HELD -> {
                dismiss()
                show(interactive = false)
            }
        }
    }

    private fun show(interactive: Boolean) {
        val content = build()
        val width = (MENU_WIDTH_DP * res.displayMetrics.density).toInt()
        val height = if (!interactive && capHeld) (res.displayMetrics.heightPixels * HELD_HEIGHT).toInt() else ViewGroup.LayoutParams.WRAP_CONTENT
        val popup = PopupWindow(content, width, height, interactive)
        popup.isTouchable = interactive
        popup.elevation = res.getDimension(R.dimen.hmt_space_8)
        held = !interactive
        popup.setOnDismissListener {
            window = null
            held = false
            closedAt = SystemClock.uptimeMillis()
            onClosed()
        }
        window = popup
        // Under the anchor, 6dp below it.
        popup.showAsDropDown(anchor, 0, res.getDimensionPixelSize(R.dimen.hmt_space_6), gravity)
    }

    private companion object {
        const val REOPEN_GUARD_MS = 300L

        /** A fixed width, the web panel's 14rem. */
        const val MENU_WIDTH_DP = 224

        /** The share of the screen's height a held menu takes. */
        const val HELD_HEIGHT = 0.4f
    }
}

/** What a tour's hold does to a menu's popup. */
object MenuHold {
    enum class Action { NONE, CLOSE, OPEN_HELD, REOPEN_HELD }

    /**
     * From whether the popup [isOpen] and is [held], what the tour [want]s and whether it [canOpen]:
     * a menu the user opened is taken over as held, so it lets go of touches and closes after the
     * step; letting go closes only a held one, never the user's own.
     */
    fun next(isOpen: Boolean, held: Boolean, want: Boolean, canOpen: Boolean): Action = when {
        !want -> if (isOpen && held) Action.CLOSE else Action.NONE
        isOpen && held -> Action.NONE
        !canOpen -> Action.NONE
        isOpen -> Action.REOPEN_HELD
        else -> Action.OPEN_HELD
    }
}

/** How a rail menu's button looks, from how many it has [picked] and whether its switch [shown] them. */
data class RailLook(val filled: Boolean, val badge: Boolean, val badgeAlpha: Float, val switchEnabled: Boolean) {
    companion object {
        /** The badge while the switch is off: the web's greyed count. */
        const val OFF_ALPHA = 0.55f

        fun of(picked: Int, shown: Boolean) = RailLook(
            filled = shown && picked > 0,
            badge = picked > 0,
            badgeAlpha = if (shown) 1f else OFF_ALPHA,
            switchEnabled = picked > 0,
        )
    }
}
