package dev.holdmytrack.android.map

import java.util.WeakHashMap
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.jsonObject
import org.maplibre.android.maps.Style

/**
 * The served style's `metadata`, which carries the build it came from ([STYLE_BUILD]) and the
 * satellite lists ([MapSatellite]). `Style.json` serializes the whole document, a few hundred KB, so each
 * [Style] is parsed once and kept by weak reference: a reload replaces the [Style], and its entry
 * goes with it.
 */
object StyleMetadata {

    /** The key holding the build the style came from, which the layers document names too. */
    const val STYLE_BUILD = "holdmytrack:style-build"

    private val parsed = WeakHashMap<Style, JsonObject>()

    fun of(style: Style): JsonObject = parsed.getOrPut(style) { parse(style.json) }

    /** The build [style] came from, empty for one that names none. */
    fun build(style: Style): String = (of(style)[STYLE_BUILD] as? JsonPrimitive)?.content.orEmpty()

    /** [styleJson]'s metadata, empty for a style without any or one that doesn't parse. */
    fun parse(styleJson: String): JsonObject =
        runCatching { Json.parseToJsonElement(styleJson).jsonObject["metadata"]?.jsonObject }.getOrNull() ?: JsonObject(emptyMap())
}
