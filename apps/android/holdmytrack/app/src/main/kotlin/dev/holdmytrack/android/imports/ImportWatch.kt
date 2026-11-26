package dev.holdmytrack.android.imports

/** What a read of the imports still running means for the files this phone uploaded
 *  (`testdata/client-rules/import-watch.json`, `import-retry.json`). */
object ImportWatch {
    /** [landed]: one ended since, so the map is read again; [next]: what the next read is
     *  compared with; [again]: reading goes on. */
    data class Step(val landed: Boolean, val next: Int, val again: Boolean)

    /** [expected]: running at the last read, with the uploads accepted since; [running]: now;
     *  [acceptedSince]: accepted while this read was out, which it can't have seen. */
    fun step(expected: Int, running: Int, acceptedSince: Int): Step {
        val next = running + acceptedSince
        return Step(landed = running < expected - acceptedSince, next = next, again = next > 0)
    }

    /** Seconds to wait after [failures] failed reads in a row, or null to give up. */
    fun delay(failures: Int): Int? = if (failures >= GIVE_UP) null else minOf(2 shl failures, MAX_DELAY)

    private const val GIVE_UP = 8
    private const val MAX_DELAY = 60
}
