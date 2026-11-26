package dev.holdmytrack.android.imports

/** What an uploaded file's state means for the phone that sent it, and how long the watch waits
 *  (`testdata/client-rules/upload-watch.json`, `import-retry.json`). */
object ImportWatch {
    /** [landed]: the map and Library catch up; [done]: the file is no longer watched. */
    data class Step(val landed: Boolean, val done: Boolean)

    /** [status]: `GET /v2/uploads/{external_id}`'s; only processing is watched on. */
    fun step(status: String): Step = Step(landed = status == "done", done = status != "processing")

    /** Seconds to wait after [failures] rounds in a row with a failed read, [watched] seconds
     *  after the watch started, or null to give up. */
    fun delay(failures: Int, watched: Long): Int? =
        if (failures >= GIVE_UP || watched >= MAX_WATCH) null else minOf(2 shl failures, MAX_DELAY)

    private const val GIVE_UP = 8
    private const val MAX_DELAY = 60
    private const val MAX_WATCH = 600L
}
