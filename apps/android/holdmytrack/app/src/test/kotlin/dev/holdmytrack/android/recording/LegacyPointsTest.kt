package dev.holdmytrack.android.recording

import dev.holdmytrack.android.recording.db.LegacyPoints
import java.time.Instant
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/** Version 7's migration never replaces a recording's only copy with nothing. */
class LegacyPointsTest {

    @Test
    fun `points move with their elevation and time`() {
        val json = """[{"lat":59.43,"lon":24.75,"elevation_m":12.5,"time":"2026-11-01T08:00:00Z"},{"lat":59.44,"lon":24.76,"time":"2026-11-01T08:00:03Z"}]"""
        assertEquals(
            listOf(
                RecordedPoint(59.43, 24.75, 12.5f, Instant.parse("2026-11-01T08:00:00Z")),
                RecordedPoint(59.44, 24.76, null, Instant.parse("2026-11-01T08:00:03Z")),
            ),
            LegacyPoints.parse(json),
        )
    }

    @Test
    fun `a recording past the old 2 MB row limit moves whole`() {
        val json = (0 until 30_000).joinToString(",", "[", "]") { """{"lat":59.0,"lon":24.0,"time":"2026-11-01T08:00:00Z"}""" }
        assertEquals(30_000, LegacyPoints.parse(json)?.size)
    }

    @Test
    fun `points already moved are left alone`() {
        assertNull(LegacyPoints.parse(LegacyPoints.MOVED))
    }

    @Test
    fun `an unreadable value is kept rather than emptied`() {
        assertNull(LegacyPoints.parse("""[{"lat":59.43,"lon":24.75,"time":"2026-11"""))
        assertNull(LegacyPoints.parse("""[{"lat":59.43}]"""))
        assertNull(LegacyPoints.parse(""))
    }
}
