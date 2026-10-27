package dev.holdmytrack.android.map

import dev.holdmytrack.android.net.TrackMetricPoint
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test
import org.maplibre.geojson.LineString

/** The selected activity's route, which the layers document's direction arrows ride (`docs/SPEC.md` FR-4.8). */
class RouteFeatureTest {

    private fun point(lon: Double) = TrackMetricPoint(lon, 0.0, 1.0)

    @Test
    fun theWholeRouteInRecordingOrder() {
        val route = MapOverlays.routeFeature(listOf(point(0.0), point(1.0), point(2.0)))!!
        assertEquals(true, route.getBooleanProperty("route"))
        assertEquals(listOf(0.0, 1.0, 2.0), (route.geometry() as LineString).coordinates().map { it.longitude() })
    }

    @Test
    fun noRouteForATrackTooShortToHaveADirection() {
        assertNull(MapOverlays.routeFeature(listOf(point(0.0))))
    }
}
