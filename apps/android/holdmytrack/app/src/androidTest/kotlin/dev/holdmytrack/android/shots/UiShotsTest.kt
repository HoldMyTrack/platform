package dev.holdmytrack.android.shots

import android.content.Context
import android.content.Intent
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import androidx.test.uiautomator.By
import androidx.test.uiautomator.BySelector
import androidx.test.uiautomator.Configurator
import androidx.test.uiautomator.UiDevice
import androidx.test.uiautomator.UiObject2
import androidx.test.uiautomator.Until
import androidx.recyclerview.widget.RecyclerView
import androidx.test.runner.lifecycle.ActivityLifecycleMonitorRegistry
import androidx.test.runner.lifecycle.Stage
import dev.holdmytrack.android.MainActivity
import dev.holdmytrack.android.R
import dev.holdmytrack.android.net.Session
import dev.holdmytrack.android.tour.TourStore
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Before
import org.junit.FixMethodOrder
import org.junit.Test
import org.junit.runner.RunWith
import org.junit.runners.MethodSorters
import java.io.File

/**
 * A screenshot of every `apps/docs/ui-states.json` entry this app can reach on the demo account,
 * saved as `<id>.png` in the app's files folder (`ui-shots/`), for `make ui-compare` to put beside
 * iOS's. Runs only when asked (`-e uiShots true`), so `make e2e-android` skips it.
 */
@RunWith(AndroidJUnit4::class)
@FixMethodOrder(MethodSorters.NAME_ASCENDING)
class UiShotsTest {

    @Before
    fun setUp() {
        assumeTrue("ui-compare only", InstrumentationRegistry.getArguments().getString("uiShots") == "true")
        Configurator.getInstance().waitForIdleTimeout = 0
        device.wakeUp()
        device.executeShellCommand("wm dismiss-keyguard")
        device.executeShellCommand("settings put system font_scale 1.0")
        device.setOrientationNatural()
    }

    @Test
    fun a_default() {
        signedOut()
        shot("sign-in")
        demo()
        step("tracks") { tab("nav_tracks"); heights("tracks") }
        step("track-focused") {
            half()
            need(id("track_title")).click()
            need(id("track_actions")); settle()
            shot("track-focused")
            need(id("panel_info")).click()
            device.wait(Until.hasObject(id("info_value")), 10_000); settle()
            shot("track-info")
            device.pressBack(); settle()
        }
        step("tracks-checked") {
            half()
            // The focused row's tile: it alone is checked.
            need(id("track_tile_target")).click()
            need(id("track_actions")); settle()
            shot("tracks-checked")
            // Back unchecks every row.
            device.pressBack(); settle()
        }
        step("fog") {
            need(id("mode_fog")).click(); settle(4_000)
            shot("fog")
            need(id("mode_fog")).click()
            device.wait(Until.hasObject(id("fog_level_rows")), SHORT_MS); settle()
            shot("fog-levels")
            device.pressBack(); settle()
            need(id("mode_normal")).click(); settle()
        }
        step("layers-menu") { menu("layers_button", "layers-menu") }
        step("places-menu") { menu("places_button", "places-menu") }
        step("export") {
            need(id("export_button")).click()
            device.wait(Until.hasObject(id("export_viewfinder")), SHORT_MS); settle()
            shot("export")
            device.pressBack(); settle()
        }
        step("trips") {
            tab("nav_trips")
            heights("trips")
            half()
            // The list opens scrolled past the open Trip (ui-states.json, trips-half), so its
            // folder and totals are brought back into view first.
            listToTop(R.id.trips_list)
            // The open Trip's folder: the name just above its totals.
            val stats = need(id("trips_stats")).visibleBounds
            val name = device.findObjects(id("trip_name")).filter { it.visibleBounds.bottom <= stats.top }
                .maxByOrNull { it.visibleBounds.top } ?: error("no open Trip's folder above its totals")
            val trip = name.text
            name.click(); settle()
            shot("trips-folded")
            need(By.res(PACKAGE, "trip_name").text(trip)).click(); settle()
        }
        step("library") {
            tab("nav_library")
            heights("library")
            half()
            need(id("library_sync")).click(); settle()
            heights("sync")
            device.pressBack(); settle()
        }
        step("you") {
            tab("nav_you")
            shot("you")
            need(id("you_privacy")).click(); settle(4_000)
            shot("privacy")
            device.pressBack(); settle()
            need(id("you_account")).click(); settle(6_000)
            shot("settings")
            device.pressBack(); settle()
        }
        assertTrue("steps that failed: $failed", failed.isEmpty())
    }

