package dev.holdmytrack.android.flows

import android.Manifest
import android.content.Context
import android.content.Intent
import android.location.Location
import android.location.LocationManager
import android.location.provider.ProviderProperties
import android.os.SystemClock
import android.view.View
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import androidx.test.runner.lifecycle.ActivityLifecycleMonitorRegistry
import androidx.test.runner.lifecycle.Stage
import androidx.test.uiautomator.By
import androidx.test.uiautomator.Configurator
import androidx.test.uiautomator.BySelector
import androidx.test.uiautomator.Direction
import androidx.test.uiautomator.StaleObjectException
import androidx.test.uiautomator.UiDevice
import androidx.test.uiautomator.UiObject2
import androidx.test.uiautomator.Until
import dev.holdmytrack.android.MainActivity
import dev.holdmytrack.android.R
import dev.holdmytrack.android.net.Session
import dev.holdmytrack.android.tour.TourStore
import org.junit.AfterClass
import org.junit.Assert.assertTrue
import org.junit.BeforeClass
import org.junit.FixMethodOrder
import org.junit.Test
import org.junit.runner.RunWith
import org.junit.runners.MethodSorters
import java.time.LocalDate
import java.time.format.DateTimeFormatter
import java.util.Locale
import kotlin.concurrent.thread

/**
 * End-to-end flows over the map's state rules, on an emulator against the dev stack the app was
 * built for (`docs/DEVELOPMENT.md`, "Android verification"): new Dates keeping Checked and Hidden
 * on the tracks still listed, a Trip opened from the Trips tab and closed by Back, a recording
 * reaching the Sync sheet, and the keyboard covering the map without shortening it. One fresh
 * account ([TestAccount]) serves the class, in method-name order.
 */
@RunWith(AndroidJUnit4::class)
@FixMethodOrder(MethodSorters.NAME_ASCENDING)
class MapFlowsTest {

    /** `docs/SPEC.md` FR-5.8: a list reloaded for new Dates keeps Checked and Hidden on the tracks
     *  still listed. */
    @Test
    fun a_newDatesKeepCheckedAndHiddenOnTheTracksStillListed() {
        signIn()
        expandSheet()
        // The opening view lists the newest two: Mill Creek Falls (Oct 6), then Evening Loop (Oct 5).
        atLeast(id("track_tile_target"), 2)
        for (row in 0..1) {
            tapUntil({ device.findObjects(id("track_tile_target"))[row] }) { checkedRows() > row }
        }
        need(id("selection_bar"))
        need(id("panel_visibility")).click()
        expect("two rows hidden", count(id("track_hidden"), 2))

        // From Oct 6, by each track's local day in New York: Mill Creek Falls stays listed, Evening
        // Loop goes, and the camera flies onto Mill Creek Falls.
        pickFrom(LocalDate.of(2026, 10, 6))
        expandSheet()
        expect("only Mill Creek Falls listed", count(id("track_text"), 1))
        expect("Mill Creek Falls still hidden", count(id("track_hidden"), 1))
        expect("Mill Creek Falls still checked", count(checkedTiles(), 1))
        need(id("selection_bar"))
    }

    @Test
    fun b_theTripsTabOpensTheNewestTripAndBackReturnsToTheArea() {
        signIn()
        val members = listOf(account.idsByDay.getValue("2026-10-01"), account.idsByDay.getValue("2026-10-06"))
        account.createTrip(TRIP, members)
        need(id("nav_trips")).click()
        expandSheet()
        need(By.text(TRIP))
        expect("the Trip's two rows", count(id("track_text"), 2))

        device.pressBack()
        assertTrue("Trip closed", device.wait(Until.gone(By.text(TRIP)), TIMEOUT_MS))
        // Back to the map collapses the sheet; until it has, the handle still offers Collapse.
        need(id("panel_handle").descStartsWith("Expand"))
        expandSheet()
        assertTrue("the range's rows", device.wait(Until.hasObject(id("track_text")), TIMEOUT_MS))
    }

