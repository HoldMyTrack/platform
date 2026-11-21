package dev.holdmytrack.android.recording

import java.text.Normalizer

/** The Type picker's search (`testdata/client-rules/type-search.json`), the web's `pickerSearch.ts`. */
object TypeSearch {

    /** A type as the picker lists it: the raw `track_type` and its label. */
    data class Option(val value: String, val label: String)

    /** The options shown, and the text offered as a new type, if any. */
    data class Result(val shown: List<Option>, val add: String?)

    /** A blank [query] lists [options] as given. Otherwise an exact label comes first, then a
     *  label or one of its words starting with the query, then a label or raw value containing
     *  it, keeping [options]' order within each rank; the trimmed query is offered as [Result.add]
     *  while no option's label or value equals it and it fits [maxLength]. */
    fun search(options: List<Option>, query: String, maxLength: Int): Result {
        val text = query.trim()
        if (text.isEmpty()) return Result(options, null)
        val q = fold(text)
        val ranked = List(3) { mutableListOf<Option>() }
        for (o in options) {
            val label = fold(o.label)
            when {
                label == q -> ranked[0] += o
                label.startsWith(q) || label.contains(" $q") -> ranked[1] += o
                label.contains(q) || fold(o.value).contains(q) -> ranked[2] += o
            }
        }
        val exact = options.any { fold(it.value) == q || fold(it.label) == q }
        return Result(ranked.flatten(), text.takeIf { !exact && codePoints(it) <= maxLength })
    }

    /** The rows for [known] in its order, led by [current] with count 0 when none of them is it, so
     *  the current choice is always listed (`testdata/client-rules/type-options.json`). An empty
     *  [current], a mixed group's, adds nothing. */
    fun options(current: String, known: List<TypeCount>): List<TypeCount> =
        if (current.isEmpty() || known.any { it.type == current }) known else listOf(TypeCount(current, 0)) + known

    /** Case- and accent-insensitive: every nonspacing mark goes. */
    fun fold(s: String): String =
        Normalizer.normalize(s.lowercase(), Normalizer.Form.NFD).replace(Regex("\\p{Mn}+"), "")

    /** A string's length as the server counts it, in code points. */
    fun codePoints(s: String): Int = s.codePointCount(0, s.length)
}