package dev.holdmytrack.android.recording

import android.Manifest

/** What a tap on the record button does. */
sealed interface RecordTap {
    data object Pause : RecordTap
    data object Resume : RecordTap
    data object Start : RecordTap
    data class AskPermissions(val missing: List<String>) : RecordTap
}

object RecordTapRules {
    /** Idle starts, once [missing] permissions are granted; recording pauses; paused resumes.
     *  A tap never stops: that takes a two-second hold. */
    fun tap(state: RecordingState, missing: List<String>): RecordTap = when (state) {
        RecordingState.RECORDING -> RecordTap.Pause
        RecordingState.PAUSED -> RecordTap.Resume
        RecordingState.IDLE -> if (missing.isEmpty()) RecordTap.Start else RecordTap.AskPermissions(request(missing))
    }

    /** What to ask Android for [missing]: precise location goes with approximate, since Android
     *  ignores a request for precise alone, and only the pair lets someone who granted
     *  approximate for Locate upgrade it. */
    fun request(missing: List<String>): List<String> =
        missing.flatMap { if (it == Manifest.permission.ACCESS_FINE_LOCATION) listOf(it, Manifest.permission.ACCESS_COARSE_LOCATION) else listOf(it) }

    /** The notification's Stop applies unless the app was relaunched from recents, whose replayed
     *  intent would stop a recording started since. */
    fun stopIntentApplies(isStopAction: Boolean, launchedFromHistory: Boolean): Boolean = isStopAction && !launchedFromHistory
}
