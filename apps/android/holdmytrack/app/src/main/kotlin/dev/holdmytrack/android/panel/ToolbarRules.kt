package dev.holdmytrack.android.panel

/** Which of the Activities toolbar's actions apply, and the master checkbox's state. */
object ToolbarRules {

    /** Why an action can or can't be used. */
    enum class Use { READY, NO_TARGET, DEMO, PENDING }

    data class Actions(val visibility: Use, val edit: Use, val addToStory: Use, val delete: Use, val focus: Use)

    /**
     * The actions over [targets]. The demo account looks but can't change (the server's
     * `requireNotDemo`), and a pending row can't be deleted until its reprocess lands, since the
     * job would race the delete. Showing, hiding and flying to a target change nothing on the server.
     */
    fun actions(targets: Int, anyPending: Boolean, demo: Boolean): Actions {
        val look = if (targets == 0) Use.NO_TARGET else Use.READY
        val change = when {
            demo -> Use.DEMO
            targets == 0 -> Use.NO_TARGET
            else -> Use.READY
        }
        val delete = if (change == Use.READY && anyPending) Use.PENDING else change
        return Actions(visibility = look, edit = change, addToStory = change, delete = delete, focus = look)
    }

    enum class CheckAll { NONE, SOME, ALL }

    /** The master checkbox over [listed] rows, [checked] of them checked. */
    fun checkAll(listed: Int, checked: Int): CheckAll = when {
        listed > 0 && checked == listed -> CheckAll.ALL
        checked > 0 -> CheckAll.SOME
        else -> CheckAll.NONE
    }
}