    @Test
    fun b_landscape() {
        signedOut()
        demo()
        device.setOrientationLeft(); settle(3_000)
        halves("landscape")
        device.setOrientationNatural()
    }

    @Test
    fun c_large() {
        device.executeShellCommand("settings put system font_scale 1.3")
        signedOut()
        demo()
        halves("large")
        device.executeShellCommand("settings put system font_scale 1.0")
    }

    private val failed = mutableListOf<String>()

    /** One part of the walk: a failure is noted, and the next part starts from the Tracks tab. */
    private fun step(name: String, block: () -> Unit) {
        try {
            block()
        } catch (e: Throwable) {
            failed += "$name: $e"
            device.findObject(id("nav_tracks"))?.click()
            settle()
        }
    }

    /** Tracks, Trips and Library half open, then You, each named `<tab>-half-<suffix>`. */
    private fun halves(suffix: String) {
        for ((nav, name) in listOf("nav_tracks" to "tracks", "nav_trips" to "trips", "nav_library" to "library")) {
            tab(nav)
            half()
            shot("$name-half-$suffix")
        }
        tab("nav_you")
        shot("you-$suffix")
    }

    /** The open tab's sheet closed, half open and open all the way, then half open again. */
    private fun heights(name: String) {
        dragHandle(1.0)
        shot("$name-collapsed")
        half()
        shot("$name-half")
        dragHandle(0.0)
        shot("$name-expanded")
        dragHandle(1.0)
        half()
    }

    private fun listToTop(list: Int) {
        instrumentation.runOnMainSync {
            ActivityLifecycleMonitorRegistry.getInstance().getActivitiesInStage(Stage.RESUMED)
                .filterIsInstance<MainActivity>().singleOrNull()
                ?.findViewById<RecyclerView>(list)?.scrollToPosition(0)
        }
        settle()
    }

    private fun menu(button: String, name: String) {
        need(id(button)).click(); settle()
        shot(name)
        device.pressBack(); settle()
    }

    private fun half() {
        val handle = device.findObject(id("panel_handle")) ?: return
        if (handle.contentDescription == "Expand the panel") handle.click()
        settle()
    }

    /** The sheet's grip dragged to [fraction] of the map's height: 0 is the top, 1 the bottom. */
    private fun dragHandle(fraction: Double) {
        val handle = device.findObject(id("panel_handle")) ?: return
        val map = need(id("main_content")).visibleBounds
        val from = handle.visibleBounds
        val y = (map.top + (map.bottom - map.top) * fraction).toInt().coerceIn(map.top + 1, map.bottom - 1)
        device.swipe(from.centerX(), from.centerY(), from.centerX(), y, 40)
        settle()
    }

    private fun tab(nav: String) {
        need(id(nav)).click(); settle(3_000)
    }

    private fun signedOut() {
        instrumentation.runOnMainSync { Session.clear() }
        TourStore(context).let { it.save(it.load().copy(tour = true)) }
        context.startActivity(
            Intent(context, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TASK),
        )
        need(id("demo")); settle()
    }

    private fun demo() {
        need(id("demo")).click()
        settle(4_000)
        // A recording a stray tap started in an earlier run is offered back; it's thrown away.
        device.findObject(By.text("Discard"))?.let {
            it.click(); settle()
            device.findObject(By.res("android", "button1"))?.click(); settle()
        }
        need(id("panel_handle")); settle()
    }

    private fun shot(name: String) {
        val dir = File(context.getExternalFilesDir(null), "ui-shots").apply { mkdirs() }
        device.takeScreenshot(File(dir, "$name.png"))
    }

    /** A failed wait leaves `_fail-<n>.png`, which ui-compare.py skips, to show what was there. */
    private fun need(selector: BySelector): UiObject2 =
        device.wait(Until.findObject(selector), TIMEOUT_MS) ?: run {
            shot("_fail-${++failures}")
            error("not on screen: $selector")
        }

    private var failures = 0

    private fun settle(ms: Long = 1_500) = Thread.sleep(ms)

    private companion object {
        const val PACKAGE = "dev.holdmytrack.android"
        const val TIMEOUT_MS = 30_000L
        const val SHORT_MS = 5_000L
        val instrumentation get() = InstrumentationRegistry.getInstrumentation()
        val context: Context get() = instrumentation.targetContext
        val device: UiDevice get() = UiDevice.getInstance(instrumentation)
        fun id(name: String): BySelector = By.res(PACKAGE, name)
    }
}