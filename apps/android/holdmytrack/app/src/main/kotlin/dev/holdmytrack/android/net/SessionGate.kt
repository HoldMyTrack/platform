package dev.holdmytrack.android.net

import android.content.Context
import android.util.Log
import androidx.fragment.app.Fragment
import dev.holdmytrack.android.R
import dev.holdmytrack.android.SignInActivity
import dev.holdmytrack.android.VerifyEmailActivity
import dev.holdmytrack.android.map.MapNotice
import dev.holdmytrack.android.map.NoticePanel
import dev.holdmytrack.android.settings.AppLanguage
import dev.holdmytrack.android.web.WebPageActivity

/**
 * Whether the map may show the user's layers: a session, confirmed by the server, with a
 * confirmed email and a Country. No session goes to `SignInActivity`.
 *
 * A token restored from disk isn't trusted until the server confirms it: a revoked one would
 * otherwise show as a blank map, its 401s visible only in logcat. An unconfirmed email goes to
 * `VerifyEmailActivity`, since every tile and sync request would be a `403`.
 */
class SessionGate(
    private val fragment: Fragment,
    private val notices: NoticePanel,
    /** The check answered: run [passes] again. */
    private val onChecked: () -> Unit,
) {
    /** Guards against a second check while one is in flight; every `onResume` asks. */
    private var verifying = false

    /** Posted when a check starts, so "Checking your session…" appears only if the check is slow
     *  enough to notice; removed when it answers. */
    private val showChecking = Runnable {
        notices.show(MapNotice.CHECKING, fragment.getString(R.string.checking_session))
    }

    /** True when the map may go on; otherwise the user is sent where they need to go, or the
     *  check runs and [onChecked] follows. */
    fun passes(): Boolean {
        when (SessionRoute.of(Session.isSignedIn, Session.verified, Session.emailVerified, Session.isDemo, Session.country)) {
            SessionRoute.SIGN_IN -> leaveFor { SignInActivity.open(it) }
            SessionRoute.VERIFY -> verify()
            SessionRoute.VERIFY_EMAIL -> leaveFor { VerifyEmailActivity.open(it) }
            SessionRoute.ONBOARDING -> leaveFor { WebPageActivity.openOnboarding(it) }
            SessionRoute.MAP -> return true
        }
        return false
    }

    /** Whether the fragment can still act on an answer: a rotation or Back while the check runs
     *  destroys it, and its replacement runs a check of its own on resume. */
    private val attached: Boolean
        get() = fragment.isAdded && fragment.view != null

    private fun leaveFor(open: (Context) -> Unit) {
        open(fragment.requireContext())
        fragment.requireActivity().finish()
    }

    private fun verify() {
        if (verifying) return
        verifying = true
        val app = fragment.requireContext().applicationContext
        notices.view.postDelayed(showChecking, CHECKING_DELAY_MS)
        HoldMyTrackApi.verifySession { result ->
            verifying = false
            notices.view.removeCallbacks(showChecking)
            // The session's state is kept either way; only the screen's part waits for a fragment
            // still attached.
            result.onSuccess { profile ->
                Session.markVerified(profile)
                AppLanguage.followAccount(app, profile.locale)
            }.onFailure { failure ->
                // Only a 401 means the token is dead. Any other failure keeps it for the next
                // resume, and the notice says why the map is empty.
                if (failure is ApiException && failure.code == 401) Session.clear()
            }
            if (!attached) return@verifySession
            notices.hide(MapNotice.CHECKING)
            result.onSuccess {
                notices.hide(MapNotice.UNREACHABLE)
            }.onFailure { failure ->
                if (failure !is ApiException || failure.code != 401) {
                    Log.w(TAG, "could not verify the stored session", failure)
                    notices.show(
                        MapNotice.UNREACHABLE,
                        fragment.getString(R.string.map_unreachable),
                        failed = true,
                        action = R.string.retry,
                    ) { verify() }
                }
            }
            onChecked()
        }
    }

    private companion object {
        const val TAG = "HoldMyTrack"

        /** How long a check runs before the notice shows, so a fast one doesn't flash it. */
        const val CHECKING_DELAY_MS = 600L
    }
}
