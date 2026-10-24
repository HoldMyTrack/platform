package dev.holdmytrack.android.web

/**
 * Where a navigation in [WebPageActivity] goes, from the link's parts and the screen's state: the
 * decision half of its `route`, which acts on the answer. Both apps run
 * `testdata/client-rules/web-page-route.json`.
 */
object WebRoute {

    sealed interface Route {
        /** The page's own path: the WebView loads it. */
        data object Stay : Route

        /** Another origin, or another page of the site: a browser tab, or the app for its scheme. */
        data object Outside : Route

        /** The screen is already leaving: nothing more is done. */
        data object Ignore : Route

        /** The sign-in pages, or the plain map: the screen closes and the map's session check acts. */
        data object Close : Route

        /** The first run's save reached the map: the session is read before the map opens. */
        data object Onboarded : Route

        /** Sync history's View on map. */
        data class ViewOnMap(val activity: String, val day: String) : Route
    }

    /**
     * The route for a link of [scheme], [authority] and [path], with the map's [activity] and [day]
     * query parameters, against the API's [baseScheme] and [baseAuthority], on the screen showing
     * [page]. [leaving] is whether an earlier navigation already sent the user elsewhere.
     */
    fun of(
        scheme: String?,
        authority: String?,
        path: String?,
        activity: String?,
        day: String?,
        baseScheme: String?,
        baseAuthority: String?,
        page: String,
        leaving: Boolean,
        onboarding: Boolean,
    ): Route {
        if (scheme != baseScheme || authority != baseAuthority) return Route.Outside
        val at = path.orEmpty().ifEmpty { "/" }
        if (at == page) return Route.Stay
        if (leaving) return Route.Ignore
        return when (at) {
            "/signin", "/verify-pending" -> Route.Close
            "/" -> when {
                activity != null && day != null -> Route.ViewOnMap(activity, day)
                onboarding -> Route.Onboarded
                else -> Route.Close
            }
            else -> Route.Outside
        }
    }
}
