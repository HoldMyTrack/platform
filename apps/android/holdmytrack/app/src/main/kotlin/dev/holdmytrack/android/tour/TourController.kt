package dev.holdmytrack.android.tour

import android.os.Handler
import android.os.Looper
import android.provider.Settings
import android.view.View
import android.view.ViewGroup
import androidx.appcompat.app.AppCompatActivity
import androidx.core.view.isVisible
import com.google.android.material.snackbar.Snackbar
import dev.holdmytrack.android.MainActivity
import dev.holdmytrack.android.R
import dev.holdmytrack.android.map.MapMode
import org.maplibre.android.camera.CameraPosition
import org.maplibre.android.camera.CameraUpdateFactory
import org.maplibre.android.geometry.LatLng
import org.maplibre.android.maps.MapLibreMap

/** What the tour drives in the app: the tabs, the map's mode, sheet, Layers menu and camera, and the views it points at. */
interface TourHost {
    val isDemo: Boolean
    val tab: MainActivity.Tab
    fun showTab(tab: MainActivity.Tab)
    /** The map's mode, null before the map is up. */
    val mode: MapMode?
    fun setMode(mode: MapMode)
    val sheetOpen: Boolean
    fun setSheetOpen(open: Boolean)
    /** Holds the Layers menu open for looking at, or lets it go. */
    fun setLayersOpen(open: Boolean)
    val map: MapLibreMap?
    /** The Edit window, the Private location editor or a recording has the map. */
    val blocked: Boolean
    fun targets(target: TourTarget): List<View>
    /** Scrolls [target] into view where its screen scrolls. */
    fun reveal(target: TourTarget)
}

/**
 * The tour, its offer and the first-time cards (`apps/android/docs/SPEC.md` FR-2.12), the state around
 * [TourRules] and [TourSteps]: the web's `useTour.ts`. Each step puts its tab, mode, sheet and
 * Layers menu as it says, and the user's come back when the tour ends. The map's camera follows
 * [TourSteps]' views, and goes back to where it was before the first move.
 */
class TourController(private val activity: AppCompatActivity, private val host: TourHost) {

    private val store = TourStore(activity)
    private var seen = store.load()

    private class Running(val steps: List<TourStep>, var index: Int, val mode: MapMode, val tab: MainActivity.Tab, val sheet: Boolean)
    private var running: Running? = null
    private var overlay: TourOverlay? = null
    private var card: TourOverlay? = null
    private var dir = 1

    /** Whether the account has activities, once the map knows; null until then. */
    private var hasActivities: Boolean? = null
    private var requested = false
    private var decided = false

    val touring: Boolean get() = running != null

    /** The map found the account's history: the tour starts or is offered, once. */
    fun historyKnown(any: Boolean) {
        hasActivities = any
        decide()
    }

    /** The You tab's Take a tour. */
    fun request() {
        requested = true
        decided = false
        decide()
    }

    private fun decide() {
        if (decided) return
        when (TourRules.start(requested, host.isDemo, hasActivities, seen)) {
            TourStart.WAIT -> return
            TourStart.START -> start()
            TourStart.OFFER -> offer()
            TourStart.NONE -> Unit
        }
        decided = true
        requested = false
    }

    private fun save(next: TourSeen) {
        seen = next
        store.save(next)
    }

