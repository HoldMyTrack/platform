package dev.holdmytrack.android

/**
 * Which launches of [MainActivity] may steer it. The activity is exported for the launcher, so any
 * app can start it with extras; the app's own launches go through the unexported alias [ALIAS]
 * instead, and only those keep their tab, View on map, Private location or Stop.
 */
object MainEntry {

    /** The manifest's unexported `activity-alias` of [MainActivity]. */
    const val ALIAS = "dev.holdmytrack.android.MainFromApp"

    /** Whether a launch addressed to [component] (the intent's class name) came from this app. */
    fun fromApp(component: String?): Boolean = component == ALIAS
}
