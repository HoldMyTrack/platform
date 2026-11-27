package dev.holdmytrack.android.flows

import android.content.Intent
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.uiautomator.By
import androidx.test.uiautomator.Direction
import androidx.test.uiautomator.Until
import dev.holdmytrack.android.MainActivity
import dev.holdmytrack.android.R
import dev.holdmytrack.android.net.Session
import dev.holdmytrack.android.recording.RecordingService
import dev.holdmytrack.android.tour.TourStore
import org.junit.After
import org.junit.AfterClass
import org.junit.Before
import org.junit.BeforeClass
import org.junit.Test
import org.junit.runner.RunWith

/**
 * End-to-end flows over the map's menus and the Tracks sheet's actions, as [MapFlowsTest] runs
 * its own: the Layers menu's picks, the Type and Distance filters, Add to trip, and a Sync row
 * swiped away with Undo. One fresh account ([TestAccount]) serves the class.
 */
@RunWith(AndroidJUnit4::class)
class PanelFlowsTest {

    /** Each pick counts on the button, Show layers hides the picks and keeps them, a pick while
     *  it's off turns it back on, and the picks outlast a new sign-in. They're the phone's, not
     *  the account's, so the flow puts back Roads alone, which a new install has. */
    @Test
    fun theLayersMenuCountsAndKeepsItsPicks() {
        signIn(account)
        try {
            setLayers(roads = true, paths = emptySet(), show = true)
            expect("Roads counted", waitUntil { layersLabel() == "Layers, 1" })
            // The button is read with the menu closed: UI Automator sees only the menu's window.
            openLayers()
            need(id("layers_bike_paths")).click()
            closeMenu()
            expect("Roads and Bike paths", waitUntil { layersLabel() == "Layers, 2" })
            openLayers()
            need(id("layers_master")).click()
            expect("hidden", waitUntil { device.findObject(id("layers_master"))?.isChecked == false })
            expect("the picks kept", need(id("layers_bike_paths")).isChecked)
            closeMenu()
            expect("hidden, still counted", waitUntil { layersLabel() == "Layers, 2" })
            openLayers()
            need(id("layers_shared_paths")).click()
            expect("a pick shows the layers again", waitUntil { device.findObject(id("layers_master"))?.isChecked == true })
            closeMenu()
            expect("three picks", waitUntil { layersLabel() == "Layers, 3" })

            signIn(account)
            expect("kept across a new sign-in", waitUntil { layersLabel() == "Layers, 3" })
            // With nothing picked, Show layers has nothing to show and can't be changed.
            setLayers(roads = false, paths = emptySet(), show = true)
            expect("nothing counted", waitUntil { layersLabel() == "Layers" })
            openLayers()
            expect("Show layers off limits", !need(id("layers_master")).isEnabled)
            closeMenu()
        } finally {
            runCatching { setLayers(roads = true, paths = emptySet(), show = true) }
        }
    }

    /** `docs/SPEC.md` FR-5.2–FR-5.3: Type and Distance narrow the list, and Reset clears both. The
     *  opening view lists the newest two: Mill Creek Falls, a 3.6 mi ride, and the shorter
     *  Evening Loop. */
    @Test
    fun theTypeAndDistanceFiltersNarrowTheList() {
        signIn(account)
        expandSheet()
        expect("the opening view's two rows", count(id("track_text"), 2))

        tapUntil({ still(id("panel_type_trigger")) }) { device.hasObject(id("type_filter_rows")) }
        retrying { need(By.res(PACKAGE, "type_filter_label").textStartsWith("Cycling")).click() }
        device.pressBack()
        expect("Cycling off the list", count(id("track_text"), 1))
        retrying { still(id("panel_reset_filters")).click() }
        expect("Reset brings it back", count(id("track_text"), 2))

        // The shortest end dragged to 3 mi of the slider's 1 to 4 leaves the ride alone.
        // The filter row scrolls sideways: Distance may be past its end.
        if (!device.hasObject(id("panel_distance"))) need(id("panel_filters")).parent.scroll(Direction.RIGHT, 1f)
        // UI Automator doesn't list the slider itself, only its ends under it.
        tapUntil({ still(id("panel_distance")) }) { device.hasObject(id("panel_distance_min")) }
        val lowest = still(id("panel_distance_min"))
        val ends = lowest.parent
        val heading = ends.parent.children.first().visibleBounds
        val left = lowest.visibleBounds.left
        val right = need(id("panel_distance_max")).visibleBounds.right
        // The track lies between the heading and the ends, its knobs over the ends' labels.
        val y = (heading.bottom + ends.visibleBounds.top) / 2
        device.drag(left, y, left + (right - left) * 2 / 3, y, 20)
        device.pressBack()
        expect("the shortest end at 3 mi", waitUntil { device.findObject(id("panel_distance_readout"))?.text?.startsWith("3") == true })
        expect("the ride alone", count(id("track_text"), 1))
        retrying { still(id("panel_reset_filters")).click() }
        expect("Reset clears Distance too", count(id("track_text"), 2))
    }

