package dev.holdmytrack.android

import android.app.Activity
import android.app.Application
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.enableEdgeToEdge
import dev.holdmytrack.android.net.AppOutdated
import dev.holdmytrack.android.net.HoldMyTrackApi
import dev.holdmytrack.android.net.Session
import dev.holdmytrack.android.panel.ActivityTypes
import dev.holdmytrack.android.settings.AppTheme
import org.maplibre.android.MapLibre
import org.maplibre.android.module.http.HttpRequestUtil

/**
 * Process-level setup, all of which has to happen before anything else runs.
 *
 * The load-bearing line is the last one. MapLibre Native fetches the style document, the
 * basemap archive and every tile through its *own* HTTP stack, which the app's API client
 * never sees — so a credential held only by the app client would reach none of the user
 * layers. `HttpRequestUtil.setOkHttpClient` replaces that stack's client with the app's own,
 * whose interceptor attaches the session token per request (`net/HoldMyTrackApi.kt`). This is the
 * Android half of the roadmap's mobile auth decision, and it is confirmed core-SDK API rather
 * than a React-Native shim.
 *
 * It belongs here, not in an Activity: the map SDK may issue a request as soon as a `MapView`
 * exists, and a client installed after that has already missed requests.
 */
class HoldMyTrackApplication : Application() {

    override fun onCreate() {
        super.onCreate()
        Session.init(this)
        AppOutdated.init(this)
        ActivityTypes.init(this)
        // Before any screen inflates, so the first one already has the chosen theme's colors.
        AppTheme.applySaved(this)
        // Loads the native library and installs the module provider a MapView's constructor
        // asks for immediately, so no Activity has to remember to do it first.
        MapLibre.getInstance(this)
        HttpRequestUtil.setOkHttpClient(HoldMyTrackApi.client)
        // Every screen edge-to-edge on Android 14 too, as Android 15 and later draw it at this
        // targetSdk: each one pads itself for the system bars. Transparent bars with icons for the
        // theme's day or night, before the screen's own onCreate inflates anything.
        registerActivityLifecycleCallbacks(object : ActivityLifecycleCallbacks {
            override fun onActivityPreCreated(activity: Activity, savedInstanceState: Bundle?) {
                (activity as? ComponentActivity)?.enableEdgeToEdge()
            }
            override fun onActivityCreated(activity: Activity, savedInstanceState: Bundle?) = Unit
            override fun onActivityStarted(activity: Activity) = Unit
            override fun onActivityResumed(activity: Activity) = Unit
            override fun onActivityPaused(activity: Activity) = Unit
            override fun onActivityStopped(activity: Activity) = Unit
            override fun onActivitySaveInstanceState(activity: Activity, outState: Bundle) = Unit
            override fun onActivityDestroyed(activity: Activity) = Unit
        })
    }
}
