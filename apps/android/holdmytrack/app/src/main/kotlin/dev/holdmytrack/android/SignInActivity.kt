package dev.holdmytrack.android

import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Bundle
import android.util.Log
import android.view.View
import android.widget.Button
import android.widget.EditText
import android.widget.TextView
import androidx.appcompat.app.AppCompatActivity
import androidx.browser.customtabs.CustomTabsIntent
import androidx.credentials.CredentialManager
import androidx.credentials.CustomCredential
import androidx.credentials.GetCredentialRequest
import androidx.credentials.exceptions.GetCredentialException
import androidx.lifecycle.lifecycleScope
import com.google.android.libraries.identity.googleid.GetSignInWithGoogleOption
import com.google.android.libraries.identity.googleid.GoogleIdTokenCredential
import com.google.android.libraries.identity.googleid.GoogleIdTokenParsingException
import dev.holdmytrack.android.net.Account
import dev.holdmytrack.android.net.FailureText
import dev.holdmytrack.android.net.HoldMyTrackApi
import dev.holdmytrack.android.net.Providers
import dev.holdmytrack.android.net.Session
import dev.holdmytrack.android.settings.AppLanguage
import java.security.MessageDigest
import java.security.SecureRandom
import java.time.ZoneId
import java.util.Base64
import kotlinx.coroutines.launch

/**
 * Sign in, start a demo account, or continue with Google or Facebook, when the server has them
 * configured (`docs/IMPLEMENTATION.md` §4.9). Creating an account opens the web's `/signup` in a
 * browser tab, so it passes that page's Turnstile check, and comes back here as Facebook does
 * ([OAuthRedirectActivity]), with the verifier this screen keeps.
 *
 * Designed as the web's sign-in page (`templates/pages/signin.html`): one card, the serif title
 * inside it, the providers, then the email form, then the demo — the layout carries all of
 * that, and this class only shows, hides and wires it.
 *
 * The app's first screen whenever no session is held, mirroring web's `AuthGate`: a bare
 * basemap with no tracks or fog is a weak demonstration of what HoldMyTrack does, and the
 * Demo button here is a much stronger one, one tap away. So `MainActivity` never mounts the map
 * without a session — it hands off to [open] instead — and this screen is the root of its own
 * task, with nothing behind it to fall back to: Back leaves the app rather than revealing a map
 * that would have nothing of the user's on it.
 */
class SignInActivity : AppCompatActivity() {

    private lateinit var email: EditText
    private lateinit var password: EditText
    private lateinit var error: TextView
    private lateinit var submit: Button
    private lateinit var signUp: Button
    private lateinit var forgot: Button
    private lateinit var demo: Button
    private lateinit var buttons: List<Button>
    private lateinit var google: Button
    private lateinit var facebook: Button
    private lateinit var providersDivider: View
    private var providers: Providers? = null

    /** A sign-up or Facebook browser tab is open and hasn't come back — so the buttons,
     *  disabled when it opened, come back on in [onResume] if it was simply closed. */
    private var awaitingBrowser = false

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContentView(R.layout.activity_sign_in)

        email = findViewById(R.id.email)
        password = findViewById(R.id.password)
        error = findViewById(R.id.error)
        intent.getIntExtra(EXTRA_NOTICE, 0).takeIf { it != 0 }?.let { res ->
            findViewById<TextView>(R.id.notice).apply {
                setText(res)
                visibility = View.VISIBLE
            }
        }
        submit = findViewById(R.id.submit)
        signUp = findViewById(R.id.sign_up)
        forgot = findViewById(R.id.forgot)
        demo = findViewById(R.id.demo)
        google = findViewById(R.id.google)
        facebook = findViewById(R.id.facebook)
        providersDivider = findViewById(R.id.providers_divider)
        buttons = listOf(submit, signUp, forgot, demo, google, facebook)

        submit.setOnClickListener { withCredentials(HoldMyTrackApi::signIn) }
        signUp.setOnClickListener { openBrowserRoundTrip(BrowserFlow.SIGN_UP, HoldMyTrackApi::signUpPageUri) }
        // The web's own /forgot, not a native form: the emailed reset link opens the web's
        // /reset page anyway, so the flow ends in the browser whichever way it starts.
        forgot.setOnClickListener {
            CustomTabsIntent.Builder().build().launchUrl(this, HoldMyTrackApi.webPageUri("/forgot"))
        }
        demo.setOnClickListener {
            setBusy(true)
            HoldMyTrackApi.startDemo(::onResult)
        }
        google.setOnClickListener { signInWithGoogle() }
        facebook.setOnClickListener {
            openBrowserRoundTrip(BrowserFlow.FACEBOOK) { challenge -> HoldMyTrackApi.facebookStartUri(timezone(), challenge) }
        }