    /** Add to trip's sheet adds the checked tracks to a Trip in one tap, or to a new one named in
     *  its own sheet. */
    @Test
    fun tracksAreAddedToATripOrANewOneFromAddToTrip() {
        account.createTrip(TRIP, emptyList())
        signIn(account)
        expandSheet()
        atLeast(id("track_tile_target"), 2)
        for (row in 0..1) {
            tapUntil({ device.findObjects(id("track_tile_target"))[row] }) { checkedRows() > row }
        }
        tapUntil({ still(id("panel_add_to_trip")) }) { device.hasObject(id("picker_list")) }
        // The sheet slides up: its row is tapped once it has settled.
        tapUntil({ still(By.text(TRIP)) }) { !device.hasObject(id("picker_list")) }
        expect("both in the Trip", waitUntil { account.trips()[TRIP]?.size == 2 })

        // One, into a new Trip.
        expandSheet()
        while (checkedRows() > 1) {
            val checked = checkedRows()
            tapUntil({ device.findObject(checkedTiles()) }) { checkedRows() < checked }
        }
        tapUntil({ still(id("panel_add_to_trip")) }) { device.hasObject(id("picker_list")) }
        tapUntil({ still(By.text(context.getString(R.string.trip_new))) }) { device.hasObject(id("trip_dialog_name")) }
        need(id("trip_dialog_name")).text = NEW_TRIP
        // The sheet rides up with the keyboard: tapped once it has settled, until it closes.
        // The button, not the sheet's title, which reads the same.
        val create = By.clazz("android.widget.Button").text(context.getString(R.string.trip_create_confirm)).enabled(true)
        tapUntil({ still(create) }) { !device.hasObject(id("trip_dialog_name")) }
        expect("the new Trip holds the one track", waitUntil { account.trips()[NEW_TRIP]?.size == 1 })
    }

    /** The demo account can't send, so its saved recording waits on the Sync sheet: a swipe
     *  hides it, and the Snackbar's Undo puts it back. The recording is deleted after, since the
     *  shot tests show the demo's Sync sheet too. */
    @Test
    fun aSyncRowSwipedAwayIsHiddenWithUndo() {
        signInDemo()
        val walk = "$WALK ${System.currentTimeMillis() % 100_000}"
        val row = By.res(PACKAGE, "candidate_title").text(walk)
        var walked = false
        // From the walk on, so a walk saved before a failure is deleted too.
        try {
            walking {
                need(id("record_button")).click()
                need(id("recording_status"))
                // A recording keeps only past a minute of moving time (`RecordingRules.MIN_DURATION_MS`).
                Thread.sleep(RECORDING_MS)
                need(id("recording_status_stop")).click()
                need(By.res("android", "button1")).click()
                need(id("recording_save"))
                device.waitForIdle()
                retrying { need(id("recording_name")).text = walk }
                retrying { need(id("recording_save")).click() }
                expect("the Save screen closed", device.wait(Until.gone(id("recording_save")), TIMEOUT_MS))
            }
            tapUntil({ still(id("nav_library")) }) { device.hasObject(id("library_sync")) }
            tapUntil({ still(id("library_sync")) }) { device.hasObject(row) }
            // Walks an earlier failed run left hidden may be counted already.
            val before = hiddenCount()
            retrying { still(row).parent.swipe(Direction.LEFT, 0.8f) }
            expect("Show hidden counts it", waitUntil { hiddenCount() == before + 1 })
            expect("hidden off the list", device.wait(Until.gone(row), SHORT_MS))
            retrying { need(By.text(context.getString(R.string.sync_undo))).click() }
            expect("back on the list", device.wait(Until.hasObject(row), TIMEOUT_MS))
            expect("no longer counted", waitUntil { hiddenCount() == before })
            walked = true
        } finally {
            // A failure in the flow is the one reported; after a pass, a walk left is a failure.
            if (walked) deleteWalks() else runCatching { deleteWalks() }
        }
    }

