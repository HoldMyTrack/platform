package dev.holdmytrack.android.flows

import android.Manifest
import android.app.Activity
import android.content.Context
import android.content.Intent
import android.location.Location
import android.location.LocationManager
import android.location.provider.ProviderProperties
import android.os.SystemClock
import androidx.test.platform.app.InstrumentationRegistry
import androidx.test.runner.lifecycle.ActivityLifecycleMonitorRegistry
import androidx.test.runner.lifecycle.Stage
import androidx.test.uiautomator.By
import androidx.test.uiautomator.BySelector
import androidx.test.uiautomator.Configurator
import androidx.test.uiautomator.StaleObjectException
import androidx.test.uiautomator.UiDevice
import androidx.test.uiautomator.UiObject2
import androidx.test.uiautomator.Until
import dev.holdmytrack.android.MainActivity
import dev.holdmytrack.android.net.Session
import dev.holdmytrack.android.tour.TourStore
import java.util.concurrent.atomic.AtomicBoolean
import kotlin.concurrent.thread

/*
 * The steps every flow class drives the app with, on an emulator against the dev stack
 * (`docs/DEVELOPMENT.md`, "Android verification"): waits, taps that retry what the app drops
 * while it settles, signing in and a walk for the recorder.
 */

const val PACKAGE = "dev.holdmytrack.android"
// Generous: an emulator on a busy machine takes seconds to draw a screen.
const val TIMEOUT_MS = 60_000L
const val SHORT_MS = 5_000L
const val SIGN_IN_MS = 15_000L
/** Quarter-second readings a view's bounds must hold before it's tapped ([still]). */
const val STILL_READINGS = 2

val instrumentation get() = InstrumentationRegistry.getInstrumentation()
val context: Context get() = instrumentation.targetContext
val device: UiDevice get() = UiDevice.getInstance(instrumentation)

fun id(name: String): BySelector = By.res(PACKAGE, name)

/** The device's own stay-on setting, put back after the class ([restoreDevice]). */
private var stayOn = "0"

/** Sets the emulator up for a class of flows: permissions, no error dialogs, the screen kept on. */
fun prepareDevice() {
    // The map animates while recording (the camera follows, the button pulses), so the app never
    // goes idle; waiting for it before each query would time every query out.
    Configurator.getInstance().waitForIdleTimeout = 0
    val automation = instrumentation.uiAutomation
    listOf(Manifest.permission.ACCESS_FINE_LOCATION, Manifest.permission.ACCESS_COARSE_LOCATION, Manifest.permission.POST_NOTIFICATIONS)
        .forEach { automation.grantRuntimePermission(PACKAGE, it) }
    automation.executeShellCommand("appops set $PACKAGE android:mock_location allow").close()
    // A loaded emulator's own apps (the launcher) can stop responding; their dialog would cover the app.
    automation.executeShellCommand("settings put global hide_error_dialogs 1").close()
    // Kept on for the class, since a flow's waits can outlast the screen-off timeout.
    stayOn = device.executeShellCommand("settings get global stay_on_while_plugged_in").trim().takeIf { it.toIntOrNull() != null } ?: "0"
    device.executeShellCommand("settings put global stay_on_while_plugged_in 7")
}

fun restoreDevice() {
    device.executeShellCommand("settings put global stay_on_while_plugged_in $stayOn")
}

/** Wakes and unlocks an emulator that booted asleep, so [need] doesn't time out on a black screen. */
fun wakeDevice() {
    device.wakeUp()
    device.executeShellCommand("wm dismiss-keyguard")
}

fun need(selector: BySelector): UiObject2 =
    device.wait(Until.findObject(selector), TIMEOUT_MS) ?: fail("not on screen: $selector")

/** Fails with what was on screen saved for whoever reads the failure (adb pull it). */
fun fail(message: String): Nothing {
    val dir = context.getExternalFilesDir(null)
    device.takeScreenshot(java.io.File(dir, "failure.png"))
    device.dumpWindowHierarchy(java.io.File(dir, "failure.xml"))
    throw AssertionError(message)
}

/** Fails, saving the screen, unless [holds]. */
fun expect(message: String, holds: Boolean) {
    if (!holds) fail(message)
}

/** Whether [holds] comes true within the timeout, asked every quarter second. */
fun waitUntil(holds: () -> Boolean): Boolean {
    val deadline = SystemClock.uptimeMillis() + TIMEOUT_MS
    while (true) {
        if (holds()) return true
        if (SystemClock.uptimeMillis() > deadline) return false
        Thread.sleep(250)
    }
}

/** At least [n] of [selector] on screen. */
fun atLeast(selector: BySelector, n: Int) =
    expect("fewer than $n on screen: $selector", waitUntil { device.findObjects(selector).size >= n })

/** Exactly [n] of [selector] on screen, within the timeout. */
fun count(selector: BySelector, n: Int): Boolean = waitUntil { device.findObjects(selector).size == n }

/** Rows whose check target offers to uncheck them (`panel_row_uncheck`). */
fun checkedTiles(): BySelector = id("track_tile_target").descStartsWith("Uncheck ")

fun checkedRows(): Int = device.findObjects(checkedTiles()).size

