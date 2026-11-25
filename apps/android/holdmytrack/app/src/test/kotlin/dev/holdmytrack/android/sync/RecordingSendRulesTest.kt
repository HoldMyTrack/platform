package dev.holdmytrack.android.sync

import dev.holdmytrack.android.net.ApiException
import java.net.UnknownHostException
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
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
        assertEquals(listOf("c"), RecordingSendRules.toSend(keys, onItsWay = setOf("a"), hidden = emptySet(), held = emptySet(), refused = setOf("b"), retry = false))
        assertEquals(listOf("b", "c"), RecordingSendRules.toSend(keys, onItsWay = setOf("a"), hidden = emptySet(), held = emptySet(), refused = setOf("b"), retry = true))
    }

    @Test
    fun `one whose Delete is being asked about is never sent from under it`() {
        val sent = RecordingSendRules.toSend(listOf("a", "b"), onItsWay = emptySet(), hidden = emptySet(), held = setOf("a"), refused = emptySet(), retry = true)
        assertEquals(listOf("b"), sent)
    }

    @Test
    fun `Delete leaves one being sent or on its way`() {
        assertTrue(RecordingSendRules.deletable(sending = false, onItsWay = false))
        assertFalse(RecordingSendRules.deletable(sending = true, onItsWay = false))
        assertFalse(RecordingSendRules.deletable(sending = false, onItsWay = true))
    }

    @Test
    fun `one swiped aside is never sent or counted, and says nothing`() {
        val keys = listOf("a", "b")
        assertEquals(listOf("b"), RecordingSendRules.toSend(keys, onItsWay = emptySet(), hidden = setOf("a"), held = emptySet(), refused = emptySet(), retry = true))
        assertEquals(1, RecordingSendRules.unsent(keys, hidden = setOf("a")))
        assertNull(RecordingSendRules.note(sending = false, hidden = true, refusedReason = "too short"))
    }

    @Test
    fun `only a failure every recording would meet stops the send`() {
        fun http(code: Int) = RecordingSendRules.failure(ApiException(code, "why"))
        for (code in listOf(401, 403, 426, 429)) assertEquals(RecordingSendRules.Failure.STOP, http(code))
        for (code in listOf(400, 413)) assertEquals(RecordingSendRules.Failure.REFUSE, http(code))
        for (code in listOf(408, 500)) assertEquals(RecordingSendRules.Failure.NEXT, http(code))
        assertEquals(RecordingSendRules.Failure.STOP, RecordingSendRules.failure(UnknownHostException("offline")))
        assertEquals(RecordingSendRules.Failure.NEXT, RecordingSendRules.failure(IllegalArgumentException("unreadable")))
    }

    @Test
    fun `Retry shows while a real account has recordings not sent`() {
        assertTrue(RecordingSendRules.retryShown(demo = false, unsent = 2))
        assertFalse(RecordingSendRules.retryShown(demo = false, unsent = 0))
        assertFalse(RecordingSendRules.retryShown(demo = true, unsent = 2))
    }

    @Test
    fun `a row says it's going, refused with the reason, or waiting`() {
        assertEquals(RecordingSendRules.Note.Sending, RecordingSendRules.note(sending = true, hidden = false, refusedReason = "too short"))
        assertEquals(RecordingSendRules.Note.Refused("too short"), RecordingSendRules.note(sending = false, hidden = false, refusedReason = "too short"))
        assertEquals(RecordingSendRules.Note.Waiting, RecordingSendRules.note(sending = false, hidden = false, refusedReason = null))
    }
}
