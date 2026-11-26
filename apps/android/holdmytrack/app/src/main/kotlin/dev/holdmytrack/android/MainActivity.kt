package dev.holdmytrack.android

import dev.holdmytrack.android.recording.db.RecordedTrackStore
import kotlinx.coroutines.Job
import kotlinx.coroutines.launch
import androidx.lifecycle.lifecycleScope
import android.content.Context
import android.content.Intent
import android.graphics.Rect
import android.os.Bundle
import android.view.View
import androidx.activity.OnBackPressedCallback
import androidx.appcompat.app.AppCompatActivity
import androidx.core.graphics.Insets
import androidx.core.view.ViewCompat
import androidx.core.view.WindowInsetsCompat
import androidx.core.view.updatePadding
import androidx.fragment.app.Fragment
import com.google.android.material.bottomnavigation.BottomNavigationView
import dev.holdmytrack.android.map.MapMode
import dev.holdmytrack.android.imports.ImportFailureAlert
import dev.holdmytrack.android.net.HoldMyTrackApi
import dev.holdmytrack.android.net.Session
import dev.holdmytrack.android.panel.PanelTab
import dev.holdmytrack.android.recording.RecordingService
import dev.holdmytrack.android.sync.HiddenCandidates
import dev.holdmytrack.android.sync.RecordingSendRules
import dev.holdmytrack.android.sync.RecordingSends
import dev.holdmytrack.android.sync.SyncCandidates
import dev.holdmytrack.android.tour.TourController
import dev.holdmytrack.android.tour.TourEvent
import dev.holdmytrack.android.tour.TourHost
import dev.holdmytrack.android.tour.TourMenu
import dev.holdmytrack.android.tour.TourTarget

/**
 * The app's main window: the bottom bar — Tracks, Trips, Record, Library, You — and the tab above it
 * (`apps/android/docs/IMPLEMENTATION.md` §1.3). Tracks, Trips, Library
 * and Sync are all the map ([MapFragment]): its panel's tabs, Sync opened from Library's head
 * with Library lit in the bar, and its list drawn on the map it covers. You is [YouFragment]. Tabs are shown and hidden
 * rather than replaced, so the map — its camera, its layers, a recording on it — is just as it
 * was on coming back to it. The record button over the bar's middle slot is the map's to drive
 * (`MapFragment.onRecordTap`).
 *
 * Never shows the map without a session: a signed-out visitor is handed straight to
 * `SignInActivity`, as the web's page shell redirects one to `/signin` (`docs/IMPLEMENTATION.md` §4.19), before any layout
 * or `MapView` exists. A bare basemap with none of the three user layers — all behind
 * `requireAuth` server-side — would be a weak first impression next to the Demo account that
 * screen offers one tap away.
 */
class MainActivity : AppCompatActivity() {

    /** The bottom bar's tabs, Record aside — a button rather than a tab — and Sync, Library's. */
    enum class Tab {
        TRACKS, TRIPS, LIBRARY, SYNC, YOU;

        /** Where Back goes: from Sync to Library, where it opens, from another tab to Tracks,
         *  and from Tracks out of the app (null). */
        val back: Tab?
            get() = when (this) {
                TRACKS -> null
                SYNC -> LIBRARY
                else -> TRACKS
            }

        companion object {
            /** The tab a saved state or an intent names, or null for a name no tab has, such as an older build's. */
            fun named(name: String): Tab? = entries.firstOrNull { it.name == name }
        }
    }

    private lateinit var nav: BottomNavigationView
    private var tab = Tab.TRACKS

    /** The tour, its offer and its first-time cards (`apps/docs/SPEC.md` FR-2.12). */
    lateinit var tour: TourController
        private set

    /** Set while the bar's selection is moved in code, so its listener doesn't act on it. */
    private var selectingInCode = false