/** [selector] once it's on screen and its bounds have held for half a second, two readings in a
 *  row: a dialog sliding back down as the keyboard goes, or a layout that stalls for a dropped
 *  frame, takes a tap meant for it elsewhere. */
fun still(selector: BySelector): UiObject2 {
    var last = need(selector).visibleBounds
    var held = 0
    expect("still moving: $selector", waitUntil {
        Thread.sleep(250)
        val now = need(selector).visibleBounds
        held = if (now == last) held + 1 else 0
        last = now
        held >= STILL_READINGS
    })
    return need(selector)
}

/** Taps what [target] finds until [done] holds, for taps the app can drop while it settles. */
fun tapUntil(target: () -> UiObject2, done: () -> Boolean) {
    for (attempt in 1..3) {
        retrying { target().click() }
        val deadline = SystemClock.uptimeMillis() + SHORT_MS
        while (SystemClock.uptimeMillis() < deadline) {
            if (done()) return
            Thread.sleep(250)
        }
    }
    fail("tapped three times, nothing changed")
}

/** Runs [action] again if the view it found was replaced meanwhile. */
fun retrying(action: () -> Unit) {
    repeat(3) {
        try {
            return action()
        } catch (_: StaleObjectException) {
            device.waitForIdle()
        }
    }
    action()
}

/** The bottom bar's Trips tapped until it's the one marked and the sheet shows its list. Each tap
 *  waits for the bar to stop moving: back from the Save screen it's still being laid out, and a
 *  tap read from those bounds lands on the record button and starts a recording, which then hides
 *  the sheet from every flow after. */
fun openTrips() {
    tapUntil({ still(id("nav_trips")) }) {
        if (device.hasObject(id("recording_status"))) fail("a tap on Trips started a recording")
        device.hasObject(id("nav_trips").selected(true)) && device.hasObject(id("trips_list"))
    }
}

/** The Tracks sheet open full height, so its rows are on screen. */
fun expandSheet() {
    val expanded = { device.hasObject(id("panel_handle").descStartsWith("Collapse")) }
    need(id("panel_handle"))
    if (!expanded()) tapUntil({ need(id("panel_handle")) }, expanded)
}

/** The activity on screen now, or null between two. */
fun resumedActivity(): Activity? {
    var resumed: Activity? = null
    instrumentation.runOnMainSync {
        resumed = ActivityLifecycleMonitorRegistry.getInstance().getActivitiesInStage(Stage.RESUMED).singleOrNull()
    }
    return resumed
}

/** Starts the app afresh, keeping whatever session it has, and returns once its new screen has
 *  replaced the old one: until then a query finds the old screen's views. */
fun start() {
    // The tour's offer would cover the map. The phone keeps whether it was offered, not the
    // account (TourStore), so the flows mark it seen.
    TourStore(context).let { it.save(it.load().copy(tour = true)) }
    val before = resumedActivity()
    context.startActivity(
        Intent(context, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TASK),
    )
    expect("the app started afresh", waitUntil { resumedActivity().let { it != null && it !== before } })
}

/** Taps [selector] until its screen goes, waiting out a sign-in each time: a tap that lands before
 *  the screen settles is lost, and a sign-in can take seconds. */
fun tapAway(selector: BySelector) {
    for (attempt in 1..3) {
        retrying { device.findObject(selector)?.click() }
        if (device.wait(Until.gone(selector), SIGN_IN_MS)) return
    }
    fail("tapped three times, still on screen: $selector")
}

/** Opens the app signed in to [account], on the map, whoever it was left signed in as. */
fun signIn(account: TestAccount) {
    instrumentation.runOnMainSync { Session.clear() }
    start()
    need(id("email").enabled(true)).text = account.email
    need(id("password")).text = account.password
    tapAway(id("submit"))
    need(id("panel_handle"))
}

/** Runs [block] while the GPS provider walks north from Cleveland's Public Square, a fix a second,
 *  ~11 m apart: an emulator recording needs a moving location, or Stop drops it. */
fun walking(block: () -> Unit) {
    val locations = context.getSystemService(LocationManager::class.java)
    locations.addTestProvider(
        LocationManager.GPS_PROVIDER, false, false, false, false, true, true, true,
        ProviderProperties.POWER_USAGE_LOW, ProviderProperties.ACCURACY_FINE,
    )
    locations.setTestProviderEnabled(LocationManager.GPS_PROVIDER, true)
    val walking = AtomicBoolean(true)
    val walker = thread {
        var step = 0
        while (walking.get()) {
            val fix = Location(LocationManager.GPS_PROVIDER).apply {
                latitude = 41.4993 + step * 0.0001
                longitude = -81.6944
                accuracy = 5f
                speed = 1.4f
                time = System.currentTimeMillis()
                elapsedRealtimeNanos = SystemClock.elapsedRealtimeNanos()
            }
            runCatching { locations.setTestProviderLocation(LocationManager.GPS_PROVIDER, fix) }
            step++
            Thread.sleep(1_000)
        }
    }
    try {
        block()
    } finally {
        walking.set(false)
        walker.join()
        runCatching { locations.removeTestProvider(LocationManager.GPS_PROVIDER) }
    }
}
