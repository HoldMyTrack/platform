package dev.holdmytrack.android.sync

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class RecordingSendRulesTest {

    @Test
    fun `only a verified, real account sends`() {
        assertTrue(RecordingSendRules.sends(signedIn = true, emailVerified = true, demo = false))
        assertFalse(RecordingSendRules.sends(signedIn = true, emailVerified = true, demo = true))
        assertFalse(RecordingSendRules.sends(signedIn = true, emailVerified = false, demo = false))
        assertFalse(RecordingSendRules.sends(signedIn = false, emailVerified = true, demo = false))
    }

    @Test
    fun `what's on its way is never sent twice, and a refusal only on Retry`() {
        val keys = listOf("a", "b", "c")
        assertEquals(listOf("c"), RecordingSendRules.toSend(keys, onItsWay = setOf("a"), refused = setOf("b"), retry = false))
        assertEquals(listOf("b", "c"), RecordingSendRules.toSend(keys, onItsWay = setOf("a"), refused = setOf("b"), retry = true))
    }

    @Test
    fun `Retry shows while a real account has recordings not sent`() {
        assertTrue(RecordingSendRules.retryShown(demo = false, unsent = 2))
        assertFalse(RecordingSendRules.retryShown(demo = false, unsent = 0))
        assertFalse(RecordingSendRules.retryShown(demo = true, unsent = 2))
    }

    @Test
    fun `a row says it's going, refused with the reason, or waiting`() {
        assertEquals(RecordingSendRules.Note.Sending, RecordingSendRules.note(sending = true, refusedReason = "too short"))
        assertEquals(RecordingSendRules.Note.Refused("too short"), RecordingSendRules.note(sending = false, refusedReason = "too short"))
        assertEquals(RecordingSendRules.Note.Waiting, RecordingSendRules.note(sending = false, refusedReason = null))
    }
}
