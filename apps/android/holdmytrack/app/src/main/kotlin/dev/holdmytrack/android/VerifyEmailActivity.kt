package dev.holdmytrack.android

import android.content.Context
import android.content.Intent
import android.graphics.Typeface
import android.os.Bundle
import android.text.SpannableString
import android.text.Spanned
import android.text.style.StyleSpan
import android.view.View
import android.view.inputmethod.EditorInfo
import android.widget.Button
import android.widget.EditText
import android.widget.TextView
import androidx.appcompat.app.AppCompatActivity
import dev.holdmytrack.android.net.ApiException
import dev.holdmytrack.android.net.HoldMyTrackApi
import dev.holdmytrack.android.net.Session

/**
 * "Check your email" — what a signed-in account whose address isn't confirmed yet sees instead
 * of the map, the app's counterpart of the web's `/verify-pending`. The server answers every
 * tile and sync request of such an account with `403 email_not_verified` (`requireVerified`,
 * `services/server/internal/httpapi/auth_session.go`), so the map would open with nothing on it and
 * nothing on screen saying why.
 *
 * The email's 6-digit code is typed here and confirms the address in this session, which stays
 * signed in. Its link, opened in a browser, signs the app out instead, and the app never hears
 * about it, so this screen asks `GET /v2/auth/me` again on every resume and on Confirm with the
 * field empty ([VerifyAction]). Resend and Sign out are the web page's other ways forward;
 * changing a mistyped address stays on the web, since the app's local recordings and hidden Sync
 * rows are keyed by the email and would be orphaned.
 *
 * The root of its own task like [SignInActivity]: Back leaves the app rather than revealing a
 * map this account can't load yet.
 */
class VerifyEmailActivity : AppCompatActivity() {

    private lateinit var notice: TextView
    private lateinit var error: TextView
    private lateinit var code: EditText
    private lateinit var buttons: List<Button>

    /** Guards against a second `GET /v2/auth/me` while one is in flight. */
    private var checking = false

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        if (!Session.isSignedIn) {
            SignInActivity.open(this)
            finish()
            return
        }
        setContentView(R.layout.activity_verify_email)

        findViewById<TextView>(R.id.verify_hint).text = hint(Session.email)
        notice = findViewById(R.id.verify_notice)
        error = findViewById(R.id.verify_error)
        code = findViewById(R.id.verify_code)
        val proceed: Button = findViewById(R.id.verify_continue)
        val resend: Button = findViewById(R.id.verify_resend)
        val signOut: Button = findViewById(R.id.verify_sign_out)
        buttons = listOf(proceed, resend, signOut)

        proceed.setOnClickListener { confirm() }
        code.setOnEditorActionListener { _, actionId, _ ->
            if (actionId != EditorInfo.IME_ACTION_DONE) return@setOnEditorActionListener false
            confirm()
            true
        }
        resend.setOnClickListener { resend() }
        signOut.setOnClickListener {
            setBusy(true)
            HoldMyTrackApi.signOut { SignInActivity.open(this) }
        }
    }

    override fun onResume() {
        super.onResume()
        if (Session.isSignedIn) check(userAsked = false)
    }

    private fun confirm() {
        if (busy) return
        when (val action = VerifyAction.of(code.text.toString())) {
            VerifyAction.Check -> check(userAsked = true)
            is VerifyAction.Submit -> submit(action.code)
        }
    }

    /** The server's wording for a code it refuses: wrong, used up, expired. */
    private fun submit(typed: String) {
        setBusy(true)
        HoldMyTrackApi.verifyCode(typed) { result ->
            setBusy(false)
            result.onSuccess { profile ->
                Session.markVerified(profile)
                openMap()
            }.onFailure { failure ->
                if (failure is ApiException && failure.code == 401) {
                    Session.clear()
                    SignInActivity.open(this)
                    finish()
                } else {
                    show(failure.message.orEmpty(), failed = true)
                }
            }
        }
    }

    private fun openMap() {
        startActivity(
            Intent(this, MainActivity::class.java)
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TASK),
        )
        finish()
    }

    /**
     * Confirmed → the map. A `401` means the session itself is gone, as on the map. Anything
     * else is reported only when the user asked, via Continue — the automatic check on resume
     * stays quiet, since the screen already says what to do.
     */
    private fun check(userAsked: Boolean) {
        if (checking) return
        checking = true
        if (userAsked) setBusy(true)
        HoldMyTrackApi.verifySession { result ->
            checking = false
            setBusy(false)
            result.onSuccess { profile ->
                Session.markVerified(profile)
                if (profile.emailVerified) {
                    openMap()
                } else if (userAsked) {
                    show(getString(R.string.verify_email_not_yet), failed = false)
                }
            }.onFailure { failure ->
                if (failure is ApiException && failure.code == 401) {
                    Session.clear()
                    SignInActivity.open(this)
                    finish()
                } else if (userAsked) {
                    show(getString(R.string.verify_email_check_failed, failure.message.orEmpty()), failed = true)
                }
            }
        }
    }

    /** The server's own wording either way: its confirmation, or its refusal (rate limit). */
    private fun resend() {
        setBusy(true)
        HoldMyTrackApi.resendVerification { result ->
            setBusy(false)
            result.onSuccess { text -> show(text, failed = false) }
                .onFailure { failure -> show(failure.message.orEmpty(), failed = true) }
        }
    }

    /** A request is in flight: Confirm, its keyboard action and the buttons wait for it. */
    private var busy = false

    private fun setBusy(busy: Boolean) {
        this.busy = busy
        buttons.forEach { it.isEnabled = !busy }
        if (busy) {
            notice.visibility = View.GONE
            error.visibility = View.GONE
        }
    }

    /** A notice for what the server confirmed or reported, the error box for a failure — the
     *  web page's `.auth-card__notice` and `__error`. */
    private fun show(text: String, failed: Boolean) {
        val (shown, hidden) = if (failed) error to notice else notice to error
        shown.text = text
        shown.visibility = View.VISIBLE
        hidden.visibility = View.GONE
    }

    /** The hint with the address in bold, as the web's `<strong>` sets it off. */
    private fun hint(email: String): CharSequence {
        val text = getString(R.string.verify_email_hint, email)
        val start = text.indexOf(email)
        if (email.isEmpty() || start < 0) return text
        return SpannableString(text).apply {
            setSpan(StyleSpan(Typeface.BOLD), start, start + email.length, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
        }
    }

    companion object {
        /** Replaces the whole back stack with this screen, as [SignInActivity.open] does. */
        fun open(context: Context) {
            context.startActivity(
                Intent(context, VerifyEmailActivity::class.java)
                    .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TASK),
            )
        }
    }
}
