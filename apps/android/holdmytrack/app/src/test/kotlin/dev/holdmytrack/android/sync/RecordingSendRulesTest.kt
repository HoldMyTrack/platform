package dev.holdmytrack.android.sync

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Test

/** What the shared cases (`testdata/client-rules/recording-send-*.json`) don't say of sending recordings. */
class RecordingSendRulesTest {

    @Test
    fun `nothing is sent signed out`() {
        assertFalse(RecordingSendRules.sends(signedIn = false, emailVerified = true, demo = false))
    }

    @Test
    fun `a refused row carries the reason`() {
        assertEquals(
            RecordingSendRules.Note.Refused("too short"),
            RecordingSendRules.note(sent = false, sending = false, hidden = false, refusedReason = "too short", demo = false),
        )
    }
}
