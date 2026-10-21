package dev.holdmytrack.android.panel

import android.content.Context
import android.os.LocaleList
import dev.holdmytrack.android.net.HoldMyTrackApi
import org.json.JSONObject
import java.lang.ref.WeakReference
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.CopyOnWriteArrayList

/**
 * What the app shows for each activity type, as the server says (root `docs/SPEC.md` FR-5.1,
 * `GET /v1/activity-types`, every activity list's `types` and every Story's type labels): its
 * label and its kind. The app matches no words and keeps no catalog of its own. Kept on the phone
 * for the language it was read in, so a recording or an unsent activity shows its type offline
 * too; a type the server hasn't described yet is [ActivityKind.OTHER], and its label the type
 * spaced out from snake_case and title-cased, as the server falls back. The web's
 * `ui/activityTypes.ts`.
 */
object ActivityTypes {

    /** What the server said about one type; either part may be missing. */
    data class Info(val kind: ActivityKind?, val label: String?)

    private const val PREFS = "holdmytrack.activity_types"
    private const val KEY_TYPES = "types"
    private const val KEY_LANGUAGE = "language"

    private val kinds = ConcurrentHashMap<String, ActivityKind>()
    private val labels = ConcurrentHashMap<String, String>()
    private val listeners = CopyOnWriteArrayList<WeakReference<() -> Unit>>()
    private var context: Context? = null
    @Volatile private var catalogRead = false

    /** Reads what an earlier run kept in this language; from the Application, before any
     *  screen shows. */
    fun init(appContext: Context) {
        context = appContext.applicationContext
        val prefs = prefs() ?: return
        if (prefs.getString(KEY_LANGUAGE, null) != language()) return
        val saved = prefs.getString(KEY_TYPES, null) ?: return
        runCatching {
            val json = JSONObject(saved)
            for (type in json.keys()) {
                val info = json.getJSONObject(type)
                info.optString("kind").takeIf { it.isNotEmpty() }?.let { kinds[type] = ActivityKind.fromWire(it) }
                info.optString("label").takeIf { it.isNotEmpty() }?.let { labels[type] = it }
            }
        }
    }

    fun kind(type: String): ActivityKind = kinds[type] ?: ActivityKind.OTHER

    fun label(type: String): String = labels[type] ?: fallbackLabel(type)

    /** The server's own fallback for a type with no name of its own. */
    fun fallbackLabel(type: String): String =
        type.split('_').filter { it.isNotEmpty() }.joinToString(" ") { it.replaceFirstChar(Char::uppercaseChar) }

    /** What a response said about its types, by type; kept for the next run. */
    fun merge(described: Map<String, Info>) {
        var changed = false
        for ((type, info) in described) {
            if (info.kind != null && kinds.put(type, info.kind) != info.kind) changed = true
            if (info.label != null && labels.put(type, info.label) != info.label) changed = true
        }
        if (!changed) return
        save()
        listeners.forEach { it.get()?.invoke() }
    }

    /** [listener] runs after a merge changed something, on the thread that merged. Held weakly:
     *  the caller keeps it for as long as it wants to hear. */
    fun addListener(listener: () -> Unit) {
        listeners.removeAll { it.get() == null }
        listeners += WeakReference(listener)
    }

    /** Asks for the catalog and [types], unless every one of [types] is known and the catalog
     *  was read this run. Offline, what's kept stays. */
    fun refresh(types: Collection<String> = emptyList()) {
        val missing = types.filter { it.isNotEmpty() && !labels.containsKey(it) }.distinct().take(MAX_NAMED)
        if (catalogRead && missing.isEmpty()) return
        HoldMyTrackApi.activityTypes(missing) { result ->
            result.getOrNull()?.let {
                catalogRead = true
                merge(it)
            }
        }
    }

    private fun save() {
        val prefs = prefs() ?: return
        val json = JSONObject()
        for (type in kinds.keys + labels.keys) {
            json.put(type, JSONObject().apply {
                kinds[type]?.let { put("kind", it.wire) }
                labels[type]?.let { put("label", it) }
            })
        }
        prefs.edit().putString(KEY_TYPES, json.toString()).putString(KEY_LANGUAGE, language()).apply()
    }

    /** The languages the app asks the server in (`HoldMyTrackApi`'s Accept-Language). */
    private fun language(): String = LocaleList.getDefault().toLanguageTags()

    private fun prefs() = context?.getSharedPreferences(PREFS, Context.MODE_PRIVATE)

    /** The server's bound on named types. */
    private const val MAX_NAMED = 100
}