    /** Back within the bar ([Tab.back]); disabled on Tracks, so Back leaves the app. */
    private val backInBar = object : OnBackPressedCallback(false) {
        override fun handleOnBackPressed() {
            tab.back?.let(::showTab)
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        intent = fromApp(intent)
        if (!Session.isSignedIn) {
            SignInActivity.open(this)
            finish()
            return
        }
        // Likewise an account whose email isn't confirmed: the server refuses it every tile.
        if (!Session.emailVerified) {
            VerifyEmailActivity.open(this)
            finish()
            return
        }
        setContentView(R.layout.activity_main)
        nav = findViewById(R.id.bottom_nav)
        // The middle slot is where the record button sits: no tab, and nothing for TalkBack to
        // stop on under the button.
        nav.findViewById<View>(R.id.nav_record)?.importantForAccessibility = View.IMPORTANT_FOR_ACCESSIBILITY_NO_HIDE_DESCENDANTS
        nav.setOnItemSelectedListener { item ->
            if (!selectingInCode) {
                tabOf(item.itemId)?.let { picked ->
                    showTab(picked)
                    if (picked == Tab.TRIPS) tour.notice(TourEvent.Tab(PanelTab.TRIPS))
                }
            }
            true
        }
        // Library lit over Sync: a tap on it is a reselect, and goes back to Library.
        nav.setOnItemReselectedListener { item ->
            if (!selectingInCode) tabOf(item.itemId)?.takeIf { it != tab }?.let(::showTab)
        }
        tour = TourController(this, tourHost)
        // The bar pads itself clear of the gesture bar, so the tabs above it get no bottom inset
        // — the map's own chrome adds the one it's given (`ChromeInsets.install`). At the
        // sides — a landscape phone's navigation bar or its camera cutout — the tabs are padded
        // in here, once for all of them, and see no side inset of their own.
        ViewCompat.setOnApplyWindowInsetsListener(findViewById(R.id.main_content)) { content, insets ->
            val sideTypes = WindowInsetsCompat.Type.navigationBars() or WindowInsetsCompat.Type.displayCutout()
            val sides = insets.getInsets(sideTypes)
            content.setPadding(sides.left, 0, sides.right, 0)
            val navigation = insets.getInsets(WindowInsetsCompat.Type.navigationBars())
            val cutout = insets.getInsets(WindowInsetsCompat.Type.displayCutout())
            WindowInsetsCompat.Builder(insets)
                .setInsets(WindowInsetsCompat.Type.navigationBars(), Insets.of(0, navigation.top, 0, 0))
                .setInsets(WindowInsetsCompat.Type.displayCutout(), Insets.of(0, cutout.top, 0, cutout.bottom))
                .build()
        }
        // In place of Material's own, which pads the bar by the keyboard too: risen over it, the bar
        // would squeeze the map, and the Tracks list would follow the shorter view (`docs/SPEC.md`
        // FR-5.11). The keyboard covers the window instead (`windowSoftInputMode`).
        // Its sides clear a landscape phone's navigation bar or camera cutout, as Material's did.
        val navPadding = Insets.of(nav.paddingLeft, nav.paddingTop, nav.paddingRight, nav.paddingBottom)
        ViewCompat.setOnApplyWindowInsetsListener(nav) { bar, insets ->
            val sides = insets.getInsets(WindowInsetsCompat.Type.navigationBars() or WindowInsetsCompat.Type.displayCutout())
            bar.updatePadding(
                left = navPadding.left + sides.left,
                right = navPadding.right + sides.right,
                bottom = navPadding.bottom + insets.getInsets(WindowInsetsCompat.Type.navigationBars()).bottom,
            )
            insets
        }
        onBackPressedDispatcher.addCallback(this, backInBar)

        // A recreation (rotation, theme, language) restores the tabs' fragments, which tab was
        // showing and each one's own state.
        if (savedInstanceState == null) {
            showTab(Tab.TRACKS)
            tabFor(intent)?.let(::showTab)
            editPrivateLocation(intent)
        } else {
            tab = savedInstanceState.getString(STATE_TAB)?.let(Tab::named) ?: Tab.TRACKS
            markTab(tab)
            // The map's panel comes back on its Tracks tab; the others put it back on their own
            // once the map's view is up.
            when (tab) {
                Tab.TRIPS -> nav.post { map()?.showTrips() }
                Tab.LIBRARY -> nav.post { map()?.showLibrary() }
                Tab.SYNC -> nav.post { map()?.showSync() }
                Tab.TRACKS, Tab.YOU -> Unit
            }
        }
    }

    override fun onResume() {
        super.onResume()
        // Copies of Trips may have been sent while the app was away, a recording made, and an
        // import may have failed.
        if (::nav.isInitialized) {
            refreshTripsBadge()
            refreshSyncBadge()
        }
        // A recording that couldn't go when saved, with no signal, goes now.
        RecordingSends.send(this)
        ImportFailureAlert.check(this)
    }

    override fun onNewIntent(intent: Intent) {
        val sent = fromApp(intent)
        super.onNewIntent(sent)
        // The notification's Stop and a View on map are both about the map.
        val forMap = sent.action == RecordingService.ACTION_STOP || sent.hasExtra(EXTRA_VIEW_TRACK)
        if (forMap) showMap()
        tabFor(sent)?.let(::showTab)
        map()?.onNewIntent(sent)
        editPrivateLocation(sent)
    }

    override fun onSaveInstanceState(outState: Bundle) {
        super.onSaveInstanceState(outState)
        outState.putString(STATE_TAB, tab.name)
    }

    /**
     * Shows [next]'s fragment and hides the others, adding it the first time. Tracks, Trips
     * and Sync are the same fragment: moving between them moves its panel between them, and
     * Tracks takes it off Private locations too.
     */
    fun showTab(next: Tab) {
        val tag = tagOf(next)
        val fragments = supportFragmentManager
        val transaction = fragments.beginTransaction().setReorderingAllowed(true)
        for (other in TAGS) {
            if (other == tag) continue
            fragments.findFragmentByTag(other)?.takeIf { !it.isHidden }?.let(transaction::hide)
        }
        val target = fragments.findFragmentByTag(tag)
        when {
            target == null -> transaction.add(R.id.main_content, newFragment(tag), tag)
            target.isHidden -> transaction.show(target)
        }
        transaction.commitNow()
        tab = next
        when (next) {
            Tab.TRIPS -> map()?.showTrips()
            Tab.LIBRARY -> map()?.showLibrary()
            Tab.SYNC -> map()?.showSync()
            Tab.TRACKS -> map()?.showTracks()
            else -> Unit
        }
        markTab(next)
    }

    /** The map, when a start of a recording, a View on map or the notification's Stop needs it
     *  — left on Trips if that's where it is, since that's the map too. */
    fun showMap() {
        if (tab == Tab.SYNC || tab == Tab.YOU) showTab(Tab.TRACKS)
    }

    /** The Trips tab's badge: the copies of Trips others sent, waiting to be accepted or
     *  declined (`docs/SPEC.md` FR-13.7) — in the accent, an invitation rather than a chore. */
    fun setTripsWaiting(count: Int) {
        if (count <= 0 || Session.isDemo) {
            nav.removeBadge(R.id.nav_trips)
            return
        }
        nav.getOrCreateBadge(R.id.nav_trips).apply {
            backgroundColor = getColor(R.color.hmt_accent)
            badgeTextColor = getColor(R.color.hmt_surface)
            number = count
            setContentDescriptionQuantityStringsResource(R.plurals.trips_waiting)
        }
    }

    /** The inbox read on launch and on every return to the app; the Trips tab reads it again
     *  as it opens and after every answer. A failed read leaves the badge as it was. */
    private fun refreshTripsBadge() {
        if (Session.isDemo) return
        HoldMyTrackApi.tripSends { result -> result.onSuccess { setTripsWaiting(it.sends.size) } }
    }

    private var syncBadgeRead: Job? = null

    /** Library's badge, and the count on its +: the recordings on this phone waiting to be sent
     *  from Library › Sync, none swiped aside. Read on every return to the map, a recording's Save screen included,
     *  as Library opens and after a send. */
    fun refreshSyncBadge() {
        // The latest read wins.
        syncBadgeRead?.cancel()
        syncBadgeRead = lifecycleScope.launch {
            val keys = RecordedTrackStore(this@MainActivity).all().map { SyncCandidates.key(HoldMyTrackApi.SOURCE_RECORDED, it.id) }
            val waiting = RecordingSendRules.waiting(keys, HiddenCandidates(this@MainActivity, Session.email).all(), Session.isDemo)
            map()?.setSyncWaiting(waiting)
            if (waiting <= 0) {
                nav.removeBadge(R.id.nav_library)
                return@launch
            }
            nav.getOrCreateBadge(R.id.nav_library).apply {
                backgroundColor = getColor(R.color.hmt_accent)
                badgeTextColor = getColor(R.color.hmt_surface)
                number = waiting
                setContentDescriptionQuantityStringsResource(R.plurals.recordings_waiting)
            }
        }
    }

    /** The bottom bar, and the record button over it, gone while something on the map has the
     *  screen (`MapChromeRules.bottomBarShown`). */
    fun setBottomBarShown(shown: Boolean) {
        findViewById<View>(R.id.bottom_bar).visibility = if (shown) View.VISIBLE else View.GONE
    }

    /** The Privacy screen's Add a location on the map, or a row: the map, the editor on it. */
    private fun editPrivateLocation(intent: Intent?) {
        val id = intent?.getStringExtra(EXTRA_PRIVATE_LOCATION) ?: return
        showTab(Tab.TRACKS)
        map()?.editPrivateLocation(id)
    }

    /** The map's panel moved between its tabs: the bar marks the one it shows. */
    fun onPanelTabChanged(panelTab: PanelTab) {
        if (tab == Tab.YOU) return
        markTab(
            when (panelTab) {
                PanelTab.TRIPS -> Tab.TRIPS
                PanelTab.LIBRARY -> Tab.LIBRARY
                PanelTab.SYNC -> Tab.SYNC
                PanelTab.TRACKS -> Tab.TRACKS
            },
        )
    }

    private fun markTab(shown: Tab) {
        tab = shown
        selectingInCode = true
        nav.selectedItemId = itemOf(shown)
        selectingInCode = false
        backInBar.isEnabled = shown.back != null
    }

    private fun map() = supportFragmentManager.findFragmentByTag(TAG_MAP) as? MapFragment

    /** The You tab's Take a tour. */
    fun startTour() = tour.request()

    private val tourHost = object : TourHost {
        override val isDemo get() = Session.isDemo
        override val tab get() = this@MainActivity.tab
        override fun showTab(tab: Tab) = this@MainActivity.showTab(tab)
        override val mode get() = map()?.tourMode
        override fun setMode(mode: MapMode) {
            map()?.setTourMode(mode)
        }
        override val sheetOpen get() = map()?.sheetOpen ?: false
        override fun setSheetOpen(open: Boolean) {
            map()?.setSheetOpen(open)
        }
        override fun setMenuOpen(menu: TourMenu, open: Boolean) {
            map()?.holdMenu(menu, open)
        }
        override val map get() = map()?.mapLibre
        override val blocked get() = map()?.tourBlocked ?: true
        override fun targets(target: TourTarget): List<View> {
            fun mapView(id: Int) = listOfNotNull(map()?.view?.findViewById<View>(id))
            return when (target) {
                TourTarget.SHEET -> mapView(R.id.tracks_sheet)
                TourTarget.RANGE -> mapView(R.id.panel_dates)
                TourTarget.LAYERS -> mapView(R.id.layers_panel) + listOfNotNull(map()?.layersMenu)
                TourTarget.PLACES -> mapView(R.id.places_panel) + listOfNotNull(map()?.placesMenu)
                TourTarget.EXPORT -> mapView(R.id.export_panel)
                TourTarget.MODES -> mapView(R.id.mode_bar) + listOfNotNull(map()?.fogLevelMenu)
                TourTarget.RECORD -> listOfNotNull(findViewById(R.id.record_button))
                TourTarget.YOU_TOUR -> listOfNotNull(youTourRow())
            }
        }
        override fun reveal(target: TourTarget) {
            if (target != TourTarget.YOU_TOUR) return
            val row = youTourRow() ?: return
            row.requestRectangleOnScreen(Rect(0, 0, row.width, row.height), false)
        }
        private fun youTourRow(): View? = supportFragmentManager.findFragmentByTag(TAG_YOU)?.view?.findViewById(R.id.you_tour)
    }

    private fun tagOf(tab: Tab) = when (tab) {
        Tab.TRACKS, Tab.TRIPS, Tab.LIBRARY, Tab.SYNC -> TAG_MAP
        Tab.YOU -> TAG_YOU
    }

    private fun newFragment(tag: String): Fragment = when (tag) {
        TAG_YOU -> YouFragment()
        else -> MapFragment()
    }

    private fun itemOf(tab: Tab) = when (tab) {
        Tab.TRACKS -> R.id.nav_tracks
        Tab.TRIPS -> R.id.nav_trips
        // Sync is opened from Library, so the bar keeps Library lit.
        Tab.LIBRARY, Tab.SYNC -> R.id.nav_library
        Tab.YOU -> R.id.nav_you
    }

    private fun tabOf(itemId: Int) = when (itemId) {
        R.id.nav_tracks -> Tab.TRACKS
        R.id.nav_trips -> Tab.TRIPS
        R.id.nav_library -> Tab.LIBRARY
        R.id.nav_you -> Tab.YOU
        else -> null
    }

    /** [intent] as sent by this app, or, from another app, a plain launch with nothing to act on
     *  ([MainEntry]). */
    private fun fromApp(intent: Intent): Intent =
        if (MainEntry.fromApp(intent.component?.className)) intent else Intent(intent).setAction(Intent.ACTION_MAIN).replaceExtras(Bundle())

    private fun tabFor(intent: Intent?) = intent?.getStringExtra(EXTRA_TAB)?.let(Tab::named)

    companion object {
        private const val TAG_MAP = "map"
        private const val TAG_YOU = "you"
        private val TAGS = listOf(TAG_MAP, TAG_YOU)
        private const val STATE_TAB = "tab"
        private const val EXTRA_TAB = "dev.holdmytrack.android.TAB"
        internal const val EXTRA_VIEW_TRACK = "dev.holdmytrack.android.VIEW_TRACK"
        internal const val EXTRA_VIEW_DAY = "dev.holdmytrack.android.VIEW_DAY"
        private const val EXTRA_PRIVATE_LOCATION = "dev.holdmytrack.android.PRIVATE_LOCATION"

        /** A launch of this activity that keeps what it carries: through the unexported alias,
         *  which only this app can address ([MainEntry]). */
        fun fromApp(context: Context): Intent = Intent().setClassName(context, MainEntry.ALIAS)

        /** Opens the main window on [tab] — `SyncActivity`'s Choose what to sync. Clears whatever is over an
         *  existing one. */
        fun openTab(context: Context, tab: Tab) {
            context.startActivity(
                fromApp(context)
                    .putExtra(EXTRA_TAB, tab.name)
                    .addFlags(Intent.FLAG_ACTIVITY_CLEAR_TOP or Intent.FLAG_ACTIVITY_SINGLE_TOP),
            )
        }

        /** Opens the map with the Private location editor on [id], or on a new one with
         *  `PrivateLocationEditor.NEW` — the Privacy screen's. Clears whatever is over the map. */
        fun editPrivateLocation(context: Context, id: String) {
            context.startActivity(
                fromApp(context)
                    .putExtra(EXTRA_PRIVATE_LOCATION, id)
                    .addFlags(Intent.FLAG_ACTIVITY_CLEAR_TOP or Intent.FLAG_ACTIVITY_SINGLE_TOP),
            )
        }

        /** Opens the map on [trackId], on [day] (`YYYY-MM-DD`, its local date where it was
         *  recorded) — the sync history's View on map. Clears whatever is over an existing map,
         *  which then selects it. */
        fun viewOnMap(context: Context, trackId: String, day: String) {
            context.startActivity(
                fromApp(context)
                    .putExtra(EXTRA_VIEW_TRACK, trackId)
                    .putExtra(EXTRA_VIEW_DAY, day)
                    .addFlags(Intent.FLAG_ACTIVITY_CLEAR_TOP or Intent.FLAG_ACTIVITY_SINGLE_TOP),
            )
        }
    }
}
