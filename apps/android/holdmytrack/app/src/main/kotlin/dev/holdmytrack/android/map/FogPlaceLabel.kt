package dev.holdmytrack.android.map

/**
 * What Fog's place popup says about an outline a tap picked ([FogPlaces]), the web's
 * `fogPlaceLabel.ts`: from the outline's tile feature (`internal/httpapi`'s `adminLayer.tileQuery`)
 * its name, kind, the places it lies in, whether it's explored, and how many of each level below
 * it the account has explored. Catalog keys are the web's, which [FogWords] maps to resources.
 * Shared cases: `testdata/client-rules/fog-place-label.json`.
 */
object FogPlaceLabel {

    /** Of a level below the place, how many of its places in it the account has been in out of
     *  [total], and the plural catalog key naming them in its country's words. */
    data class Count(val key: String, val explored: Int, val total: Int)

    data class Label(
        val name: String,
        val kindKey: String,
        /** The places it lies in, nearest first, or "" for a country. */
        val within: String,
        val visitedKey: String,
        /** Coarsest level first; empty for a city or a stand-in. */
        val counts: List<Count>,
    )

    /** The levels a place counts below it: the tile's columns, and the column naming them in its
     *  country's words, else what they're called anywhere. */
    private val COUNTED = listOf(
        Triple("regions", "region_word", "region"),
        Triple("counties", "county_word", "county"),
        Triple("cities", null, "city"),
    )

    private val KINDS = setOf("country", "region", "county", "city")

    /**
     * The label for an outline's [props], or null for the sea or a feature it can't name. [has] is
     * whether the catalog has a key: the kind is the place's own, as its country files it
     * (Overture's local_type), where there's a word for it, else the level's.
     */
    fun of(props: Map<String, Any?>, has: (String) -> Boolean): Label? {
        val kind = props["kind"] as? String
        val name = props["name"] as? String
        if (kind == null || kind !in KINDS || name.isNullOrEmpty()) return null
        val own = (props["type"] as? String)?.let { "map.fog.type.$it" }
        // A boolean in the tile; a JSON round trip can make it a string.
        val visited = props["visited"] == true || props["visited"] == "true"
        return Label(
            name = name,
            kindKey = own?.takeIf(has) ?: "map.fog.place.$kind",
            within = props["within"] as? String ?: "",
            visitedKey = if (visited) "map.fog.place.visited" else "map.fog.place.unvisited",
            counts = COUNTED.mapNotNull { (level, wordColumn, generic) ->
                val explored = (props[level] as? Number)?.toInt() ?: return@mapNotNull null
                val total = (props["${level}_total"] as? Number)?.toInt() ?: return@mapNotNull null
                if (total <= 0) return@mapNotNull null
                val word = wordColumn?.let { props[it] as? String }?.takeIf { it.isNotEmpty() }
                val ownKey = word?.let { "map.fog.count.$it" }?.takeIf { has("$it.other") }
                Count(ownKey ?: "map.fog.count.$generic", explored, total)
            },
        )
    }
}