    /** The keyboard covers the map and never shortens it
     *  (`apps/android/docs/IMPLEMENTATION.md` §1.3): a shorter map shows less ground, and the
     *  next camera move, such as Dates' flight, lists only that, dropping Checked and Hidden from
     *  the rest (`docs/SPEC.md` FR-5.8). */
    @Test
    fun d_theKeyboardCoversTheMapWithoutShorteningIt() {
        signIn()
        expandSheet()
        val before = mapHeight()
        // Dates' From, typed: the keyboard comes up over the map and the bottom bar.
        tapUntil({ still(id("panel_dates")) }) { device.hasObject(id("dates_after")) }
        need(id("dates_after")).click()
        need(id("mtrl_picker_header_toggle")).click()
        expect("the keyboard up", waitUntil { keyboardShown() })
        // A shortened map is so as soon as the keyboard is: watched for a few seconds.
        val heights = (1..KEYBOARD_SAMPLES).map { Thread.sleep(250); mapHeight() }
        expect("the map ${before}px tall under the keyboard, not ${heights.distinct()}", heights.all { it == before })
        // Out without setting anything: the keyboard, the picker, then Dates.
        device.pressBack()
        expect("the keyboard down", waitUntil { !keyboardShown() })
        device.pressBack()
        still(By.res("android", "button1")).click()
    }

    /** The map view's height in the app, read on its main thread: UI Automator sees only the
     *  dialog on top. */
    private fun mapHeight(): Int {
        var height = 0
        instrumentation.runOnMainSync {
            val main = ActivityLifecycleMonitorRegistry.getInstance().getActivitiesInStage(Stage.RESUMED)
                .filterIsInstance<MainActivity>().single()
            height = main.findViewById<View>(R.id.map_view).height
        }
        return height
    }

    private fun keyboardShown(): Boolean = device.executeShellCommand("dumpsys input_method").contains("mInputShown=true")

