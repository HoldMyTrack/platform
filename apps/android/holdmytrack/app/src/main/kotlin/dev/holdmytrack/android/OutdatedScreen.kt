package dev.holdmytrack.android

/**
 * When the Update screen opens ([AppOutdated]), as values. Android drops an activity started
 * from the background, so a refusal that arrives while no screen of the app is in front (an
 * upload or a poll still running) waits for the next one to come to the front.
 */
data class OutdatedScreen(
    /** The server has refused this build since the Update screen was last closed. */
    val refused: Boolean = false,
    /** The Update screen has been started, or is up. */
    val showing: Boolean = false,
) {
    /** What happened, and whether to start the Update screen now. */
    data class Step(val state: OutdatedScreen, val open: Boolean)

    /** A refused call; [inFront] is whether a screen of the app is in front to open it over. */
    fun refusedWhile(inFront: Boolean): Step =
        if (!showing && inFront) Step(OutdatedScreen(refused = true, showing = true), open = true)
        else Step(copy(refused = true), open = false)

    /** A screen of the app came to the front: a refusal still waiting opens the Update screen. */
    fun cameToFront(isUpdateScreen: Boolean): Step = when {
        isUpdateScreen -> Step(copy(showing = true), open = false)
        refused && !showing -> Step(copy(showing = true), open = true)
        else -> Step(this, open = false)
    }

    /** The Update screen closed: the next refusal opens it again. */
    fun closed(): OutdatedScreen = OutdatedScreen()
}
