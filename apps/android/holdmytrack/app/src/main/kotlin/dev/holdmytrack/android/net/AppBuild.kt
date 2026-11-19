package dev.holdmytrack.android.net

import okhttp3.HttpUrl

/**
 * What the app and the server say to each other about which build this is, as plain values:
 * the User-Agent naming it, the server's refusal of one too old (root `docs/IMPLEMENTATION.md`
 * §4.33) and where an update comes from. `AppOutdated` acts on them.
 */
object AppBuild {

    /** What the User-Agent names this build — `HoldMyTrack-Android/1.2.3 (62da50b; 812)`: the
     *  release number, the commit and the versionCode, which the server compares against its
     *  minimum. */
    fun userAgent(versionName: String, gitSha: String, versionCode: Int): String =
        "HoldMyTrack-Android/$versionName ($gitSha; $versionCode)"

    /** Whether a response to [url] with [code] is the server turning this build away: only
     *  its own `/v2/`, since nothing else answers 426 for that reason ([ApiOrigin]). */
    fun isRefusal(url: HttpUrl, apiBase: HttpUrl, code: Int): Boolean =
        code == 426 && ApiOrigin.isApi(url, ApiPath.v2(apiBase))

    /** Where Update leads: the app's Play listing, the only way the app is handed out. */
    fun updateLink(packageName: String): String =
        "https://play.google.com/store/apps/details?id=$packageName"
}
