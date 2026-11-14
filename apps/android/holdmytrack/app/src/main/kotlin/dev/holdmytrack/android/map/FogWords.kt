package dev.holdmytrack.android.map

import dev.holdmytrack.android.R

/**
 * The web's Fog catalog keys as this app's resources, for Fog's level menu ([FogLevelMenu]) and
 * place popup ([FogPlaces]): what a country calls its places (`map.fog.type.*`, Overture's
 * local_type), the levels' generic kinds (`map.fog.place.*`) and the counts below a place
 * (`map.fog.count.*`, plurals). A key with no resource is one the catalog doesn't have.
 */
object FogWords {

    /** The string naming a kind of place, Overture's local_type, or null for one with no word. */
    fun type(word: String): Int? = TYPES[word]

    /** Whether the catalog has [key], as the web's `hasKey`: a plural is had by its `.other` form. */
    fun has(key: String): Boolean =
        string(key) != null || (key.endsWith(OTHER) && plural(key.removeSuffix(OTHER)) != null)

    /** The string for a `map.fog.type.*` or `map.fog.place.*` key. */
    fun string(key: String): Int? = when {
        key.startsWith(TYPE) -> TYPES[key.removePrefix(TYPE)]
        key.startsWith(PLACE) -> PLACES[key.removePrefix(PLACE)]
        else -> null
    }

    /** The plurals for a `map.fog.count.*` key. */
    fun plural(key: String): Int? = if (key.startsWith(COUNT)) COUNTS[key.removePrefix(COUNT)] else null

    private const val TYPE = "map.fog.type."
    private const val PLACE = "map.fog.place."
    private const val COUNT = "map.fog.count."
    private const val OTHER = ".other"

    private val PLACES: Map<String, Int> = mapOf(
        "city" to R.string.fog_place_city,
        "country" to R.string.fog_place_country,
        "county" to R.string.fog_place_county,
        "region" to R.string.fog_place_region,
        "unvisited" to R.string.fog_place_unvisited,
        "visited" to R.string.fog_place_visited,
    )

    private val TYPES: Map<String, Int> = mapOf(
        "allotments" to R.string.fog_type_allotments,
        "archipelago" to R.string.fog_type_archipelago,
        "area" to R.string.fog_type_area,
        "atoll" to R.string.fog_type_atoll,
        "canton" to R.string.fog_type_canton,
        "cercle" to R.string.fog_type_cercle,
        "city" to R.string.fog_type_city,
        "civil_parish" to R.string.fog_type_civil_parish,
        "commune" to R.string.fog_type_commune,
        "community" to R.string.fog_type_community,
        "constituency" to R.string.fog_type_constituency,
        "council" to R.string.fog_type_council,
        "country" to R.string.fog_type_country,
        "county" to R.string.fog_type_county,
        "department" to R.string.fog_type_department,
        "district" to R.string.fog_type_district,
        "division" to R.string.fog_type_division,
        "emirate" to R.string.fog_type_emirate,
        "entity" to R.string.fog_type_entity,
        "federal subject" to R.string.fog_type_federal_subject,
        "governorate" to R.string.fog_type_governorate,
        "hamlet" to R.string.fog_type_hamlet,
        "industrial" to R.string.fog_type_industrial,
        "island" to R.string.fog_type_island,
        "islet" to R.string.fog_type_islet,
        "isolated_dwelling" to R.string.fog_type_isolated_dwelling,
        "locality" to R.string.fog_type_locality,
        "municipal_federation" to R.string.fog_type_municipal_federation,
        "municipality" to R.string.fog_type_municipality,
        "parish" to R.string.fog_type_parish,
        "prefecture" to R.string.fog_type_prefecture,
        "province" to R.string.fog_type_province,
        "regency" to R.string.fog_type_regency,
        "region" to R.string.fog_type_region,
        "sector" to R.string.fog_type_sector,
        "state" to R.string.fog_type_state,
        "subcounty" to R.string.fog_type_subcounty,
        "subdistrict" to R.string.fog_type_subdistrict,
        "subprefecture" to R.string.fog_type_subprefecture,
        "subregion" to R.string.fog_type_subregion,
        "suburb" to R.string.fog_type_suburb,
        "territory" to R.string.fog_type_territory,
        "town" to R.string.fog_type_town,
        "township" to R.string.fog_type_township,
        "village" to R.string.fog_type_village,
        "zone" to R.string.fog_type_zone
    )

    private val COUNTS: Map<String, Int> = mapOf(
        "allotments" to R.plurals.fog_count_allotments,
        "archipelago" to R.plurals.fog_count_archipelago,
        "area" to R.plurals.fog_count_area,
        "atoll" to R.plurals.fog_count_atoll,
        "canton" to R.plurals.fog_count_canton,
        "cercle" to R.plurals.fog_count_cercle,
        "city" to R.plurals.fog_count_city,
        "civil_parish" to R.plurals.fog_count_civil_parish,
        "commune" to R.plurals.fog_count_commune,
        "community" to R.plurals.fog_count_community,
        "constituency" to R.plurals.fog_count_constituency,
        "council" to R.plurals.fog_count_council,
        "country" to R.plurals.fog_count_country,
        "county" to R.plurals.fog_count_county,
        "department" to R.plurals.fog_count_department,
        "district" to R.plurals.fog_count_district,
        "division" to R.plurals.fog_count_division,
        "emirate" to R.plurals.fog_count_emirate,
        "entity" to R.plurals.fog_count_entity,
        "federal subject" to R.plurals.fog_count_federal_subject,
        "governorate" to R.plurals.fog_count_governorate,
        "hamlet" to R.plurals.fog_count_hamlet,
        "industrial" to R.plurals.fog_count_industrial,
        "island" to R.plurals.fog_count_island,
        "islet" to R.plurals.fog_count_islet,
        "isolated_dwelling" to R.plurals.fog_count_isolated_dwelling,
        "locality" to R.plurals.fog_count_locality,
        "municipal_federation" to R.plurals.fog_count_municipal_federation,
        "municipality" to R.plurals.fog_count_municipality,
        "parish" to R.plurals.fog_count_parish,
        "prefecture" to R.plurals.fog_count_prefecture,
        "province" to R.plurals.fog_count_province,
        "regency" to R.plurals.fog_count_regency,
        "region" to R.plurals.fog_count_region,
        "sector" to R.plurals.fog_count_sector,
        "state" to R.plurals.fog_count_state,
        "subcounty" to R.plurals.fog_count_subcounty,
        "subdistrict" to R.plurals.fog_count_subdistrict,
        "subprefecture" to R.plurals.fog_count_subprefecture,
        "subregion" to R.plurals.fog_count_subregion,
        "suburb" to R.plurals.fog_count_suburb,
        "territory" to R.plurals.fog_count_territory,
        "town" to R.plurals.fog_count_town,
        "township" to R.plurals.fog_count_township,
        "village" to R.plurals.fog_count_village,
        "zone" to R.plurals.fog_count_zone
    )
}