    /** What Show hidden counts, 0 while it isn't offered. */
    private fun hiddenCount(): Int =
        device.findObject(id("sync_show_hidden"))?.text?.let { Regex("""\d+""").find(it)?.value?.toInt() } ?: 0

    /** Deletes every walk this flow saved, hidden ones too: the demo's Sync sheet is in the shot tests. */
    private fun deleteWalks() {
        val walks = By.res(PACKAGE, "candidate_title").textStartsWith(WALK)
        // A flow that failed before Sync opened leaves the map showing.
        if (!device.hasObject(id("sync_list"))) {
            tapUntil({ still(id("nav_library")) }) { device.hasObject(id("library_sync")) }
            tapUntil({ still(id("library_sync")) }) { device.hasObject(id("sync_list")) }
        }
        if (hiddenCount() > 0) retrying { still(id("sync_show_hidden")).click() }
        while (device.wait(Until.hasObject(walks), SHORT_MS)) {
            // The title sits in the row's text column: its row is two levels up.
            retrying { need(walks).parent.parent.findObject(id("candidate_delete")).click() }
            retrying { need(By.res("android", "button1")).click() }
            device.wait(Until.gone(By.res("android", "button1")), SHORT_MS)
            Thread.sleep(500)
        }
        expect("every walk deleted", !device.hasObject(walks))
    }

    /** Opens the app on the demo account, as [signIn] does for the test account. */
    private fun signInDemo() {
        instrumentation.runOnMainSync { Session.clear() }
        TourStore(context).let { it.save(it.load().copy(tour = true)) }
        context.startActivity(
            Intent(context, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TASK),
        )
        // A tap that lands before the screen settles is lost.
        tapUntil({ still(id("demo").enabled(true)) }) { !device.hasObject(id("demo")) }
        need(id("panel_handle"))
    }

    private fun layersLabel(): String? = device.findObject(id("layers_button"))?.contentDescription

    /** The Layers menu opened: a tap during the map's first load is lost. */
    private fun openLayers() {
        if (!device.hasObject(id("layers_master"))) tapUntil({ still(id("layers_button")) }) { device.hasObject(id("layers_master")) }
    }

    private fun closeMenu() {
        device.pressBack()
        expect("the menu closed", device.wait(Until.gone(id("layers_master")), SHORT_MS))
    }

    /** The Layers picks set through the menu: Roads, the named paths and Show layers. */
    private fun setLayers(roads: Boolean, paths: Set<String>, show: Boolean) {
        openLayers()
        fun set(name: String, on: Boolean) {
            if (need(id(name)).isChecked != on) retrying { need(id(name)).click() }
        }
        set("layers_roads", roads)
        for (path in listOf("layers_bike_paths", "layers_shared_paths", "layers_mtb_trails")) set(path, path in paths)
        val master = need(id("layers_master"))
        if (master.isEnabled && master.isChecked != show) master.click()
        closeMenu()
    }

    @Before
    fun wake() = wakeDevice()

    /** A recording a failed flow left running would hide the sheet from every flow after it:
     *  the test account's, or the demo's, which the phone keeps under no email. */
    @After
    fun endRecording() {
        RecordingService.forgetAccount(context, account.email)
        RecordingService.forgetAccount(context, "")
    }

    private companion object {
        const val TRIP = "Lakeside"
        const val NEW_TRIP = "Ridge weekend"
        const val WALK = "Sync walk"
        const val RECORDING_MS = 70_000L

        lateinit var account: TestAccount

        @BeforeClass
        @JvmStatic
        fun createAccount() {
            prepareDevice()
            account = TestAccount.create()
        }

        @AfterClass
        @JvmStatic
        fun deleteAccount() {
            restoreDevice()
            account.delete()
        }
    }
}