        // Shown only once the server says it has them configured — the web's same rule. A
        // failure leaves them hidden: email and password still work, and a button that can
        // only fail is worse than none.
        HoldMyTrackApi.providers { result ->
            result.onSuccess { configured ->
                providers = configured
                google.visibility = if (configured.google && configured.googleClientId.isNotEmpty()) View.VISIBLE else View.GONE
                facebook.visibility = if (configured.facebook) View.VISIBLE else View.GONE
                providersDivider.visibility =
                    if (google.visibility == View.VISIBLE || facebook.visibility == View.VISIBLE) View.VISIBLE else View.GONE
            }
        }

        // Not on a recreation: the intent is the same one already handled before it.
        if (savedInstanceState == null) handleRedirect(intent)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        handleRedirect(intent)
    }

    override fun onResume() {
        super.onResume()
        if (awaitingBrowser) {
            awaitingBrowser = false
            setBusy(false)
        }
    }

    /**
     * Credential Manager's account picker, asked for an ID token for the server's web client
     * (the audience the server checks), carrying a nonce the server issued and spends on the
     * sign-in. Closing the picker is not an error, so it shows none.
     */
    private fun signInWithGoogle() {
        val clientId = providers?.googleClientId?.takeIf { it.isNotEmpty() } ?: return
        setBusy(true)
        HoldMyTrackApi.googleNonce { result ->
            if (isDestroyed) return@googleNonce
            result.onSuccess { nonce -> pickGoogleAccount(clientId, nonce) }
                .onFailure { googleFailed(it as? Exception ?: IllegalStateException(it)) }
        }
    }

    private fun pickGoogleAccount(clientId: String, nonce: String) {
        val request = GetCredentialRequest.Builder()
            .addCredentialOption(GetSignInWithGoogleOption.Builder(clientId).setNonce(nonce).build())
            .build()
        lifecycleScope.launch {
            try {
                val credential = CredentialManager.create(this@SignInActivity)
                    .getCredential(this@SignInActivity, request).credential
                if (credential is CustomCredential &&
                    credential.type == GoogleIdTokenCredential.TYPE_GOOGLE_ID_TOKEN_CREDENTIAL
                ) {
                    val idToken = GoogleIdTokenCredential.createFrom(credential.data).idToken
                    HoldMyTrackApi.signInWithGoogle(idToken, timezone(), ::onResult)
                } else {
                    googleFailed(IllegalStateException("unexpected credential type ${credential.type}"))
                }
            } catch (e: GetCredentialException) {
                when (GoogleFailure.of(e)) {
                    GoogleFailure.CANCELLED -> setBusy(false)
                    GoogleFailure.NO_ACCOUNT -> googleFailed(e, R.string.google_no_account)
                    GoogleFailure.FAILED -> googleFailed(e)
                }
            } catch (e: GoogleIdTokenParsingException) {
                googleFailed(e)
            }
        }
    }

    /** Logged because the usual cause in development is a missing Android OAuth client for
     *  this signing key in Google Cloud (`docs/DEPLOY.md`), which the picker reports as a
     *  generic failure or as no account to offer. */
    private fun googleFailed(cause: Exception, message: Int = R.string.google_failed) {
        Log.w(TAG, "google sign-in failed", cause)
        setBusy(false)
        showError(getString(message))
    }

    /**
     * One of the server's own pages that end in a handoff — the web's sign-up, or its Facebook
     * flow — in a browser tab, started with the S256 challenge of a fresh verifier, kept with [flow]
     * by [BrowserHandoff] for [handleRedirect] to read back when the tab returns.
     */
    private fun openBrowserRoundTrip(flow: BrowserFlow, start: (challenge: String) -> Uri) {
        val verifier = Base64.getUrlEncoder().withoutPadding()
            .encodeToString(ByteArray(32).also { SecureRandom().nextBytes(it) })
        val challenge = Base64.getUrlEncoder().withoutPadding()
            .encodeToString(MessageDigest.getInstance("SHA-256").digest(verifier.toByteArray(Charsets.US_ASCII)))
        BrowserHandoff.save(this, verifier, flow, System.currentTimeMillis())
        setBusy(true)
        awaitingBrowser = true
        CustomTabsIntent.Builder().build().launchUrl(this, start(challenge))
    }

    /**
     * Where a browser-tab round trip lands (`holdmytrack://oauth`, forwarded by
     * [OAuthRedirectActivity]): a one-time code to redeem with the stored verifier, or the
     * server's error code ([OAuthRedirectRule]). Only a code uses the verifier up: the link is
     * exported, so another app firing `?error=` must not end a sign-in still in the browser.
     */
    private fun handleRedirect(intent: Intent?) {
        val uri = intent?.data ?: return
        if (uri.scheme != OAuthRedirectActivity.SCHEME || uri.host != OAuthRedirectActivity.HOST) return
        val pending = BrowserHandoff.pending(this, System.currentTimeMillis())
        when (val rule = OAuthRedirectRule.of(uri.getQueryParameter("code"), uri.getQueryParameter("error"), pending != null)) {
            OAuthRedirectRule.Ignore -> return
            is OAuthRedirectRule.ShowError -> {
                awaitingBrowser = false
                setBusy(false)
                showError(getString(browserErrorMessage(BrowserFailure.of(pending?.flow, rule.error))))
            }
            is OAuthRedirectRule.Exchange -> {
                awaitingBrowser = false
                BrowserHandoff.clear(this)
                setBusy(true)
                HoldMyTrackApi.exchangeHandoff(rule.code, pending!!.verifier, ::onResult)
            }
        }
    }

    /** The web's own wording for the same codes (`/signin?error=…`). */
    private fun browserErrorMessage(failure: BrowserFailure): Int = when (failure) {
        BrowserFailure.FACEBOOK_NO_EMAIL -> R.string.facebook_no_email
        BrowserFailure.FACEBOOK_EMAIL_IN_USE -> R.string.facebook_email_in_use
        BrowserFailure.GOOGLE -> R.string.google_failed
        BrowserFailure.FACEBOOK -> R.string.facebook_failed
        BrowserFailure.SIGN_UP -> R.string.sign_up_failed
    }

    /** The device's IANA zone — what the web sends as `tz` — so a new account starts on it. */
    private fun timezone(): String = ZoneId.systemDefault().id

    /** Sends the fields, or says one is missing ([SignInFields]). */
    private fun withCredentials(request: (String, String, (Result<Account>) -> Unit) -> Unit) {
        when (val fields = SignInFields.of(email.text.toString(), password.text.toString())) {
            SignInFields.Missing -> showError(getString(R.string.credentials_required))
            is SignInFields.Submit -> {
                setBusy(true)
                request(fields.email, fields.password, ::onResult)
            }
        }
    }

    /** Destroyed by a rotation, as against left by the user: an answer landing after it still
     *  moves on, since the recreated screen knows nothing of the request. */
    private var recreated = false

    override fun onDestroy() {
        recreated = isChangingConfigurations
        super.onDestroy()
    }

    /** An answer that lands after a rotation still signs in and moves on, from the
     *  application's context, since both next screens start a new task; only this screen's
     *  views are left alone, as the recreated screen has its own. One that lands after the user
     *  left keeps the session and opens nothing. */
    private fun onResult(result: Result<Account>) {
        if (!isDestroyed) setBusy(false)
        result.onSuccess { account ->
            Session.start(account.token, account.profile)
            // The account's own language, if it has chosen one — before the next screen opens.
            AppLanguage.followAccount(applicationContext, account.profile.locale)
            if (isDestroyed && !recreated) return@onSuccess
            if (account.profile.emailVerified) {
                applicationContext.startActivity(
                    Intent(applicationContext, MainActivity::class.java)
                        .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TASK),
                )
            } else {
                VerifyEmailActivity.open(applicationContext)
            }
            finish()
        }.onFailure { failure ->
            if (!isDestroyed) showError(FailureText.of(failure, getString(R.string.sign_in_failed)))
        }
    }

    private fun setBusy(busy: Boolean) {
        buttons.forEach { it.isEnabled = !busy }
        if (busy) error.visibility = View.GONE
    }

    private fun showError(message: String) {
        error.text = message
        error.visibility = View.VISIBLE
    }

    companion object {
        private const val TAG = "SignInActivity"

        /** Replaces the whole back stack with this screen — used on a cold start with no
         *  session, when a stored token turns out to be revoked, and on sign-out (from Profile
         *  or from `VerifyEmailActivity`), so no screen
         *  that needs a session is ever left underneath it. */
        fun open(context: Context, notice: Int = 0) {
            context.startActivity(
                Intent(context, SignInActivity::class.java)
                    .putExtra(EXTRA_NOTICE, notice)
                    .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TASK),
            )
        }

        /** A string shown in a notice above the form — "Your account was deleted." */
        private const val EXTRA_NOTICE = "notice"
    }
}
