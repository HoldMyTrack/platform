package dev.holdmytrack.android.imports

/** What a read of the imports still running means for the files this phone uploaded
 *  (`testdata/client-rules/import-watch.json`). */
object ImportWatch {
    /** [landed]: one ended since, so the map is read again; [next]: what the next read is
     *  compared with; [again]: reading goes on. */
    data class Step(val landed: Boolean, val next: Int, val again: Boolean)

    /** [expected]: running at the last read, with the uploads accepted since; [running]: now. */
    fun step(expected: Int, running: Int): Step = Step(landed = running < expected, next = running, again = running > 0)
}
