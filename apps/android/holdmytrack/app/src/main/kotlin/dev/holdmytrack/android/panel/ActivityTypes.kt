package dev.holdmytrack.android.panel

import android.content.Context
import dev.holdmytrack.android.net.HoldMyTrackApi
import org.json.JSONObject
import java.lang.ref.WeakReference
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.CopyOnWriteArrayList

/**
 * What the app shows for each activity type, as the server says (root `docs/SPEC.md` FR-5.1,
 * `GET /v1/activity-types` and every activity list's `types`): the app matches no words itself.
 * Kept on the phone, so a recording or an unsent activity shows its type offline too; a type the
 * server hasn't described yet is [ActivityKind.OTHER] until it has.
 */
object ActivityTypes {

    private const val PREFS = "holdmytrack.activity_types"
    private const val KEY = "types"

    private val kinds = ConcurrentHashMap<String, ActivityKind>()
    private var context: Context? = null

    /** Reads what an earlier run kept; from the Application, before any screen shows. */
    fun init(appContext: Context) {
        context = appContext.applicationContext
        val saved = prefs()?.getString(KEY, null) ?: return
        runCatching {
            val json = JSONObject(saved)
            for (type in json.keys()) kinds[type] = ActivityKind.fromWire(json.getJSONObject(type).optString("kind"))
        }
    }

    fun kind(type: String): ActivityKind = kinds[type] ?: ActivityKind.OTHER

    /** What a response said about its types, by type; kept for the next run. */
    fun merge(described: Map<String, ActivityKind>) {
        if (described.isEmpty() || described.all { (type, kind) -> kinds[type] == kind }) return
        kinds.putAll(described)
        save()
        listeners.forEach { it.get()?.invoke() }
    }

    private val listeners = CopyOnWriteArrayList<WeakReference<() -> Unit>>()

    /** [listener] runs after a merge changed something, on the thread that merged. Held weakly:
     *  the caller keeps it for as long as it wants to hear. */
    fun addListener(listener: () -> Unit) {
        listeners.removeAll { it.get() == null }
        listeners += WeakReference(listener)
    }

    /** Asks for the catalog and [types], unless every one of [types] is known and the catalog
     *  was read this run. Offline, what's kept stays. */
    fun refresh(types: Collection<String> = emptyList()) {
        val missing = types.filter { it.isNotEmpty() && !kinds.containsKey(it) }.distinct().take(MAX_NAMED)
        if (catalogRead && missing.isEmpty()) return
        HoldMyTrackApi.activityTypes(missing) { result ->
            result.getOrNull()?.let {
                catalogRead = true
                merge(it)
            }
        }
    }

    @Volatile private var catalogRead = false

    private fun save() {
        val json = JSONObject()
        for ((type, kind) in kinds) json.put(type, JSONObject().put("kind", kind.wire))
        prefs()?.edit()?.putString(KEY, json.toString())?.apply()
    }

    private fun prefs() = context?.getSharedPreferences(PREFS, Context.MODE_PRIVATE)

    /** The server's bound on named types. */
    private const val MAX_NAMED = 100
}
