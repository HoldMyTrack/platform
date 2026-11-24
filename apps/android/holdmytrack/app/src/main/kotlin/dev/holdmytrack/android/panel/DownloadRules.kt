package dev.holdmytrack.android.panel

/**
 * Whether the Tracks panel's Download (root `docs/SPEC.md` FR-5.14) can take its target, so it
 * says why before a request the server would refuse. The web's
 * `apps/web/src/ui/downloadTarget.ts`; both run `testdata/client-rules/download-block.json`.
 */
object DownloadRules {

    /** The most tracks one download takes: Library's page size. */
    const val MAX_TRACKS = 100

    sealed interface Block {
        data class TooMany(val count: Int) : Block

        data class Pending(val id: String) : Block

        data class Private(val id: String) : Block
    }

    /** Ids in order with whether each is Pending and entirely inside Private locations. */
    data class Target(val id: String, val pending: Boolean, val private: Boolean)

    /** Why [target] can't be downloaded, or null when it can: more than [max] tracks, else the
     *  first Pending one, else the first entirely inside Private locations. Checked in the panel
     *  can pass [max] while the map pans. */
    fun block(target: List<Target>, max: Int = MAX_TRACKS): Block? {
        if (target.size > max) return Block.TooMany(target.size)
        target.firstOrNull { it.pending }?.let { return Block.Pending(it.id) }
        target.firstOrNull { it.private }?.let { return Block.Private(it.id) }
        return null
    }
}
