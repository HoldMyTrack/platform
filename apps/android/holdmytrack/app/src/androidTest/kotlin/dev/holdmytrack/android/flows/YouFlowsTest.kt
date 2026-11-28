package dev.holdmytrack.android.flows

import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.runner.lifecycle.ActivityLifecycleMonitorRegistry
import androidx.test.runner.lifecycle.Stage
import androidx.test.uiautomator.By
import androidx.test.uiautomator.Direction
import androidx.test.uiautomator.Until
import dev.holdmytrack.android.MainActivity
import dev.holdmytrack.android.R
import dev.holdmytrack.android.web.WebPageActivity
import org.junit.After
import org.junit.Before
import org.junit.BeforeClass
import org.junit.AfterClass
import org.junit.Test
import org.junit.runner.RunWith
import java.util.regex.Pattern

/**
 * The You tab and the site's pages in the app (`apps/docs/SPEC.md` FR-1.5, FR-1.7, FR-2.9), as
 * [MapFlowsTest] runs its flows: Settings signed in, the first run waiting on Settings, You's
 * rows and Privacy, and Delete account signing out. Each flow has an account of its own with no
 * tracks: one is deleted, one has no Country.
 */
@RunWith(AndroidJUnit4::class)
class YouFlowsTest {

    private var account: TestAccount? = null

    /** A fresh account for this flow, deleted after it. */
    private fun account(country: Boolean = true): TestAccount =
        TestAccount.create(tracks = false, country = country).also { account = it }

    /** The account's card opens Settings signed in: the account's own page, not the site's
     *  sign-in form. Back closes it. */
    @Test
    fun settingsOpensSignedInAndCloses() {
        signIn(account())
        openYou()
        // The page's screen in front: its web view isn't listed by its id once the page has loaded.
        tapUntil({ still(id("you_account")) }) { resumedActivity() is WebPageActivity }
        expect("the account's Settings", device.wait(Until.hasObject(By.text(COUNTRY)), TIMEOUT_MS))
        expect("not the sign-in form", !device.hasObject(By.text(context.getString(R.string.sign_in))))
        device.pressBack()
        expect("back on You", device.wait(Until.hasObject(id("you_account")), TIMEOUT_MS))
    }

    /** A verified account with no Country opens on Settings, with no map behind it. Saving
     *  reaches the map only where the API is APP_BASE_URL's origin, which the stock dev stack's
     *  isn't (`docs/DEVELOPMENT.md`), so the save itself isn't driven here. */
    @Test
    fun aFirstRunWaitsOnSettings() {
        val account = account(country = false)
        signedOut()
        need(id("email").enabled(true)).text = account.email
        need(id("password")).text = account.password
        tapAway(id("submit"))
        need(By.text(context.getString(R.string.settings_onboarding_title)))
        expect("the page", device.wait(Until.hasObject(By.text(COUNTRY)), TIMEOUT_MS))
        // Asked of every screen alive, not the one in front, which covers whatever is behind it.
        expect("no map behind the first run", !mapAlive())
        expect("Save and continue", device.wait(Until.hasObject(By.text(Pattern.compile("Save and continue", Pattern.CASE_INSENSITIVE))), TIMEOUT_MS))
    }

    /** You lists the account over its numbers and recent weeks, Privacy, App, the HoldMyTrack
     *  tiles, Sign out and Delete account; Privacy shows what HoldMyTrack keeps and opens
     *  Download your data, a screen of its own. */
    @Test
    fun theYouTabListsItsRowsAndOpensPrivacy() {
        signIn(account())
        openYou()
        for (row in listOf("you_account", "you_stats", "you_weeks", "you_privacy", "you_theme", "you_language", "you_tour", "you_about", "you_help", "you_contacts", "you_sign_out", "you_delete")) {
            scrollTo(id(row))
        }
        // Back to the top, where Privacy sits whole.
        repeat(6) { device.findObject(By.scrollable(true))?.scroll(Direction.UP, 1f) }
        tapUntil({ still(id("you_privacy")) }) { device.hasObject(id("privacy_add")) }
        scrollTo(By.text(context.getString(R.string.privacy_keeps_map)))
        scrollTo(id("privacy_download"))
        tapUntil({ still(id("privacy_download")) }) { device.hasObject(id("export_request")) }
    }

    /** Delete account, confirmed by the typed email, signs out, and Sign in says why. */
    @Test
    fun deleteAccountSignsOut() {
        val account = account()
        signIn(account)
        openYou()
        scrollTo(id("you_delete"))
        tapUntil({ still(id("you_delete")) }) { device.hasObject(id("delete_email")) }
        need(id("delete_email")).text = account.email
        // The dialog moves with the keyboard: Delete is tapped once it has settled, until it closes.
        val delete = By.text(context.getString(R.string.settings_delete_submit)).clazz("android.widget.Button")
        tapUntil({ still(delete) }) { !device.hasObject(id("delete_email")) }
        expect("signed out", device.wait(Until.hasObject(id("email")), TIMEOUT_MS))
        expect("Sign in says the account was deleted", need(id("notice")).text == context.getString(R.string.account_deleted))
    }

    /** Whether a map screen is alive, in front or behind another. */
    private fun mapAlive(): Boolean {
        var alive = false
        instrumentation.runOnMainSync {
            val monitor = ActivityLifecycleMonitorRegistry.getInstance()
            alive = Stage.entries.filter { it != Stage.DESTROYED }.any { stage ->
                monitor.getActivitiesInStage(stage).any { it is MainActivity }
            }
        }
        return alive
    }

    @Before
    fun wake() = wakeDevice()

    @After
    fun deleteAccount() {
        account?.delete()
    }

    private companion object {
        /** The Settings page's Country field, by its label: the web's page writes it. */
        val COUNTRY: Pattern = Pattern.compile("country", Pattern.CASE_INSENSITIVE)

        @BeforeClass
        @JvmStatic
        fun prepare() = prepareDevice()

        @AfterClass
        @JvmStatic
        fun restore() = restoreDevice()
    }
}
