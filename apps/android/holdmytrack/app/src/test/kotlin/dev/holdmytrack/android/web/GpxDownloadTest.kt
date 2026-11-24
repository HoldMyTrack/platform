package dev.holdmytrack.android.web

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class GpxDownloadTest {

    private val a = "8f1c2d3e-0000-4000-8000-000000000001"
    private val b = "8f1c2d3e-0000-4000-8000-000000000002"

    @Test
    fun `ids are one page of track ids`() {
        assertEquals(listOf(a, b), GpxDownload.ids("$a,$b"))
        assertEquals(listOf(a), GpxDownload.ids(" $a "))
        assertNull(GpxDownload.ids(""))
        assertNull(GpxDownload.ids("$a,../x"))
        assertNull(GpxDownload.ids(List(GpxDownload.MAX_IDS + 1) { a }.joinToString(",")))
    }

    @Test
    fun `a zip is saved as a zip, anything else as GPX`() {
        assertEquals("application/zip", GpxDownload.mimeType("tracks.ZIP"))
        assertEquals("application/gpx+xml", GpxDownload.mimeType("2026-05-01 Ride.gpx"))
    }
}