    @Test
    fun c_aStoppedRecordingReachesTheSyncSheet() {
        signIn()
        val locations = context.getSystemService(LocationManager::class.java)
        locations.addTestProvider(
            LocationManager.GPS_PROVIDER, false, false, false, false, true, true, true,
            ProviderProperties.POWER_USAGE_LOW, ProviderProperties.ACCURACY_FINE,
        )
        locations.setTestProviderEnabled(LocationManager.GPS_PROVIDER, true)
        var walking = true
        // A walk north from Cleveland's Public Square, a fix a second, ~11 m apart.
        val walker = thread {
            var step = 0
            while (walking) {
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
            need(id("record_button")).click()
            need(id("recording_status"))
            // A recording keeps only past a minute of moving time (`RecordingService.MIN_DURATION_MS`).
            Thread.sleep(RECORDING_MS)
            need(id("recording_status_stop")).click()
            need(By.res("android", "button1")).click()
            // The Save screen fills its fields once the recording loads, replacing the views.
            need(id("recording_save"))
            device.waitForIdle()
            retrying { need(id("recording_name")).text = WALK }
            retrying { need(id("recording_save")).click() }
            assertTrue("the Save screen closed", device.wait(Until.gone(id("recording_save")), TIMEOUT_MS))
        } finally {
            walking = false
            walker.join()
            runCatching { locations.removeTestProvider(LocationManager.GPS_PROVIDER) }
        }
        need(id("panel_handle"))
        // The tap can land while the Save screen's track is still leaving; tap until the sheet answers.
        tapUntil({ need(id("nav_sync")) }) { device.hasObject(id("panel_handle")) }
        expandSheet()
        // The row sits below the source notes. Half-expanded, the sheet's bottom is past the
        // screen's, so the list has nothing to scroll: the sheet is dragged up by its handle,
        // slowly as a finger would, and then the list scrolls.
        if (device.wait(Until.hasObject(By.textContains(WALK)), SHORT_MS)) return
        val handle = need(id("panel_handle")).visibleBounds
        device.swipe(handle.centerX(), handle.centerY(), handle.centerX(), device.displayHeight / 6, SWIPE_STEPS)
        repeat(SCROLLS) {
            if (device.wait(Until.hasObject(By.textContains(WALK)), SHORT_MS)) return
            retrying { need(id("sync_list")).scroll(Direction.DOWN, 1f) }
        }
        need(By.textContains(WALK))
    }

    private fun need(selector: BySelector): UiObject2 =
        device.wait(Until.findObject(selector), TIMEOUT_MS) ?: fail("not on screen: $selector")

    /** Fails with what was on screen saved for whoever reads the failure (adb pull it). */
    private fun fail(message: String): Nothing {
        val dir = context.getExternalFilesDir(null)
        device.takeScreenshot(java.io.File(dir, "failure.png"))
        device.dumpWindowHierarchy(java.io.File(dir, "failure.xml"))
        throw AssertionError(message)
    }

    /** Fails, saving the screen, unless [holds]. */
    private fun expect(message: String, holds: Boolean) {
        if (!holds) fail(message)
    }

    /** Whether [holds] comes true within the timeout, asked every quarter second. */
    private fun waitUntil(holds: () -> Boolean): Boolean {
        val deadline = SystemClock.uptimeMillis() + TIMEOUT_MS
        while (true) {
            if (holds()) return true
            if (SystemClock.uptimeMillis() > deadline) return false
            Thread.sleep(250)
        }
    }

    /** At least [n] of [selector] on screen. */
    private fun atLeast(selector: BySelector, n: Int) =
        expect("fewer than $n on screen: $selector", waitUntil { device.findObjects(selector).size >= n })

    /** Exactly [n] of [selector] on screen, within the timeout. */
    private fun count(selector: BySelector, n: Int): Boolean = waitUntil { device.findObjects(selector).size == n }

    /** Rows whose check target offers to uncheck them (`panel_row_uncheck`). */
    private fun checkedTiles(): BySelector = id("track_tile_target").descStartsWith("Uncheck ")

    private fun checkedRows(): Int = device.findObjects(checkedTiles()).size

    /** Sets Dates' From to [day] through its dialog and the picker's calendar, then Done. Not typed:
     *  the dialogs slide as the keyboard comes and goes, and taps land on what moved under
     *  ([d_theKeyboardCoversTheMapWithoutShorteningIt] has the keyboard's own case). */
    private fun pickFrom(day: LocalDate) {
        need(id("panel_dates")).click()
        need(id("dates_after")).click()
        // The picker opens on the first track's month, so the day is forward of it.
        val month = day.format(DateTimeFormatter.ofPattern("MMMM yyyy", Locale.getDefault()))
        fun shown(): String {
            var text = ""
            retrying { text = need(id("month_navigation_fragment_toggle")).text }
            return text
        }
        var pages = 0
        while (shown() != month && pages++ < MONTHS) {
            retrying { need(id("month_navigation_next")).click() }
            device.waitForIdle()
        }
        expect("the picker shows $month", shown() == month)
        // By its label, which names the month: the calendar keeps the months either side laid out too.
        val label = day.format(DateTimeFormatter.ofPattern("MMMM d", Locale.getDefault()))
        // The header names the selection, "Oct 6, 2026".
        val picked = Regex("""\b${day.format(DateTimeFormatter.ofPattern("MMM", Locale.getDefault()))}\w*\.? ${day.dayOfMonth}\b""")
        tapUntil({ need(By.descContains(label)) }) { picked.containsMatchIn(need(id("mtrl_picker_header_selection_text")).text) }
        tapUntil({ need(id("confirm_button")) }) { !device.hasObject(id("confirm_button")) }
        need(By.res("android", "button1")).click()
    }

    /** [selector] once it's on screen and its bounds have held for a quarter second: a dialog
     *  sliding back down as the keyboard goes takes a tap meant for its button elsewhere. */
    private fun still(selector: BySelector): UiObject2 {
        var last = need(selector).visibleBounds
        expect("still moving: $selector", waitUntil {
            Thread.sleep(250)
            val now = need(selector).visibleBounds
            (now == last).also { last = now }
        })
        return need(selector)
    }

    /** Taps what [target] finds until [done] holds, for taps the app can drop while it settles. */
    private fun tapUntil(target: () -> UiObject2, done: () -> Boolean) {
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

    /** The Tracks sheet open full height, so its rows are on screen. */
    private fun expandSheet() {
        val expanded = { device.hasObject(id("panel_handle").descStartsWith("Collapse")) }
        need(id("panel_handle"))
        if (!expanded()) tapUntil({ need(id("panel_handle")) }, expanded)
    }

    /** Runs [action] again if the view it found was replaced meanwhile. */
    private fun retrying(action: () -> Unit) {
        repeat(3) {
            try {
                return action()
            } catch (_: StaleObjectException) {
                device.waitForIdle()
            }
        }
        action()
    }

    /** Opens the app signed in to the test account, on the map, whoever it was left signed in as. */
    private fun signIn() {
        InstrumentationRegistry.getInstrumentation().runOnMainSync { Session.clear() }
        // The tour's offer would cover the map. The phone keeps whether it was offered, not the
        // account (TourStore), so the flows mark it seen.
        TourStore(context).let { it.save(it.load().copy(tour = true)) }
        context.startActivity(
            Intent(context, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TASK),
        )
        need(id("email").enabled(true)).text = account.email
        need(id("password")).text = account.password
        // A tap that lands before the screen settles is lost; tap until the sign-in screen goes.
        for (attempt in 1..3) {
            retrying { device.findObject(id("submit"))?.click() }
            if (device.wait(Until.gone(id("submit")), SIGN_IN_MS)) break
        }
        need(id("panel_handle"))
    }

    private companion object {
        const val PACKAGE = "dev.holdmytrack.android"
        // Generous: an emulator on a busy machine takes seconds to draw a screen.
        const val TIMEOUT_MS = 60_000L
        const val SHORT_MS = 5_000L
        const val SCROLLS = 3
        /** Months the picker may page forward to reach a day: Dates' bounds span the account. */
        const val MONTHS = 24
        /** Quarter seconds the map's height is read under the keyboard. */
        const val KEYBOARD_SAMPLES = 12
        /** About a second per swipe: a fling would snap the sheet back. */
        const val SWIPE_STEPS = 200
        const val SIGN_IN_MS = 15_000L
        const val RECORDING_MS = 70_000L
        const val TRIP = "Flows trip"
        const val WALK = "Flows walk"

        val instrumentation get() = InstrumentationRegistry.getInstrumentation()
        val context: Context get() = instrumentation.targetContext
        val device: UiDevice get() = UiDevice.getInstance(instrumentation)
        lateinit var account: TestAccount

        fun id(name: String): BySelector = By.res(PACKAGE, name)

        @BeforeClass
        @JvmStatic
        fun createAccount() {
            // The map animates while recording (the camera follows, the button pulses), so the app
            // never goes idle; waiting for it before each query would time every query out.
            Configurator.getInstance().waitForIdleTimeout = 0
            val automation = instrumentation.uiAutomation
            listOf(Manifest.permission.ACCESS_FINE_LOCATION, Manifest.permission.ACCESS_COARSE_LOCATION, Manifest.permission.POST_NOTIFICATIONS)
                .forEach { automation.grantRuntimePermission(PACKAGE, it) }
            automation.executeShellCommand("appops set $PACKAGE android:mock_location allow").close()
            // A loaded emulator's own apps (the launcher) can stop responding; their dialog would cover the app.
            automation.executeShellCommand("settings put global hide_error_dialogs 1").close()
            account = TestAccount.create()
        }

        @AfterClass
        @JvmStatic
        fun deleteAccount() {
            account.delete()
        }
    }
}
