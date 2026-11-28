package dev.holdmytrack.android.flows

import android.text.method.PasswordTransformationMethod
import android.widget.EditText
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.runner.lifecycle.ActivityLifecycleMonitorRegistry
import androidx.test.runner.lifecycle.Stage
import androidx.test.uiautomator.By
import androidx.test.uiautomator.BySelector
import androidx.test.uiautomator.Direction
import androidx.test.uiautomator.Until
import dev.holdmytrack.android.BuildConfig
import dev.holdmytrack.android.R
import dev.holdmytrack.android.SignInActivity
import dev.holdmytrack.android.net.Session
import org.junit.AfterClass
import org.junit.Before
import org.junit.BeforeClass
import org.junit.Test
import org.junit.runner.RunWith
import java.util.UUID

/**
 * Sign in and the session (`apps/docs/SPEC.md` FR-1.1–FR-1.3), as [MapFlowsTest] runs its flows:
 * the sign-in screen with no session, the demo kept across a new start and signed out, a refused
 * sign-in showing the server's message, and a second sign-in opening on the account's tracks.
 * One fresh account ([TestAccount]) serves the class.
 */
@RunWith(AndroidJUnit4::class)
class SessionFlowsTest {

    /** No session opens Sign in, whose only check is that neither field is empty; the password's
     *  toggle shows what was typed and hides it again, keeping it. */
    @Test
    fun withNoSessionTheAppOpensOnSignIn() {
        signedOut()
        need(id("email").enabled(true))
        need(id("password"))
        need(id("demo"))
        need(By.text(context.getString(R.string.sign_in_or)))
        tapUntil({ still(id("submit")) }) { device.hasObject(id("error")) }
        expect("the empty fields' message", need(id("error")).text == context.getString(R.string.credentials_required))

        need(id("password")).text = "abcd"
        val toggle = By.res(PACKAGE, "text_input_end_icon")
        expect("hidden", waitUntil { passwordHidden() == true })
        retrying { need(toggle).click() }
        expect("shown as plain text", waitUntil { passwordHidden() == false })
        retrying { need(toggle).click() }
        expect("hidden again", waitUntil { passwordHidden() == true })
        expect("nothing typed was lost", need(id("password")).text == "abcd")
    }

    /** The demo signs in; a new start of the app's screen keeps the session, read back from the
     *  phone's store, and opens the map; Sign out returns to Sign in. */
    @Test
    fun theDemoSignsInAndSignOutReturnsToSignIn() {
        signedOut()
        tapAway(id("demo"))
        need(id("panel_handle"))

        // The tests run in the app's process, which can't be restarted: the session is read back
        // from the phone's store, as a new process reads it, and the app's screen starts afresh.
        instrumentation.runOnMainSync { Session.init(context) }
        start()
        need(id("panel_handle"))
        expect("the session kept", !device.hasObject(id("email")))
        openYou()
        scrollTo(id("you_version"))
        expect("the build's version", need(id("you_version")).text.contains(BuildConfig.VERSION_NAME))
        signOut()
        need(id("email").enabled(true))
    }

    /** A refused sign-in shows the server's message as sent. */
    @Test
    fun theServersMessageShowsAsSent() {
        signedOut()
        need(id("email").enabled(true)).text = "nobody-${UUID.randomUUID().toString().take(8)}@example.com"
        need(id("password")).text = "wrong-password"
        tapUntil({ still(id("submit")) }) { device.hasObject(id("error")) }
        val message = need(id("error")).text
        val own = listOf(R.string.credentials_required, R.string.sign_in_failed).map(context::getString)
        expect("the server's message, not the app's: $message", message.isNotBlank() && message !in own)
        expect("still on Sign in", device.hasObject(id("email")))
    }

    /** The map opens on the account's tracks on every sign-in, the same account's second too. */
    @Test
    fun aSecondSignInOpensOnTheTracks() {
        signIn(account)
        expandSheet()
        expect("the account's tracks", device.wait(Until.hasObject(id("track_text")), TIMEOUT_MS))

        openYou()
        signOut()
        need(id("email").enabled(true)).text = account.email
        need(id("password")).text = account.password
        tapAway(id("submit"))
        expandSheet()
        expect("the camera is on the tracks, so the area lists them", device.wait(Until.hasObject(id("track_text")), TIMEOUT_MS))
    }

    /** Whether Sign in's password field hides what's typed, read in the app: UI Automator reads
     *  a hidden field's text as typed. Null while Sign in isn't showing. */
    private fun passwordHidden(): Boolean? {
        var hidden: Boolean? = null
        instrumentation.runOnMainSync {
            val screen = ActivityLifecycleMonitorRegistry.getInstance().getActivitiesInStage(Stage.RESUMED)
                .filterIsInstance<SignInActivity>().singleOrNull() ?: return@runOnMainSync
            hidden = screen.findViewById<EditText>(R.id.password).transformationMethod is PasswordTransformationMethod
        }
        return hidden
    }

    /** Opens the app with no session, on Sign in. */
    private fun signedOut() {
        instrumentation.runOnMainSync { Session.clear() }
        start()
        need(id("email"))
    }

    private fun openYou() {
        tapUntil({ still(id("nav_you")) }) { device.hasObject(id("you_privacy")) }
    }

    /** You's Sign out, scrolled to: it sits at the page's foot. */
    private fun signOut() {
        scrollTo(id("you_sign_out"))
        tapUntil({ still(id("you_sign_out")) }) { device.hasObject(id("email")) }
    }

    private fun scrollTo(selector: BySelector) {
        repeat(5) {
            if (device.hasObject(selector)) return
            device.findObject(By.scrollable(true))?.scroll(Direction.DOWN, 1f)
        }
        need(selector)
    }

    @Before
    fun wake() = wakeDevice()

    private companion object {
        lateinit var account: TestAccount

        @BeforeClass
        @JvmStatic
        fun createAccount() {
            prepareDevice()
            account = TestAccount.create()
        }

        @AfterClass
        @JvmStatic
        fun deleteAccount() {
            restoreDevice()
            if (::account.isInitialized) account.delete()
        }
    }
}
