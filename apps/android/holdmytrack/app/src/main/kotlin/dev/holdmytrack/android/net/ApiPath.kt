package dev.holdmytrack.android.net

import okhttp3.HttpUrl

/**
 * A `/v2` URL on the API with each segment encoded on its own, so an id can't add a segment, a
 * query or a fragment to the path it is put in.
 */
object ApiPath {

    fun v2(base: HttpUrl, vararg segments: String): HttpUrl =
        base.newBuilder().addPathSegment("v2").apply { segments.forEach(::addPathSegment) }.build()
}
