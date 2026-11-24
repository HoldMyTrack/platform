package dev.holdmytrack.android.panel

import org.junit.Assert.assertEquals
import org.junit.Test

class GpxDownloadTest {

    @Test
    fun `a zip is saved as a zip, anything else as GPX`() {
        assertEquals("application/zip", GpxDownload.mimeType("tracks.ZIP"))
        assertEquals("application/gpx+xml", GpxDownload.mimeType("2026-05-01 Ride.gpx"))
    }
}
