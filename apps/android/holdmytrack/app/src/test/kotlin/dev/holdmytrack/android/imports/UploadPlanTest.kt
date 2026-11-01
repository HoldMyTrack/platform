package dev.holdmytrack.android.imports

import dev.holdmytrack.android.imports.UploadPlan.Picked
import dev.holdmytrack.android.imports.UploadPlan.Refusal
import org.junit.Assert.assertEquals
import org.junit.Test

/** Which picked files are sent (`docs/SPEC.md` FR-3.1). */
class UploadPlanTest {

    private fun file(name: String, size: Long = 1_000) = Picked(name, size)

    @Test
    fun `activity files go, in order, whatever their extension's case`() {
        val plan = UploadPlan.of(listOf(file("a.gpx"), file("b.FIT"), file("c.Tcx")))
        assertEquals(listOf(0, 1, 2), plan.send)
        assertEquals(emptyList<Refusal>(), plan.refusals)
    }

    @Test
    fun `an archive and any other kind are named, and the rest still go`() {
        val plan = UploadPlan.of(listOf(file("trip.zip"), file("a.gpx"), file("notes.txt"), file("gpx")))
        assertEquals(listOf(1), plan.send)
        assertEquals(listOf(Refusal.Zip("trip.zip"), Refusal.WrongType("notes.txt"), Refusal.WrongType("gpx")), plan.refusals)
    }

    @Test
    fun `more activity files than the cap sends none of them`() {
        val picked = (1..UploadPlan.MAX_FILES + 1).map { file("$it.gpx") } + file("x.zip")
        val plan = UploadPlan.of(picked)
        assertEquals(emptyList<Int>(), plan.send)
        assertEquals(listOf(Refusal.Zip("x.zip"), Refusal.TooMany(UploadPlan.MAX_FILES + 1)), plan.refusals)
    }

    @Test
    fun `exactly the cap goes`() {
        assertEquals(UploadPlan.MAX_FILES, UploadPlan.of((1..UploadPlan.MAX_FILES).map { file("$it.fit") }).send.size)
    }

    @Test
    fun `a file past the server's limit is named, the limit itself still goes`() {
        val plan = UploadPlan.of(listOf(file("big.fit", UploadPlan.MAX_FILE_BYTES + 1), file("edge.fit", UploadPlan.MAX_FILE_BYTES)))
        assertEquals(listOf(1), plan.send)
        assertEquals(listOf(Refusal.TooLarge("big.fit")), plan.refusals)
    }
}