package dev.holdmytrack.android.imports

/**
 * Which of a set of picked files go to the server, and why the others don't: the same checks
 * as the web's upload (`services/server/internal/web/static/upload.js`), against the server's
 * limits (`docs/SPEC.md` FR-3.1), so a file it would refuse isn't sent first.
 */
data class UploadPlan(
    /** Indexes into the picked files, in their order. */
    val send: List<Int>,
    /** In the order they're shown: wrong kinds first, then too many, then each too large. */
    val refusals: List<Refusal>,
) {
    sealed interface Refusal {
        /** An archive: not imported (ADR-0039). */
        data class Zip(val name: String) : Refusal

        /** Not a `.gpx`, `.fit` or `.tcx`. */
        data class WrongType(val name: String) : Refusal

        /** More than [MAX_FILES] activity files at once: none of them is sent. */
        data class TooMany(val count: Int) : Refusal

        /** Past the server's size limit. */
        data class TooLarge(val name: String) : Refusal
    }

    /** A picked file, as far as the checks need it. */
    data class Picked(val name: String, val size: Long)

    companion object {
        /** The web's cap on files picked at once (`docs/SPEC.md` FR-3.1). */
        const val MAX_FILES = 20

        /** The server's limit (`services/server/internal/httpapi/server.go`'s maxUploadBytes). */
        const val MAX_FILE_BYTES = 16L shl 20

        private val ACCEPTED = Regex("""\.(gpx|fit|tcx)$""", RegexOption.IGNORE_CASE)
        private val ZIP = Regex("""\.zip$""", RegexOption.IGNORE_CASE)

        fun of(picked: List<Picked>): UploadPlan {
            val refusals = mutableListOf<Refusal>()
            for (file in picked) {
                if (ACCEPTED.containsMatchIn(file.name)) continue
                refusals += if (ZIP.containsMatchIn(file.name)) Refusal.Zip(file.name) else Refusal.WrongType(file.name)
            }
            var activityFiles = picked.indices.filter { ACCEPTED.containsMatchIn(picked[it].name) }
            if (activityFiles.size > MAX_FILES) {
                refusals += Refusal.TooMany(activityFiles.size)
                activityFiles = emptyList()
            }
            val send = mutableListOf<Int>()
            for (i in activityFiles) {
                if (picked[i].size > MAX_FILE_BYTES) refusals += Refusal.TooLarge(picked[i].name) else send += i
            }
            return UploadPlan(send, refusals)
        }
    }
}