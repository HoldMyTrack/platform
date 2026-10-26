package dev.holdmytrack.android.tour

import dev.holdmytrack.android.R

/** Each [TourStep.text] and [TourSteps.card] key's title and body string. */
object TourText {
    val ALL: Map<String, Pair<Int, Int>> = mapOf(
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

    fun of(key: String): Pair<Int, Int> = ALL.getValue(key)
}
