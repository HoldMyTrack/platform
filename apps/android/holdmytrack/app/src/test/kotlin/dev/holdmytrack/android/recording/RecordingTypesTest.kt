package dev.holdmytrack.android.recording

import org.junit.Assert.assertEquals
import org.junit.Test

/** What the Type picker lists: the account's types and the waiting recordings', most used first. */
class RecordingTypesTest {

    @Test
    fun `server and waiting recordings count together, most used first, then the presets`() {
        val known = RecordingTypes.known(mapOf("walking" to 3, "kayaking" to 1), listOf("walking", "kayaking", "kayaking"))
        assertEquals(
            listOf(
                TypeCount("walking", 4),
                TypeCount("kayaking", 3),
                TypeCount("hiking", 0),
                TypeCount("running", 0),
                TypeCount("cycling", 0),
                TypeCount("driving", 0),
            ),
            known,
        )
    }

    @Test
    fun `the no-type placeholder isn't offered`() {
        val known = RecordingTypes.known(mapOf(RecordingTypes.DEFAULT to 5), listOf(RecordingTypes.DEFAULT))
        assertEquals(RecordingTypes.PRESETS.map { TypeCount(it, 0) }, known)
    }
}
