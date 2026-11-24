package dev.holdmytrack.android.web

/**
 * The decisions of Library's Download in the app ([WebPageActivity]): which ids the page may ask
 * for, and what kind of file comes back. The page hands the ids over through its bridge; the app
 * downloads them with its own session and asks where to save the file.
 */
object GpxDownload {

    /** Library's page size: Download takes at most one page of Checked tracks. */
    const val MAX_IDS = 100

    private val UUID = Regex("[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}")

    /** The track ids in the page's comma-separated [raw], or null when it isn't 1 to [MAX_IDS] of them. */
    fun ids(raw: String): List<String>? {
        val ids = raw.split(',').map { it.trim() }
        if (ids.size > MAX_IDS || ids.any { !UUID.matches(it) }) return null
        return ids
    }

    /** The MIME type the save screen offers [name] as: a zip of several tracks, or one GPX. */
    fun mimeType(name: String): String =
        if (name.endsWith(".zip", ignoreCase = true)) "application/zip" else "application/gpx+xml"
}
