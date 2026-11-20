package dev.holdmytrack.android.photos

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class PhotoRefreshTest {

    @Test
    fun `the same scope isn't read again unless forced`() {
        assertFalse(PhotoRefresh.fetches("track:a", "track:a", force = false, owed = false))
        assertTrue(PhotoRefresh.fetches("track:a", "track:a", force = true, owed = false))
    }

    @Test
    fun `a new scope is read`() {
        assertTrue(PhotoRefresh.fetches("track:b", "track:a", force = false, owed = false))
        assertTrue(PhotoRefresh.fetches(null, "track:a", force = false, owed = false))
    }

    @Test
    fun `a forced refresh with no view is owed to the next one, which reads the same scope`() {
        val owed = PhotoRefresh.owedWithoutView(force = true, owed = false)
        assertTrue(owed)
        assertTrue(PhotoRefresh.fetches("track:a", "track:a", force = false, owed = owed))
    }

    @Test
    fun `an unforced refresh with no view owes nothing, and keeps what's owed`() {
        assertFalse(PhotoRefresh.owedWithoutView(force = false, owed = false))
        assertTrue(PhotoRefresh.owedWithoutView(force = false, owed = true))
    }

    @Test
    fun `fetched photos go to a window showing the track they were fetched for`() {
        assertTrue(PhotoRefresh.deliversTo("a", "a"))
    }

    @Test
    fun `nor to one showing another track, a group, or one fetched for no single track`() {
        assertFalse(PhotoRefresh.deliversTo("a", "b"))
        assertFalse(PhotoRefresh.deliversTo("a", null))
        assertFalse(PhotoRefresh.deliversTo(null, null))
    }
}
