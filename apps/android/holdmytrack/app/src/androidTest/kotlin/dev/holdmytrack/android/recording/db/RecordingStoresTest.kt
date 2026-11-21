package dev.holdmytrack.android.recording.db

import android.content.Context
import android.database.sqlite.SQLiteConstraintException
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import dev.holdmytrack.android.recording.RecordedPoint
import java.time.Instant
import java.util.UUID
import kotlinx.coroutines.runBlocking
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith

/**
 * The phone's copy of a recording: the journal that outlives a process death, and the store
 * that holds a stopped recording until the server has it (`apps/android/docs/IMPLEMENTATION.md`
 * §5, `apps/android/docs/SPEC.md` FR-5.1 and FR-5.3). On a device, since both are SQLite
 * through Android's API; each test opens a throwaway file, never the app's own.
 */
@RunWith(AndroidJUnit4::class)
class RecordingStoresTest {

    private val context: Context = InstrumentationRegistry.getInstrumentation().targetContext
    private val file = "recording-stores-test-${UUID.randomUUID()}.db"
    private lateinit var helper: RecordingDbHelper
    private lateinit var journal: LiveRecordingJournal

    private var signedIn = ""
    private fun store() = RecordedTrackStore(helper) { signedIn }

    @Before
    fun open() {
        helper = RecordingDbHelper(context, file)
        journal = LiveRecordingJournal(helper)
    }

    @After
    fun delete() {
        helper.close()
        context.deleteDatabase(file)
    }

    private fun point(seq: Int, elevation: Float? = 200f) =
        RecordedPoint(lat = 41.3 + seq / 10_000.0, lon = -81.5, elevationM = elevation, time = Instant.ofEpochSecond(1_790_000_000L + seq * 3))

    private fun record(id: String, points: List<RecordedPoint> = listOf(point(0), point(1)), startedAtMs: Long = 1_790_000_000_000) =
        RecordedTrackRecord(
            id = id, name = "", description = "", trackType = "walk", startedAtMs = startedAtMs,
            distanceMeters = 12.0, durationSeconds = 90, points = points, createdAtMs = startedAtMs,
        )

    @Test
    fun aRecordingInProgressComesBackWhole() {
        journal.begin("r", "a@x")
        journal.append("r", 0, point(0), movingMs = 1_000, distanceM = 0.0)
        journal.append("r", 1, point(1, elevation = null), movingMs = 4_000, distanceM = 11.0)
        journal.updateTotals("r", movingMs = 9_000, distanceM = 11.0) // a pause

        val left = journal.leftover()!!
        assertEquals(LiveRecordingJournal.Leftover("r", "a@x", 9_000, 11.0, listOf(point(0), point(1, elevation = null))), left)
    }

    @Test
    fun stopMovesTheRecordingIntoTheStoreUnderItsOwnAccount() = runBlocking {
        journal.begin("r", "a@x")
        journal.append("r", 0, point(0), 1_000, 0.0)
        journal.append("r", 1, point(1), 65_000, 12.0)

        signedIn = "b@x" // saved from a leftover while someone else is signed in
        journal.finish("r", record("r"), "a@x")

        assertNull(journal.leftover())
        assertTrue(store().all().isEmpty())
        signedIn = "a@x"
        assertEquals(listOf(record("r")), store().all())
    }

    @Test
    fun aStopWhoseSaveFailsLeavesTheRecordingInTheJournal() = runBlocking {
        signedIn = "a@x"
        store().insert(record("r")) // the save will collide with this row
        journal.begin("r", "a@x")
        journal.append("r", 0, point(0), 1_000, 0.0)

        assertThrows(SQLiteConstraintException::class.java) { journal.finish("r", record("r"), "a@x") }

        // Never in neither place: the journal still holds it, to be offered again.
        assertEquals("r", journal.leftover()?.id)
        assertEquals(1, journal.leftover()?.points?.size)
    }

    @Test
    fun aRecordingTooShortToKeepLeavesNothing() = runBlocking {
        journal.begin("r", "a@x")
        journal.append("r", 0, point(0), 1_000, 0.0)
        journal.finish("r", null, "a@x")

        assertNull(journal.leftover())
        signedIn = "a@x"
        assertTrue(store().all().isEmpty())
    }

    @Test
    fun aDeletedAccountsJournalGoesAndNoOneElses() {
        journal.begin("r", "a@x")
        journal.append("r", 0, point(0), 1_000, 0.0)

        journal.clear("b@x")
        assertEquals("r", journal.leftover()?.id)
        journal.clear("a@x")
        assertNull(journal.leftover())
    }

    @Test
    fun oneAccountNeverSeesOrChangesAnothersRecordings() = runBlocking {
        signedIn = "a@x"
        store().insert(record("a1"))
        signedIn = "b@x"
        store().insert(record("b1"))

        signedIn = "a@x"
        assertEquals(listOf("a1"), store().all().map { it.id })
        assertNull(store().get("b1"))
        assertNull(store().header("b1"))
        store().update(record("b1").copy(name = "renamed by a"))
        store().markSent("b1")
        store().delete("b1")
        store().deleteAll()
        assertTrue(store().all().isEmpty())

        signedIn = "b@x"
        assertEquals(listOf(record("b1")), store().all())
        assertTrue(store().sent().isEmpty())
    }

    @Test
    fun aSentRecordingWaitsApartUntilItsIngestLandsOrFails() = runBlocking {
        signedIn = "a@x"
        store().insert(record("r"))
        store().markSent("r")
        assertTrue(store().all().isEmpty())
        assertEquals(listOf("r"), store().sent().map { it.id })

        store().unmarkSent("r") // the ingest failed: waiting to be sent again
        assertEquals(listOf("r"), store().all().map { it.id })
        assertTrue(store().sent().isEmpty())

        store().markSent("r")
        store().delete("r") // landed
        assertTrue(store().sent().isEmpty())
        assertNull(store().get("r"))
    }

    @Test
    fun theWaitingListIsNewestFirst() = runBlocking {
        signedIn = "a@x"
        store().insert(record("older", startedAtMs = 1_000))
        store().insert(record("newer", startedAtMs = 2_000))
        assertEquals(listOf("newer", "older"), store().all().map { it.id })
    }

    /** A day of fixes every 3 seconds, past what one `points_json` value could hold. */
    @Test
    fun aLongRecordingsPointsComeBackInOrder() = runBlocking {
        signedIn = "a@x"
        val points = List(28_800) { point(it) }
        store().insert(record("long", points))

        assertEquals(points, store().get("long")!!.points)
        assertTrue(store().header("long")!!.points.isEmpty())
    }
}