    fun start() {
        if (running != null || host.blocked) return
        closeCard()
        save(seen.copy(tour = true))
        val mode = host.mode ?: MapMode.NORMAL
        val run = Running(TourSteps.of(host.isDemo), -1, mode, host.tab, host.sheetOpen)
        running = run
        overlay = TourOverlay(activity, dim = true).also { view ->
            content().addView(view, ViewGroup.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT))
            view.skip.setText(R.string.tour_skip)
            view.skip.setOnClickListener { end() }
            view.back.setOnClickListener { move(-1) }
            view.next.setOnClickListener { if (run.index == run.steps.lastIndex) end() else move(1) }
        }
        dir = 1
        go(run, TourRules.nextStep(run.steps.map { true }, -1, 1))
    }

    private fun move(d: Int) {
        val run = running ?: return
        dir = d
        go(run, TourRules.nextStep(run.steps.map { true }, run.index, d))
    }

    fun end() {
        val run = running ?: return
        go(run, null)
    }

    private fun go(run: Running, index: Int?) {
        if (index == null) {
            host.setLayersOpen(false)
            camera.end()
            if (host.mode != run.mode) host.setMode(run.mode)
            if (host.tab != run.tab) host.showTab(run.tab)
            host.setSheetOpen(run.sheet)
            overlay?.let { content().removeView(it) }
            overlay = null
            running = null
            return
        }
        val step = run.steps[index]
        run.index = index
        if (host.tab != step.tab) host.showTab(step.tab)
        if (host.mode != step.mode) host.setMode(step.mode)
        host.setSheetOpen(step.sheet)
        host.setLayersOpen(step.layers)
        step.card?.let { save(seen.copy(cards = seen.cards + it)) }
        camera.show(step)
        val view = overlay ?: return
        val (title, body) = text(step.text)
        view.title.setText(title)
        view.body.setText(body)
        view.progress.text = activity.getString(R.string.tour_progress, index + 1, run.steps.size)
        view.back.isVisible = index > 0
        view.skip.isVisible = index < run.steps.lastIndex
        view.next.setText(if (index == run.steps.lastIndex) R.string.tour_finish else R.string.tour_next)
        val target = step.target
        if (target != null) view.post { host.reveal(target) }
        view.pointAt(targets = { if (target == null) emptyList() else host.targets(target) }, onMissing = { move(dir) })
        view.next.post { view.next.requestFocus() }
    }

    /** A step's or card's title and body. */
    private fun text(key: String): Pair<Int, Int> = TEXT.getValue(key)

    private fun content(): ViewGroup = activity.findViewById(android.R.id.content)

    // ---- The offer and the cards ----

    private fun offer() {
        showCard(
            title = activity.getString(R.string.tour_offer_title),
            body = activity.getString(R.string.tour_offer_text),
            target = null,
            secondary = R.string.tour_offer_later to {
                closeCard()
                save(seen.copy(tour = true))
                Snackbar.make(content(), R.string.tour_tip, Snackbar.LENGTH_LONG).show()
            },
            primary = R.string.tour_offer_take to { start() },
            closeOutside = false,
        )
    }

    /** A mode or tab the user picked, which may earn its card. */
    fun notice(event: TourEvent) {
        val earned = TourRules.card(event, seen, touring)
        closeCard()
        if (earned == null) return
        save(seen.copy(cards = seen.cards + earned))
        val (key, target) = when (earned) {
            TourCard.FOG -> "tour_fog" to TourTarget.MODES
            TourCard.HEATMAP -> "tour_heatmap" to TourTarget.MODES
            TourCard.STORIES -> "tour_stories" to TourTarget.SHEET
        }
        val (title, body) = text(key)
        showCard(
            title = activity.getString(title),
            body = activity.getString(body),
            target = target,
            secondary = R.string.tour_card_full_tour to { start() },
            primary = R.string.tour_card_got_it to { closeCard() },
            closeOutside = true,
        )
    }

    private fun showCard(title: String, body: String, target: TourTarget?, secondary: Pair<Int, () -> Unit>, primary: Pair<Int, () -> Unit>, closeOutside: Boolean) {
        closeCard()
        card = TourOverlay(activity, dim = false).also { view ->
            content().addView(view, ViewGroup.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT))
            view.title.text = title
            view.body.text = body
            view.progress.isVisible = false
            view.back.isVisible = false
            view.skip.setText(secondary.first)
            view.skip.setOnClickListener {
                closeCard()
                secondary.second()
            }
            view.next.setText(primary.first)
            view.next.setOnClickListener {
                closeCard()
                primary.second()
            }
            if (closeOutside) view.onOutside = { view.post { closeCard() } }
            view.pointAt(targets = { if (target == null) emptyList() else host.targets(target) }, onMissing = null)
        }
    }

    private fun closeCard() {
        card?.let { content().removeView(it) }
        card = null
    }

    // ---- The camera ----

    private val camera = Camera()

    /**
     * The camera for each step ([TourSteps.movesCamera]): a flight to a step's own view, then its
     * pan; back to the view from before the first move for a step without one and at the end.
     * That view is read at the first move, since the map's own first flight may still be under way
     * at the start. The Stories tab frames its Story itself, so the camera after it is unknown.
     * Animations off on the phone jump, and make the pan a jump to each of its points in turn.
     */
    private inner class Camera {
        private var start: TourView? = null
        private var shown: TourView? = null
        private val handler = Handler(Looper.getMainLooper())

        fun show(step: TourStep) {
            val map = host.map ?: return
            handler.removeCallbacksAndMessages(null)
            if (start == null && TourSteps.movesCamera(step)) start = current(map).also { shown = it }
            if (step.view == null && step.tab == MainActivity.Tab.STORIES) {
                shown = null
                return
            }
            val target = step.view ?: start ?: return
            if (shown?.sameSpot(target) == true) return
            shown = target
            moveTo(map, target) { pan(map, target.pan) }
        }

        fun end() {
            handler.removeCallbacksAndMessages(null)
            val map = host.map
            val back = start
            if (map != null && back != null && shown?.sameSpot(back) != true) moveTo(map, back) {}
            start = null
            shown = null
        }

        private fun current(map: MapLibreMap): TourView {
            val position = map.cameraPosition
            return TourView(position.target?.longitude ?: 0.0, position.target?.latitude ?: 0.0, position.zoom)
        }

        private fun animationsOff() =
            Settings.Global.getFloat(activity.contentResolver, Settings.Global.ANIMATOR_DURATION_SCALE, 1f) == 0f

        private fun moveTo(map: MapLibreMap, view: TourView, then: () -> Unit) {
            map.cancelTransitions()
            val update = CameraUpdateFactory.newCameraPosition(CameraPosition.Builder().target(LatLng(view.lat, view.lon)).zoom(view.zoom).build())
            if (animationsOff()) {
                map.moveCamera(update)
                then()
                return
            }
            map.animateCamera(update, FLY_MS, object : MapLibreMap.CancelableCallback {
                override fun onFinish() = then()
                override fun onCancel() = Unit
            })
        }

        private fun pan(map: MapLibreMap, legs: List<Pair<Double, Double>>) {
            if (legs.isEmpty()) return
            val (lon, lat) = legs.first()
            val rest = legs.drop(1)
            val update = CameraUpdateFactory.newLatLng(LatLng(lat, lon))
            if (animationsOff()) {
                handler.postDelayed({
                    map.moveCamera(update)
                    pan(map, rest)
                }, PAN_LEG_MS.toLong())
                return
            }
            map.animateCamera(update, PAN_LEG_MS, object : MapLibreMap.CancelableCallback {
                override fun onFinish() = pan(map, rest)
                override fun onCancel() = Unit
            })
        }
    }

    private companion object {
        const val FLY_MS = 2000
        const val PAN_LEG_MS = 5000

        /** Each [TourStep.text] key's title and body. */
        val TEXT = mapOf(
            "tour_welcome" to (R.string.tour_welcome_title to R.string.tour_welcome_body),
            "tour_activities" to (R.string.tour_activities_title to R.string.tour_activities_body),
            "tour_range" to (R.string.tour_range_title to R.string.tour_range_body),
            "tour_stories" to (R.string.tour_stories_title to R.string.tour_stories_body),
            "tour_layers" to (R.string.tour_layers_title to R.string.tour_layers_body),
            "tour_export" to (R.string.tour_export_title to R.string.tour_export_body),
            "tour_fog" to (R.string.tour_fog_title to R.string.tour_fog_body),
            "tour_fog_city" to (R.string.tour_fog_title to R.string.tour_fog_city_body),
            "tour_fog_regions" to (R.string.tour_fog_regions_title to R.string.tour_fog_regions_body),
            "tour_fog_countries" to (R.string.tour_fog_countries_title to R.string.tour_fog_countries_body),
            "tour_heatmap" to (R.string.tour_heatmap_title to R.string.tour_heatmap_body),
            "tour_record" to (R.string.tour_record_title to R.string.tour_record_body),
            "tour_sync" to (R.string.tour_sync_title to R.string.tour_sync_body),
            "tour_sync_demo" to (R.string.tour_sync_title to R.string.tour_sync_demo_body),
            "tour_done" to (R.string.tour_done_title to R.string.tour_done_body),
        )
    }
}