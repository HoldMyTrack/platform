package dev.holdmytrack.android.profile

import java.time.LocalDate

/**
 * Which of the You tab's reads to make again (`YouFragment`); its Private locations are read on
 * every show, since the map's editor changes them. The numbers read every track day since 1970,
 * so they're read only when the tracks could have changed: the account's tile version moved (a
 * sync, an upload, a delete or an edit), the day turned, or they're older than [MAX_AGE_MS]. The
 * account changes on other screens (Settings, Profile), so it's read on every return to the app,
 * and on a tab switch once it's that old.
 */
object YouRefresh {

    /** When, and against what, the numbers were last read. */
    data class Mark(val atMs: Long, val tileVersion: String, val today: LocalDate)

    data class Reads(val account: Boolean, val numbers: Boolean)

    const val MAX_AGE_MS = 10 * 60_000L

    /** [numbers] is the last read of the numbers and [accountAtMs] of the account, null before
     *  the first; [resumed] is a return to the app or from another of its screens, as against a
     *  switch between tabs. */
    fun of(numbers: Mark?, accountAtMs: Long?, now: Mark, resumed: Boolean): Reads {
        val readNumbers = numbers == null || now.atMs - numbers.atMs >= MAX_AGE_MS ||
            now.tileVersion != numbers.tileVersion || now.today != numbers.today
        val readAccount = accountAtMs == null || resumed || now.atMs - accountAtMs >= MAX_AGE_MS
        return Reads(account = readAccount, numbers = readNumbers)
    }
}
