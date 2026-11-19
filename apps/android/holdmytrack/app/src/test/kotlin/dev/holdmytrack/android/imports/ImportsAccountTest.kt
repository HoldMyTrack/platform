package dev.holdmytrack.android.imports

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** One account's uploads never go out under another (`apps/android/docs/SPEC.md` FR-3.6). */
class ImportsAccountTest {

    @Test
    fun `the account that queued the files keeps them`() {
        assertTrue(ImportsAccount.keeps("a@example.com", "a@example.com"))
    }

    @Test
    fun `an empty queue belongs to whoever is signed in`() {
        assertTrue(ImportsAccount.keeps(null, "b@example.com"))
        assertTrue(ImportsAccount.keeps(null, null))
    }

    @Test
    fun `another account, or a sign-out, drops them`() {
        assertFalse(ImportsAccount.keeps("a@example.com", "b@example.com"))
        assertFalse(ImportsAccount.keeps("a@example.com", null))
    }

    @Test
    fun `a file still going reports to the account it went for`() {
        assertTrue(ImportsAccount.reports("a@example.com", "a@example.com"))
    }

    @Test
    fun `a file still going after a sign-out reports to no one`() {
        assertFalse(ImportsAccount.reports("a@example.com", null))
        assertFalse(ImportsAccount.reports("a@example.com", "b@example.com"))
        assertFalse(ImportsAccount.reports(null, null))
    }
}
