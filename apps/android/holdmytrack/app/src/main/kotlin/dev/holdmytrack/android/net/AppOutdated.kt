package dev.holdmytrack.android.net

import android.annotation.SuppressLint
import android.app.Activity
import android.content.Context
import android.content.Intent
import android.os.Handler
import android.os.Looper
import dev.holdmytrack.android.UpdateAppActivity

/**
 * The server's refusal of a build older than its minimum: `426 app_outdated` on any `/v2/`
 * request (root `docs/IMPLEMENTATION.md` §4.33). Seen once, in [HoldMyTrackApi]'s client, for
 * every call the app makes, so no screen has to recognise it; the Update screen covers whatever
 * was showing. A callback caller hears nothing back (`HoldMyTrackApi.refusedBuild`); a suspending
 * one gets its exception. Either way anything waiting to sync stays on the phone.
 *
 * A refusal met while no screen is in front waits for the next screen to come to the front
 * ([OutdatedScreen]): Android drops an activity started from the background, and the screen
 * would otherwise never open for the rest of the process.
 *
 * It holds the application's own context, which lives as long as the process: nothing to leak.
 */
@SuppressLint("StaticFieldLeak")
object AppOutdated {

    private val main = Handler(Looper.getMainLooper())
    private lateinit var app: Context

    /** Read and written on the main thread only. */
    private var screen = OutdatedScreen()
    private var inFront = 0

    fun init(context: Context) {
        app = context.applicationContext
    }

    /**
     * Opens the Update screen over the app's screens, unless it's already up or no screen is in
     * front. Over them, not in place of them: this runs before the refused call's own callback,
     * and clearing the task here would hand that callback a screen already destroyed.
     */
    fun refused() {
        main.post { act(screen.refusedWhile(inFront > 0)) }
    }

    /** From the application's activity callbacks: [activity] came to the front. */
    fun resumed(activity: Activity) {
        inFront++
        act(screen.cameToFront(activity is UpdateAppActivity))
    }

    /** From the application's activity callbacks: [activity] left the front. */
    fun paused() {
        inFront--
    }

    /** The Update screen is gone; the next refusal opens it again. */
    fun dismissed() {
        main.post { screen = screen.closed() }
    }

    private fun act(step: OutdatedScreen.Step) {
        screen = step.state
        if (step.open) app.startActivity(Intent(app, UpdateAppActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
    }
}
