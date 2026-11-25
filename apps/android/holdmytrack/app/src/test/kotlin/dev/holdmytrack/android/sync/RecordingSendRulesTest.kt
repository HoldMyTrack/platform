package dev.holdmytrack.android.sync

import dev.holdmytrack.android.net.ApiException
import java.net.SocketTimeoutException
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
        assertEquals(listOf("c"), RecordingSendRules.toSend(keys, onItsWay = setOf("a"), hidden = emptySet(), held = emptySet(), refused = setOf("b"), unanswered = emptyList(), retry = false))
        assertEquals(listOf("b", "c"), RecordingSendRules.toSend(keys, onItsWay = setOf("a"), hidden = emptySet(), held = emptySet(), refused = setOf("b"), unanswered = emptyList(), retry = true))
    }

    @Test
    fun `one whose Delete is being asked about is never sent from under it`() {
        val sent = RecordingSendRules.toSend(listOf("a", "b"), onItsWay = emptySet(), hidden = emptySet(), held = setOf("a"), refused = emptySet(), unanswered = emptyList(), retry = true)
        assertEquals(listOf("b"), sent)
    }

    @Test
    fun `Delete leaves one being sent or on its way, and says one landed`() {
        assertEquals(RecordingSendRules.Deletion.DELETED, RecordingSendRules.deletion(stored = true, going = false))
        assertEquals(RecordingSendRules.Deletion.SENDING, RecordingSendRules.deletion(stored = true, going = true))
        assertEquals(RecordingSendRules.Deletion.LANDED, RecordingSendRules.deletion(stored = false, going = false))
    }

    @Test
    fun `one swiped aside is never sent or counted, and says nothing`() {
        val keys = listOf("a", "b")
        assertEquals(listOf("b"), RecordingSendRules.toSend(keys, onItsWay = emptySet(), hidden = setOf("a"), held = emptySet(), refused = emptySet(), unanswered = emptyList(), retry = true))
        assertEquals(1, RecordingSendRules.unsent(keys, hidden = setOf("a")))
        assertNull(RecordingSendRules.note(sending = false, hidden = true, refusedReason = "too short"))
    }

    @Test
    fun `only a failure every recording would meet stops the send`() {
        fun http(code: Int) = RecordingSendRules.failure(ApiException(code, "why"), afterUnanswered = false)
        for (code in listOf(401, 403, 404, 421, 426, 429, 503)) assertEquals(RecordingSendRules.Failure.STOP, http(code))
        for (code in listOf(400, 413, 422)) assertEquals(RecordingSendRules.Failure.REFUSE, http(code))
        assertEquals(RecordingSendRules.Failure.NEXT, http(500))
        assertEquals(RecordingSendRules.Failure.NEXT, RecordingSendRules.failure(IllegalArgumentException("unreadable"), afterUnanswered = true))
    }

    @Test
    fun `one request with no answer may be the recording's, two in a row are the connection's`() {
        for (e in listOf(SocketTimeoutException(), ApiException(408, ""), ApiException(502, ""), ApiException(504, ""))) {
            assertTrue(RecordingSendRules.unanswered(e))
            assertEquals(RecordingSendRules.Failure.NEXT, RecordingSendRules.failure(e, afterUnanswered = false))
            assertEquals(RecordingSendRules.Failure.STOP, RecordingSendRules.failure(e, afterUnanswered = true))
        }
        assertFalse(RecordingSendRules.unanswered(ApiException(500, "")))
        assertFalse(RecordingSendRules.unanswered(IllegalArgumentException("unreadable")))
    }

    @Test
    fun `what got no answer goes last, the latest last`() {
        fun order(unanswered: List<String>) = RecordingSendRules.toSend(
            listOf("a", "b", "c"), onItsWay = emptySet(), hidden = emptySet(), held = emptySet(), refused = emptySet(), unanswered = unanswered, retry = false,
        )
        assertEquals(listOf("b", "c", "a"), order(listOf("a")))
        assertEquals(listOf("b", "c", "a"), order(listOf("c", "a")))
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
