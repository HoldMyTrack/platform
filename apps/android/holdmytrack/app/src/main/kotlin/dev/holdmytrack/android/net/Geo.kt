package dev.holdmytrack.android.net

/** A position in degrees. MapLibre's own `LatLng` is an Android class; this one keeps the
 *  geometry that uses it (`map/SpotGeometry`) testable on the JVM. */
data class GeoPoint(val lat: Double, val lon: Double)

/** A spot's area as `GET /v2/spots/{id}` sends it: polygons, each an outer ring then its holes,
 *  each ring closed (first point repeated last). */
typealias SpotArea = List<List<List<GeoPoint>>>
