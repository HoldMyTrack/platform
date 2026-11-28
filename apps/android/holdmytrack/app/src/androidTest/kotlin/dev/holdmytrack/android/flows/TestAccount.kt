package dev.holdmytrack.android.flows

import dev.holdmytrack.android.BuildConfig
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.boolean
import kotlinx.serialization.json.buildJsonArray
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.put
import okhttp3.Cookie
import okhttp3.CookieJar
import okhttp3.HttpUrl
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.MultipartBody
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import java.util.zip.ZipInputStream

/**
 * A fresh account on the dev stack the app was built against (`BuildConfig.API_BASE_URL`),
 * with the sample tracks under `/static/testing/`: three around Cleveland in October 2026 and three
 * from the sample zip's Italy days in August, so the opening view lists the newest two and Dates
 * can split them by day. Deleted at the end of the run.
 */
class TestAccount private constructor(val email: String, val password: String, private val client: OkHttpClient) {

    /** The account's track ids by start day (`2026-10-01`, …). */
    lateinit var idsByDay: Map<String, String>
        private set

    fun createTrip(name: String, trackIds: List<String>) {
        call("POST", "/v2/trips", buildJsonObject {
            put("name", name)
            put("track_ids", buildJsonArray { trackIds.forEach { add(JsonPrimitive(it)) } })
        })
    }

    /** Each Trip's track ids, by its name. */
    fun trips(): Map<String, List<String>> =
        call("GET", "/v2/trips", null)!!.jsonObject["trips"]!!.jsonArray.map { it.jsonObject }.associate { trip ->
            trip["name"]!!.jsonPrimitive.content to trip["track_ids"]!!.jsonArray.map { it.jsonPrimitive.content }
        }

    fun delete() {
        runCatching { call("DELETE", "/v2/account", buildJsonObject { put("email", email) }) }
    }

    private fun upload(name: String, bytes: ByteArray) {
        val body = MultipartBody.Builder().setType(MultipartBody.FORM)
            .addFormDataPart("file", name, bytes.toRequestBody("application/octet-stream".toMediaType()))
            .build()
        send(Request.Builder().url("$BASE/v2/tracks/upload").post(body).build())
    }

    private fun download(path: String): ByteArray =
        client.newCall(Request.Builder().url("$BASE$path").build()).execute().use { response ->
            check(response.isSuccessful) { "GET $path: ${response.code}" }
            response.body.bytes()
        }

    /** Waits until the uploads are parsed: [count] tracks, none pending. */
    private fun settle(count: Int) {
        val deadline = System.currentTimeMillis() + SETTLE_TIMEOUT_MS
        while (true) {
            val tracks = call("GET", "/v2/tracks", null)!!.jsonObject["tracks"]!!.jsonArray.map { it.jsonObject }
            if (tracks.size == count && tracks.none { it["pending"]!!.jsonPrimitive.boolean }) {
                idsByDay = tracks.associate { it["started_at"]!!.jsonPrimitive.content.take(10) to it["id"]!!.jsonPrimitive.content }
                return
            }
            check(System.currentTimeMillis() < deadline) { "uploads not settled: ${tracks.size} of $count" }
            Thread.sleep(500)
        }
    }

    private fun call(method: String, path: String, body: JsonObject?): JsonElement? {
        val request = Request.Builder().url("$BASE$path")
            .method(method, body?.toString()?.toRequestBody("application/json".toMediaType()))
            .build()
        val text = send(request)
        return text.takeIf { it.isNotBlank() }?.let(Json::parseToJsonElement)
    }

    private fun send(request: Request): String = client.newCall(request).execute().use { response ->
        val text = response.body.string()
        check(response.isSuccessful) { "${request.method} ${request.url}: ${response.code} $text" }
        text
    }

    companion object {
        private val BASE = BuildConfig.API_BASE_URL
        private const val SETTLE_TIMEOUT_MS = 120_000L
        private val TESTING = listOf("west-side.gpx", "evening-loop.tcx", "mill-creek-falls.fit")
        private val FROM_ZIP = listOf("2026-08-02 Italy.gpx", "2026-08-03 Italy.gpx", "2026-08-04 Italy.gpx")

        fun create(): TestAccount {
            val cookies = mutableMapOf<String, Cookie>()
            val client = OkHttpClient.Builder()
                .cookieJar(object : CookieJar {
                    override fun saveFromResponse(url: HttpUrl, cookies: List<Cookie>) = cookies.forEach { put(it) }
                    private fun put(cookie: Cookie) {
                        cookies[cookie.name] = cookie
                    }
                    override fun loadForRequest(url: HttpUrl): List<Cookie> = cookies.values.toList()
                })
                .build()
            val account = TestAccount("flows-${System.currentTimeMillis()}@holdmytrack.local", "flows-test-password", client)
            account.call("POST", "/v2/auth/signup", buildJsonObject {
                put("email", account.email)
                put("password", account.password)
            })
            // A fresh account goes to the first-run setup until it has a Country.
            account.call("PATCH", "/v2/account/settings", buildJsonObject {
                put("display_name", "")
                put("country", "US")
                put("timezone", "America/New_York")
            })
            TESTING.forEach { name -> account.upload(name, account.download("/static/testing/$name")) }
            ZipInputStream(account.download("/static/testing/holdmytrack-sample.zip").inputStream()).use { zip ->
                generateSequence { zip.nextEntry }.filter { it.name in FROM_ZIP }.forEach { entry ->
                    account.upload(entry.name, zip.readBytes())
                }
            }
            account.settle(TESTING.size + FROM_ZIP.size)
            return account
        }
    }
}
