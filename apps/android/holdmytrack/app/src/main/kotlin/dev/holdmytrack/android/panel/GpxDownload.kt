package dev.holdmytrack.android.panel

/** What kind of file Library's Download ([LibraryDownload]) saves. */
object GpxDownload {

    /** The MIME type the save screen offers [name] as: a zip of several tracks, or one GPX. */
    fun mimeType(name: String): String =
        if (name.endsWith(".zip", ignoreCase = true)) "application/zip" else "application/gpx+xml"
}
