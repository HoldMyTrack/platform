package dev.holdmytrack.android.net

import okhttp3.HttpUrl

/** Which requests are HoldMyTrack's own, and so get the session token and the app's headers. */
object ApiOrigin {

    /**
     * Whether [url] is bound for the API at [apiBase]: the same scheme, host and port, and a path
     * at or under the base's. Compared as parsed URLs: a string prefix of the base also matches
     * `https://holdmytrack.app.evil.tld/` and `https://holdmytrack.app@evil.tld/`, and MapLibre
     * fetches whatever URLs the style document names.
     */
    fun isApi(url: HttpUrl, apiBase: HttpUrl): Boolean {
        if (url.scheme != apiBase.scheme || url.host != apiBase.host || url.port != apiBase.port) return false
        val basePath = apiBase.encodedPath.trimEnd('/')
        return basePath.isEmpty() || url.encodedPath == basePath || url.encodedPath.startsWith("$basePath/")
    }
}