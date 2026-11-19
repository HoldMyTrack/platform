package dev.holdmytrack.android.net

import android.content.ContentResolver
import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.net.Uri
import android.os.Handler
import android.os.LocaleList
import android.os.Looper
import dev.holdmytrack.android.BuildConfig
import dev.holdmytrack.android.map.DateFilter
import dev.holdmytrack.android.map.GeoPoint
import dev.holdmytrack.android.panel.TrackKind
import dev.holdmytrack.android.panel.TrackTypes
import java.io.File
import java.io.IOException
import java.time.Duration
import java.time.Instant
import java.time.OffsetDateTime
import java.util.concurrent.Executors
import okhttp3.Cache
import okhttp3.Call
import okhttp3.Callback
import okhttp3.Dispatcher
import okhttp3.HttpUrl
import okhttp3.HttpUrl.Companion.toHttpUrl
import okhttp3.Interceptor
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.MultipartBody
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody
import okhttp3.RequestBody.Companion.asRequestBody
import okhttp3.RequestBody.Companion.toRequestBody
import okhttp3.Response
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import okio.BufferedSink
import okio.source

/**
 * The app's whole HTTP surface: the auth endpoints, sync and its history, and the track
 * reads the map and the recording screen use.
 *
 * Callback-based over OkHttp's own `enqueue`, each callback posted back to the main thread so
 * callers touch views directly; the calls sync and uploads make from coroutines are `suspend`.
 * Its data types are in `ApiModels.kt`.
 */
object HoldMyTrackApi {

    /** [ApiException.errorCode] of a split that would leave a part entirely inside a Private
     *  location (`docs/SPEC.md` FR-5.9) — asked about, then sent with allowHidden. */
    const val SPLIT_HIDES_PART = "split_hides_part"

    private const val API_V2 = "/v2"

    /** The `source` values this app posts to `POST /v2/sync/tracks` — Health Connect
     *  sync (`sync/SyncRunner.kt`), in-app GPS recording (`recording/RecordingActivity.kt`,
     *  `docs/IMPLEMENTATION.md` §4.0.4). iOS's own is `"healthkit"`; an
     *  uploaded file has its own endpoint ([uploadTrackFile]). */
    const val SOURCE_HEALTH_CONNECT = "healthconnect"
    const val SOURCE_RECORDED = "recorded"
    private val JSON = "application/json; charset=utf-8".toMediaType()
    private val main = Handler(Looper.getMainLooper())

    /** Opening a connection to the server or a tile host, TLS included. */
    private val CONNECT_TIMEOUT = Duration.ofSeconds(10)
    /** The longest wait for the next bytes of a response, the first included: a slow server query ends here. */
    private val READ_TIMEOUT = Duration.ofSeconds(10)
    /** The longest wait for one write of the request body to go out. */
    private val WRITE_TIMEOUT = Duration.ofSeconds(10)
    /** [uploadClient]'s write timeout: a 16 MiB file over a slow connection. */
    private val UPLOAD_WRITE_TIMEOUT = Duration.ofMinutes(2)
    /** [uploadClient]'s read timeout: the wait for the answer once the file has gone out. */
    private val UPLOAD_READ_TIMEOUT = Duration.ofMinutes(10)

    /**
     * One client for the app's own calls *and* for MapLibre Native's tile fetching — handed to
     * the map SDK by `HoldMyTrackApplication` via `HttpRequestUtil.setOkHttpClient`. Sharing one
     * instance is what makes the interceptor below a single place: a second client for the map
     * would be a second place the token could go missing from.
     *
     * The dispatcher mirrors what MapLibre's own default client configures (20 requests per
     * host, up from OkHttp's default 5) — a map fetches tiles in bursts from one origin, and
     * inheriting OkHttp's default here would throttle the map relative to the SDK's own
     * behaviour for no reason.
     */
    /** This build: the release number and the commit, "1.2.3 (62da50b)" — what the You tab shows
     *  and the User-Agent carries. */
    val appVersion: String = "${BuildConfig.VERSION_NAME} (${BuildConfig.GIT_SHA})"

    /** The API's own base URL, parsed once for [isApi]. */
    private val apiBase: HttpUrl by lazy { BuildConfig.API_BASE_URL.toHttpUrl() }

    /** `/v2/` and [segments] on the API ([ApiPath]). */
    private fun v2(vararg segments: String): HttpUrl = ApiPath.v2(apiBase, *segments)

    /** Whether [url] is a request to HoldMyTrack's own API ([ApiOrigin]). */
    private fun isApi(url: HttpUrl): Boolean = ApiOrigin.isApi(url, apiBase)

    val client: OkHttpClient = OkHttpClient.Builder()
        .dispatcher(Dispatcher().apply { maxRequestsPerHost = 20 })
        .connectTimeout(CONNECT_TIMEOUT)
        .readTimeout(READ_TIMEOUT)
        .writeTimeout(WRITE_TIMEOUT)
        .addInterceptor(BearerInterceptor)
        .addInterceptor(UserAgentInterceptor)
        .addInterceptor(LanguageInterceptor)
        .addInterceptor(OriginInterceptor)
        .addInterceptor(OutdatedInterceptor)
        .build()

    /**
     * Sends `Origin: <the API's origin>` on every request that leaves it, as the web client's
     * browser does on its cross-origin fetches. The satellite imagery's key (root
     * `docs/DEPLOY.md` §5) is restricted to the deployment's origin, and without an Origin
     * MapTiler refuses the app's tiles with a `403`. It gives nothing away: the key is already
     * public in the web bundle and the style document, and the restriction is there to stop other
     * websites spending the quota, which a native client setting a header doesn't. A request that
     * already carries an Origin is left as it is.
     */
    private object OriginInterceptor : Interceptor {
        private val origin = BuildConfig.API_BASE_URL.toHttpUrl().let { url ->
            val port = if (url.port == HttpUrl.defaultPort(url.scheme)) "" else ":${url.port}"
            "${url.scheme}://${url.host}$port"
        }

        override fun intercept(chain: Interceptor.Chain): Response {
            val request = chain.request()
            if (isApi(request.url) || request.header("Origin") != null) {
                return chain.proceed(request)
            }
            return chain.proceed(request.newBuilder().header("Origin", origin).build())
        }
    }

    /**
     * Names the app and its build — `HoldMyTrack-Android/1.2.3 (62da50b; 812)` — on HoldMyTrack's
     * own requests, so the server's logs say which build made a call and the server can turn
     * away one older than its minimum. Other origins keep what the request already had:
     * MapLibre's own agent on the basemap's assets.
     */
    private object UserAgentInterceptor : Interceptor {
        private val agent = AppBuild.userAgent(BuildConfig.VERSION_NAME, BuildConfig.GIT_SHA, BuildConfig.VERSION_CODE)

        override fun intercept(chain: Interceptor.Chain): Response {
            val request = chain.request()
            if (!isApi(request.url)) return chain.proceed(request)
            return chain.proceed(request.newBuilder().header("User-Agent", agent).build())
        }
    }

    /**
     * Whether [response] is the server refusing this build, which [OutdatedInterceptor] has
     * already handed to the Update screen. A callback caller isn't told: the screen that made
     * the call may be gone by the time it would run, and nothing it could show is still seen.
     * A suspending caller still gets its exception, and its lifecycle's scope is cancelled with
     * the screen.
     */
    private fun refusedBuild(response: Response): Boolean =
        AppBuild.isRefusal(response.request.url, apiBase, response.code)

    /** Hands the server's refusal of this build to [AppOutdated], whichever call met it. */
    private object OutdatedInterceptor : Interceptor {
        override fun intercept(chain: Interceptor.Chain): Response {
            val response = chain.proceed(chain.request())
            if (refusedBuild(response)) AppOutdated.refused()
            return response
        }
    }

    /**
     * Sends the app's language as Accept-Language on HoldMyTrack's own requests, so the
     * server's messages (a failed sign-in, a rejected track) come back in it — the same
     * language the rest of the screen is in. Read per request: the per-app language can change
     * while the app runs. OkHttp sends no Accept-Language of its own, so without this the
     * server would always answer in English.
     */
    private object LanguageInterceptor : Interceptor {
        override fun intercept(chain: Interceptor.Chain): Response {
            val request = chain.request()
            if (!isApi(request.url)) return chain.proceed(request)
            val tags = LocaleList.getDefault().toLanguageTags()
            if (tags.isEmpty()) return chain.proceed(request)
            return chain.proceed(request.newBuilder().header("Accept-Language", tags).build())
        }
    }

    /**
     * Attaches the session token to every request bound for HoldMyTrack's own API, and to nothing
     * else. Runs per request rather than being configured once, so a sign-in, sign-out or
     * expiry takes effect on the very next tile without anything being re-registered — the
     * property the roadmap picked this hook for.
     *
     * The origin check is the part worth keeping: the style document's basemap assets (the
     * pmtiles archive, glyphs, sprites) are unauthenticated and, in a CDN deployment, live on
     * a third party's origin. A bearer token is a live credential, and sending it to an origin
     * that has no use for it only puts it in someone else's access logs.
     */
    private object BearerInterceptor : Interceptor {
        override fun intercept(chain: Interceptor.Chain): Response {
            val request = chain.request()
            val token = Session.token
            if (token == null || !isApi(request.url)) {
                return chain.proceed(request)
            }
            return chain.proceed(request.newBuilder().header("Authorization", "Bearer $token").build())
        }
    }

    /**
     * `POST /v2/sync/tracks` — Path 2's batched sync (`docs/IMPLEMENTATION.md` §4.0.3).
     *
     * Suspending rather than callback-based like everything above it, because its only caller
     * is the sync run, which is a coroutine from end to end (Health Connect's read API leaves
     * no choice), and it waits for each answer: the next batch must not be sent until this one
     * is answered. [await] cancels the request with the run.
     *
     * Returns the server's per-track verdicts rather than a single pass/fail — a batch is
     * not all-or-nothing there, and the caller needs to know which ones landed before it takes
     * them off its list. A non-2xx status is the whole request failing and throws instead;
     * nothing in the batch was decided.
     */
    internal suspend fun syncTracks(tracks: List<SyncTrackJson>, source: String): List<SyncResult> =
        withContext(Dispatchers.IO) {
            val request = Request.Builder()
                .url(BuildConfig.API_BASE_URL + API_V2 + "/sync/tracks")
                .post(jsonBody(SyncTracksRequestJson(source, tracks)))
                .build()
            val response = waitingClient.newCall(request).await()
            val text = response.use { it.body.string() }
            if (!response.isSuccessful) throw ApiException.from(response.code, text)
            decode<SyncResultsJson>(text).results.map { SyncResult(it.externalId, it.status, it.error) }
        }

    /**
     * `POST /v2/sync/known` (`docs/IMPLEMENTATION.md` §4.0.3): which of [externalIds] the
     * account already has from [source] — the Sync tab's list is what's on the phone minus these,
     * so a reinstall or a second phone agrees with the server — and, of those, which are still
     * processing: sent, not on the map yet. Suspending, like [syncTracks], for the same
     * caller; a failure throws.
     */
    suspend fun syncKnown(source: String, externalIds: List<String>): SyncKnown =
        withContext(Dispatchers.IO) {
            val known = mutableSetOf<String>()
            val processing = mutableSetOf<String>()
            for (chunk in externalIds.chunked(MAX_KNOWN_IDS)) {
                val request = Request.Builder()
                    .url(BuildConfig.API_BASE_URL + API_V2 + "/sync/known")
                    .post(jsonBody(SyncKnownRequestJson(source, chunk)))
                    .build()
                val response = waitingClient.newCall(request).await()
                val text = response.use { it.body.string() }
                if (!response.isSuccessful) throw ApiException.from(response.code, text)
                val json = decode<SyncKnownJson>(text)
                known += json.known
                processing += json.processing
            }
            SyncKnown(known, processing)
        }

    /**
     * `POST /v2/tracks/overlaps` (root `docs/IMPLEMENTATION.md` §4.6): for each of [spans],
     * keyed by the caller, the live track it overlaps, if any — the Already on your map half
     * of the Sync tab's similar tracks (`docs/SPEC.md` FR-3.5). Keys with no overlap aren't in
     * the map.
     */
    suspend fun trackOverlaps(spans: List<OverlapSpan>): Map<String, TrackOverlap> =
        withContext(Dispatchers.IO) {
            val found = mutableMapOf<String, TrackOverlap>()
            for (chunk in spans.chunked(MAX_KNOWN_IDS)) {
                val spansJson = chunk.map { OverlapSpanJson(it.key, it.start.toString(), it.end.toString()) }
                val request = Request.Builder()
                    .url(BuildConfig.API_BASE_URL + API_V2 + "/tracks/overlaps")
                    .post(jsonBody(OverlapsRequestJson(spansJson)))
                    .build()
                val response = waitingClient.newCall(request).await()
                val text = response.use { it.body.string() }
                if (!response.isSuccessful) throw ApiException.from(response.code, text)
                for (row in decode<OverlapsJson>(text).overlaps) {
                    found[row.key] = TrackOverlap(row.trackId, row.name, row.trackType, row.startedAt, row.timezone)
                }
            }
            found
        }

    /**
     * The client the suspending calls ([syncTracks], [syncKnown], [trackOverlaps], and uploads
     * through [uploadClient]) send through: [client] with a dispatcher of its own, so a batch
     * doesn't queue behind a burst of the map's tiles for the API host's 20 slots, nor an upload
     * hold one of them for minutes. The same connections and interceptors otherwise.
     */
    private val waitingClient: OkHttpClient by lazy { client.newBuilder().dispatcher(Dispatcher()).build() }

    /** The server's `maxKnownIDs`: one `POST /v2/sync/known` asks about at most this many. */
    private const val MAX_KNOWN_IDS = 5000

    /**
     * Uploads take as long as sending the file does, up to 16 MiB, which over a slow connection
     * takes longer than [WRITE_TIMEOUT].
     * The same client otherwise, so the same interceptors.
     */
    private val uploadClient: OkHttpClient by lazy {
        waitingClient.newBuilder()
            .writeTimeout(UPLOAD_WRITE_TIMEOUT)
            .readTimeout(UPLOAD_READ_TIMEOUT)
            .build()
    }

    /**
     * `POST /v2/tracks/upload` — the web's Upload menu's request (root `docs/SPEC.md`
     * FR-3.1): one `.gpx`, `.fit` or `.tcx`. The file is streamed from [uri] rather than read into
     * memory first, since it can be 16 MiB; [onProgress] gets the bytes sent so far, on the
     * I/O thread sending them. Suspending, like [syncTracks]: its caller (`imports/FileImports.kt`)
     * sends one file after another and waits for each.
     */
    suspend fun uploadTrackFile(
        resolver: ContentResolver,
        uri: Uri,
        name: String,
        size: Long,
        onProgress: (Long) -> Unit,
    ): UploadOutcome = withContext(Dispatchers.IO) {
        val body = MultipartBody.Builder()
            .setType(MultipartBody.FORM)
            .addFormDataPart("file", name, UriRequestBody(resolver, uri, size, onProgress))
            .build()
        val request = Request.Builder()
            .url(BuildConfig.API_BASE_URL + API_V2 + "/tracks/upload")
            .post(body)
            .build()
        val response = uploadClient.newCall(request).await()
        val text = response.use { it.body.string() }
        if (!response.isSuccessful) throw ApiException.from(response.code, text)
        UploadOutcome(status = decode<UploadResultJson>(text).status)
    }

    /** A picked file as a request body, read as it's sent. Opened afresh on every [writeTo], so
     *  OkHttp's retry of a dropped connection sends the whole file again. */
    private class UriRequestBody(
        private val resolver: ContentResolver,
        private val uri: Uri,
        private val size: Long,
        private val onProgress: (Long) -> Unit,
    ) : RequestBody() {
        override fun contentType() = "application/octet-stream".toMediaType()

        override fun contentLength() = size

        override fun writeTo(sink: BufferedSink) {
            val input = resolver.openInputStream(uri) ?: throw IOException("could not open the file")
            input.source().use { source ->
                var sent = 0L
                while (true) {
                    val read = source.read(sink.buffer, 64 * 1024L)
                    if (read == -1L) break
                    sink.emitCompleteSegments()
                    sent += read
                    onProgress(sent)
                }
            }
        }
    }

    /** `GET /v2/auth/providers` — which of the Google and Facebook buttons to show. */
    fun providers(onResult: (Result<Providers>) -> Unit) {
        val request = Request.Builder().url(BuildConfig.API_BASE_URL + API_V2 + "/auth/providers").build()
        call(request, { body ->
            val json = decode<ProvidersJson>(body)
            Providers(google = json.google, facebook = json.facebook, googleClientId = json.googleClientId)
        }, onResult)
    }

    /** `POST /v2/auth/google/nonce` — the nonce to ask Credential Manager to put in the ID
     *  token, which [signInWithGoogle] then spends, so a copy of the token signs nobody in. */
    fun googleNonce(onResult: (Result<String>) -> Unit) {
        val request = Request.Builder().url(v2("auth", "google", "nonce")).post(EMPTY_BODY).build()
        call(request, { body -> decode<GoogleNonceJson>(body).nonce }, onResult)
    }

    /**
     * `POST /v2/auth/google/token` — trades the ID token Credential Manager returned for a
     * session. The server checks the token's signature against Google's keys before trusting
     * anything in it (`docs/IMPLEMENTATION.md` §4.9).
     */
    fun signInWithGoogle(idToken: String, timezone: String, onResult: (Result<Account>) -> Unit) {
        authenticate("/auth/google/token", jsonBody(GoogleTokenJson(idToken, timezone)), onResult)
    }

    /**
     * Where Sign in with Facebook starts: the server's own web flow, opened in a browser tab,
     * with the S256 [challenge] of a verifier only this app holds. The round trip ends at
     * `holdmytrack://oauth?code=…`, redeemed with [exchangeHandoff].
     */
    fun facebookStartUri(timezone: String, challenge: String): Uri =
        Uri.parse(BuildConfig.API_BASE_URL + API_V2 + "/auth/facebook/start").buildUpon()
            .appendQueryParameter("tz", timezone)
            .appendQueryParameter("app_challenge", challenge)
            .build()

    /**
     * The web's sign-up page for this app, opened in a browser tab so the sign-up passes its
     * Turnstile check, with the S256 [challenge] of a verifier only this app holds. A new account
     * comes back at `holdmytrack://oauth?code=…`, redeemed with [exchangeHandoff]; the page's own
     * script gives it the browser's timezone.
     */
    fun signUpPageUri(challenge: String): Uri =
        Uri.parse(BuildConfig.API_BASE_URL + "/signup").buildUpon()
            .appendQueryParameter("app_challenge", challenge)
            .build()

    /** One of the web's own pages — "Forgot password?", About, Help — served by the API's own
     *  origin, outside `/v2`. */
    fun webPageUri(path: String): Uri = Uri.parse(BuildConfig.API_BASE_URL + path)

    /** `POST /v2/auth/handoff` — redeems a browser-tab round trip's one-time code, once. */
    fun exchangeHandoff(code: String, verifier: String, onResult: (Result<Account>) -> Unit) {
        authenticate("/auth/handoff", jsonBody(HandoffJson(code, verifier)), onResult)
    }

    fun signIn(email: String, password: String, onResult: (Result<Account>) -> Unit) {
        authenticate("/auth/login", jsonBody(CredentialsJson(email, password)), onResult)
    }

    /**
     * `docs/VISION.md` §8.2's no-signup account. A real user row with a real session behind the
     * scenes, so nothing downstream — tiles, sync, anything — needs a demo-specific branch.
     */
    fun startDemo(onResult: (Result<Account>) -> Unit) {
        authenticate("/auth/demo", EMPTY_BODY, onResult)
    }

    /**
     * Revokes the session server-side, not just locally: `POST /v2/auth/logout` deletes the
     * row, so a token copied off the device stops working immediately rather than staying
     * valid for the rest of its 30-day TTL.
     *
     * The local clear happens either way. A failed request here means the network was down or
     * the token was already dead — in neither case is keeping it on the device the right
     * answer, and a sign-out that visibly doesn't sign out is worse than one that can't reach
     * the server.
     */
    fun signOut(onDone: () -> Unit) {
        val request = Request.Builder()
            .url(BuildConfig.API_BASE_URL + API_V2 + "/auth/logout")
            .post(EMPTY_BODY)
            .build()
        client.newCall(request).enqueue(object : Callback {
            override fun onFailure(call: Call, e: IOException) = finish()
            override fun onResponse(call: Call, response: Response) = response.use { finish() }
            private fun finish() {
                Session.clear()
                main.post(onDone)
            }
        })
    }

    /**
     * Checks a token restored from disk against the server — `GET /v2/auth/me`, the same
     * question the web client asks on first load. A 401 means the session is gone (revoked,
     * or expired past its TTL while the app was closed) and the token should be dropped; any
     * other failure is the network's fault and says nothing about the token.
     *
     * Answers with the account's `email_verified`, since a live token is not by itself enough
     * for the map: an unconfirmed email gets `403` on every tile (`VerifyEmailActivity`).
     */
    fun verifySession(onResult: (Result<Profile>) -> Unit) {
        val request = Request.Builder().url(BuildConfig.API_BASE_URL + API_V2 + "/auth/me").build()
        call(request, { body -> decode<AccountJson>(body).toProfile() }, onResult)
    }

    /** `GET /v2/account/settings/options` — see [SettingsOptions]. */
    fun settingsOptions(onResult: (Result<SettingsOptions>) -> Unit) {
        val request = Request.Builder().url(BuildConfig.API_BASE_URL + API_V2 + "/account/settings/options").build()
        call(request, { body ->
            val json = decode<SettingsOptionsJson>(body)
            fun options(list: List<SettingsOptionJson>) = list.map { SettingsOption(it.value, it.label) }
            SettingsOptions(
                countries = options(json.countries),
                timezones = json.timezones.map { TimezoneGroup(it.label.ifBlank { it.region }, options(it.options)) },
                languages = options(json.languages),
            )
        }, onResult)
    }

    /**
     * `PATCH /v2/account/settings` — Name, Country, Timezone and Language as one save, as the
     * web page saves them. [locale] is empty for "automatic". Answers with the saved profile;
     * a refusal (a missing country, a demo account) is the server's own wording.
     */
    fun updateSettings(
        displayName: String,
        country: String,
        timezone: String,
        locale: String,
        onResult: (Result<Profile>) -> Unit,
    ) {
        val request = Request.Builder()
            .url(BuildConfig.API_BASE_URL + API_V2 + "/account/settings")
            .patch(jsonBody(SettingsJson(displayName, country, timezone, locale)))
            .build()
        call(request, { text -> decode<AccountJson>(text).toProfile() }, onResult)
    }

    /**
     * `DELETE /v2/account` (root `docs/SPEC.md` FR-1.12) — [email] typed as confirmation. The
     * server closes the account and ends every session of it; a mismatch is its own wording.
     * The caller clears what this device holds for the account ([Session.clear] and the rest).
     */
    fun deleteAccount(email: String, onResult: (Result<Unit>) -> Unit) {
        val request = Request.Builder()
            .url(BuildConfig.API_BASE_URL + API_V2 + "/account")
            .delete(jsonBody(EmailJson(email)))
            .build()
        call(request, { }, onResult)
    }

    /** `GET /v2/account/export` — where the account's latest copy of its data stands. */
    fun exportStatus(onResult: (Result<ExportStatus>) -> Unit) {
        val request = Request.Builder().url(BuildConfig.API_BASE_URL + API_V2 + "/account/export").build()
        call(request, { body -> decode<ExportStatusJson>(body).toExportStatus() }, onResult)
    }

    /** `POST /v2/account/export` — asks for a copy; one already being prepared is returned
     *  instead. The server emails the account when it's ready, in the app's language. */
    fun requestExport(onResult: (Result<ExportStatus>) -> Unit) {
        val request = Request.Builder()
            .url(BuildConfig.API_BASE_URL + API_V2 + "/account/export")
            .post(EMPTY_BODY)
            .build()
        call(request, { body -> decode<ExportStatusJson>(body).toExportStatus() }, onResult)
    }

    /** `POST /v2/account/exports/{id}/parts/{n}/link` — an absolute URL to [part] that needs no
     *  session, for Android's DownloadManager, which keeps its requests' headers in a database
     *  outside the app. It lasts a day at most. */
    fun exportPartLink(part: ExportPart, onResult: (Result<Uri>) -> Unit) {
        val request = Request.Builder().url(BuildConfig.API_BASE_URL + part.url + "/link").post(EMPTY_BODY).build()
        call(request, { body -> Uri.parse(BuildConfig.API_BASE_URL + decode<ExportLinkJson>(body).url) }, onResult)
    }

    /** Where [imageClient] keeps its images: the app's cache directory, set at start. */
    private var imageCacheDir: File? = null

    /** Set from `HoldMyTrackApplication`, before any image is fetched. */
    fun initImageCache(context: Context) {
        imageCacheDir = File(context.cacheDir, "images")
    }

    /**
     * [client] with a disk cache, for [image] alone: photos and their thumbnails are served
     * immutable for a year, and the avatar's URL carries its version, so each is fetched once
     * rather than on every return to the You tab or every step through the photo viewer. Not
     * on [client] itself: MapLibre keeps its own tile cache through it.
     */
    private val imageClient: OkHttpClient by lazy {
        val dir = imageCacheDir ?: return@lazy client
        client.newBuilder().cache(Cache(dir, IMAGE_CACHE_BYTES)).build()
    }

    /** Where the image cache is emptied or trimmed: off the main thread, since it walks and
     *  deletes files. */
    private val imageCacheIo = Executors.newSingleThreadExecutor()

    /** The account's images go with its session (`Session.clear`): the avatar's path is the
     *  same for every account. Files left by an earlier process go too. */
    fun clearImageCache() {
        imageCacheIo.execute { runCatching { imageClient.cache?.evictAll() } }
    }

    /** Photo [id]'s image and thumbnail leave the cache once it's deleted. */
    private fun forgetPhoto(id: String) {
        val photo = v2("photos", id).toString()
        imageCacheIo.execute {
            runCatching {
                val urls = imageClient.cache?.urls() ?: return@runCatching
                while (urls.hasNext()) {
                    val url = urls.next()
                    if (url == photo || url.startsWith("$photo/") || url.startsWith("$photo?")) urls.remove()
                }
            }
        }
    }

    private const val IMAGE_CACHE_BYTES = 64L shl 20

    /** The avatar at [path] (a [Profile.avatarUrl], relative to the API) — see [image]. */
    fun avatar(path: String, onResult: (Result<Bitmap>) -> Unit) = image(path, maxSide = null, onResult)

    /**
     * The image at [path] (relative to the API: an avatar, a [Photo.url] or [Photo.thumbUrl]),
     * fetched with the session's bearer token like any other API request — a browser tab or an
     * image library would have no token to send — and decoded, off the main thread. With
     * [maxSide], decoded at the largest power-of-two reduction still at least that many pixels on
     * its long side, so a 2048 px photo shown at a popup's width isn't held at full size.
     */
    fun image(path: String, maxSide: Int?, onResult: (Result<Bitmap>) -> Unit) {
        val request = Request.Builder().url(BuildConfig.API_BASE_URL + path).build()
        imageClient.newCall(request).enqueue(object : Callback {
            override fun onFailure(call: Call, e: IOException) {
                main.post { onResult(Result.failure(e)) }
            }

            override fun onResponse(call: Call, response: Response) {
                if (refusedBuild(response)) return response.close()
                // A body cut off, or an image too big to decode, is this call's failure: thrown
                // from here, OkHttp would never call back, or would take the app down.
                val result = try {
                    decodeImage(response, maxSide)
                } catch (e: Exception) {
                    Result.failure(e)
                } catch (e: OutOfMemoryError) {
                    Result.failure(IOException("image too large to show", e))
                }
                main.post { onResult(result) }
            }
        })
    }

    /** [response]'s image, decoded at a reduction still at least [maxSide] on its long side. */
    private fun decodeImage(response: Response, maxSide: Int?): Result<Bitmap> = response.use {
        if (!it.isSuccessful) return@use Result.failure(ApiException(it.code, ""))
        val bytes = it.body.bytes()
        val options = BitmapFactory.Options()
        if (maxSide != null) {
            options.inJustDecodeBounds = true
            BitmapFactory.decodeByteArray(bytes, 0, bytes.size, options)
            val longSide = maxOf(options.outWidth, options.outHeight)
            var sample = 1
            while (longSide / (sample * 2) >= maxSide) sample *= 2
            options.inJustDecodeBounds = false
            options.inSampleSize = sample
        }
        BitmapFactory.decodeByteArray(bytes, 0, bytes.size, options)?.let { bitmap -> Result.success(bitmap) }
            ?: Result.failure(IOException("not an image"))
    }

    /** `POST /v2/auth/verify-code` — the 6-digit code from the verification email, typed in this
     *  session, which stays signed in. The account as verified, or the server's refusal. */
    fun verifyCode(code: String, onResult: (Result<Profile>) -> Unit) {
        val request = Request.Builder()
            .url(BuildConfig.API_BASE_URL + API_V2 + "/auth/verify-code")
            .post(jsonBody(CodeJson(code)))
            .build()
        call(request, { body -> decode<AccountJson>(body).toProfile() }, onResult)
    }

    /**
     * `POST /v2/auth/resend-verification` — mails a fresh confirmation link. Answers with the
     * server's own confirmation text ("Verification email sent."), in the app's language.
     */
    fun resendVerification(onResult: (Result<String>) -> Unit) {
        val request = Request.Builder()
            .url(BuildConfig.API_BASE_URL + API_V2 + "/auth/resend-verification")
            .post(EMPTY_BODY)
            .build()
        call(request, { body -> decode<MessageJson>(body).message }, onResult)
    }


    /** `GET /v2/tracks?trip=`: that whole Trip's tracks (`docs/SPEC.md` FR-13.6), newest
     *  first, in one response. */
    fun tripTracks(trip: String, onResult: (Result<List<Track>>) -> Unit) {
        val url = (BuildConfig.API_BASE_URL + API_V2 + "/tracks").toHttpUrl().newBuilder()
            .addQueryParameter("trip", trip)
            .build()
        call(Request.Builder().url(url).build(), { body ->
            val decoded = decode<TracksJson>(body)
            TrackTypes.merge(decoded.types.described())
            decoded.tracks.map { it.toTrack() }
        }, onResult)
    }

    /**
     * `GET /v2/tracks/area`: the newest tracks, at most [limit], whose track crosses [box]
     * (`[west, south, east, north]`), all of them without one, under [dates] (`docs/SPEC.md`
     * FR-5.11). Its rows are slim: the Edit window reads [track] for the rest.
     */
    fun areaTracks(box: List<Double>?, dates: DateFilter, limit: Int? = null, onResult: (Result<AreaPage>) -> Unit) {
        val url = (BuildConfig.API_BASE_URL + API_V2 + "/tracks/area").toHttpUrl().newBuilder()
            .apply { if (box != null) addQueryParameter("bbox", box.joinToString(",")) }
            .apply { dates.after?.let { addQueryParameter("from", it) } }
            .apply { dates.before?.let { addQueryParameter("to", it) } }
            .apply { if (limit != null) addQueryParameter("limit", limit.toString()) }
            .build()
        call(Request.Builder().url(url).build(), { body ->
            val decoded = decode<AreaTracksJson>(body)
            TrackTypes.merge(decoded.types.described())
            AreaPage(decoded.tracks.map { it.toTrack() }, decoded.total)
        }, onResult)
    }

    /** `GET /v2/tracks/{id}`: one track in full, for the Edit window. */
    fun track(id: String, onResult: (Result<Track>) -> Unit) {
        val request = Request.Builder().url(v2("tracks", id)).build()
        call(request, { body -> decode<TracksJson>(body).tracks.first().toTrack() }, onResult)
    }

    /** `GET /v2/tracks/pending`: which of [ids] are still Pending (`map/PendingTracker`). */
    fun pendingTracks(ids: List<String>, onResult: (Result<List<String>>) -> Unit) {
        val url = (BuildConfig.API_BASE_URL + API_V2 + "/tracks/pending").toHttpUrl().newBuilder()
            .addQueryParameter("ids", ids.joinToString(","))
            .build()
        call(Request.Builder().url(url).build(), { body -> decode<PendingJson>(body).pending }, onResult)
    }

    /** `GET /v2/track-types`: what to show for the catalog's types and [types] (`panel/TrackTypes`). */
    fun trackTypes(types: List<String>, onResult: (Result<Map<String, TrackTypes.Info>>) -> Unit) {
        val url = (BuildConfig.API_BASE_URL + API_V2 + "/track-types").toHttpUrl().newBuilder()
            .apply { if (types.isNotEmpty()) addQueryParameter("types", types.joinToString(",")) }
            .build()
        call(Request.Builder().url(url).build(), { body -> decode<TrackTypesJson>(body).types.described() }, onResult)
    }

    private fun Map<String, TrackTypeJson>.described(): Map<String, TrackTypes.Info> =
        mapValues { TrackTypes.Info(TrackKind.fromWire(it.value.kind), it.value.label) }

    /**
     * `PATCH /v2/tracks/{id}` — a full replace of the three fields a person can set
     * (`docs/SPEC.md` FR-5.5): an empty [name] or [description] clears it. Answers
     * with the row as it now is. A refusal (too long, a demo account) is the server's own
     * wording, in the app's language.
     */
    fun updateTrack(id: String, trackType: String, name: String, description: String, onResult: (Result<Track>) -> Unit) {
        val request = Request.Builder()
            .url(v2("tracks", id))
            .patch(jsonBody(TrackPatchJson(trackType, name, description)))
            .build()
        call(request, { text -> decode<TrackRowJson>(text).toTrack() }, onResult)
    }

    /**
     * `POST /v2/tracks/stats-card` (`docs/IMPLEMENTATION.md` §4.3.3): the export's stats card
     * for [trackIds] as a PNG drawn for an image [width] × [height], or null when every one of
     * them is Pending (204). Decoded off the main thread.
     */
    fun statsCard(trackIds: List<String>, width: Int, height: Int, dark: Boolean, onResult: (Result<Bitmap?>) -> Unit) {
        val request = Request.Builder()
            .url(BuildConfig.API_BASE_URL + API_V2 + "/tracks/stats-card")
            .post(jsonBody(StatsCardRequestJson(trackIds, width, height, if (dark) "dark" else "light")))
            .build()
        client.newCall(request).enqueue(object : Callback {
            override fun onFailure(call: Call, e: IOException) {
                main.post { onResult(Result.failure(e)) }
            }

            override fun onResponse(call: Call, response: Response) {
                if (refusedBuild(response)) return response.close()
                val result = response.use {
                    runCatching {
                        when {
                            it.code == 204 -> null
                            !it.isSuccessful -> throw ApiException.from(it.code, it.body.string())
                            else -> it.body.bytes().let { bytes -> BitmapFactory.decodeByteArray(bytes, 0, bytes.size) }
                                ?: throw IOException("not an image")
                        }
                    }
                }
                main.post { onResult(result) }
            }
        })
    }

    /** `DELETE /v2/tracks/{id}` (`docs/IMPLEMENTATION.md` §4.7.5) — the track, its
     *  track and its share of Fog coverage, for good. */
    fun deleteTrack(id: String, onResult: (Result<Unit>) -> Unit) {
        val request = Request.Builder().url(v2("tracks", id)).delete().build()
        call(request, { }) { onResult(deleteDone(it)) }
    }

    /**
     * `GET /v2/coverage/status` — whether the account still has a job that changes its Fog
     * tiles, and its map version. What the map polls after a delete or a reprocess, to
     * know when to fetch those tiles again (`map/CoverageWatch`).
     */
    fun coverageStatus(onResult: (Result<CoverageStatus>) -> Unit) {
        val request = Request.Builder().url(BuildConfig.API_BASE_URL + API_V2 + "/coverage/status").build()
        call(request, { text ->
            val json = decode<CoverageStatusJson>(text)
            CoverageStatus(json.rendering, json.version, json.tileVersion, json.explored?.let { Explored(it.countries, it.regions, it.counties, it.cities) })
        }, onResult)
    }

    /**
     * `GET /v2/map/layers` (ADR-0048) — every layer drawn over the basemap, at the account's tile
     * version: the document's text and ETag, or null while [etag] is still current (`304`).
     */
    fun mapLayers(flavor: String, etag: String?, onResult: (Result<MapLayersResponse?>) -> Unit) {
        val url = (BuildConfig.API_BASE_URL + API_V2 + "/map/layers").toHttpUrl().newBuilder()
            .addQueryParameter("flavor", flavor)
            .build()
        val request = Request.Builder().url(url).apply { etag?.let { header("If-None-Match", it) } }.build()
        client.newCall(request).enqueue(object : Callback {
            override fun onFailure(call: Call, e: IOException) {
                main.post { onResult(Result.failure(e)) }
            }

            override fun onResponse(call: Call, response: Response) {
                val body = readBody(response).getOrElse {
                    main.post { onResult(Result.failure(it)) }
                    return
                }
                if (refusedBuild(response)) return
                val result = when {
                    response.code == 304 -> Result.success(null)
                    response.isSuccessful -> Result.success(MapLayersResponse(body, response.header("ETag")))
                    else -> Result.failure(ApiException.from(response.code, body))
                }
                main.post { onResult(result) }
            }
        })
    }

    /** `GET /v2/spots` (`docs/IMPLEMENTATION.md` §4.25) — [categories]' places whose anchor is
     *  inside the box, named first, up to the server's 2,000. */
    fun spotsInArea(
        west: Double, south: Double, east: Double, north: Double,
        categories: List<String>,
        onResult: (Result<SpotsInArea>) -> Unit,
    ) {
        val url = (BuildConfig.API_BASE_URL + API_V2 + "/spots").toHttpUrl().newBuilder()
            .addQueryParameter("bbox", listOf(west, south, east, north).joinToString(",") { "%.5f".format(java.util.Locale.ROOT, it) })
            .addQueryParameter("categories", categories.joinToString(","))
            .build()
        call(Request.Builder().url(url).build(), { text ->
            val json = decode<SpotsInAreaJson>(text)
            SpotsInArea(json.spots.map { it.toSpot() }, json.total)
        }, onResult)
    }

    /** `GET /v2/spots/{id}` (`docs/IMPLEMENTATION.md` §4.25) — see [SpotDetail]. */
    fun spotDetail(id: Long, onResult: (Result<SpotDetail>) -> Unit) {
        call(Request.Builder().url(v2("spots", id.toString())).build(), { text ->
            val json = decode<SpotDetailJson>(text)
            SpotDetail(
                spot = Spot(json.id, json.category, json.name, json.address, json.description, json.inscription, json.memorial, json.startDate, json.wikipedia, json.lon, json.lat),
                area = json.area.coordinates.map { polygon -> polygon.map { ring -> ring.map { GeoPoint(lat = it[1], lon = it[0]) } } },
                capturedAt = json.capturedAt?.let(::parseInstant),
            )
        }, onResult)
    }

    /** `GET /v2/spots/captures` — every place the account has captured, newest first; with
     *  [since], only those captured at or after it. */
    fun spotCaptures(since: Instant?, onResult: (Result<List<SpotCapture>>) -> Unit) {
        val url = (BuildConfig.API_BASE_URL + API_V2 + "/spots/captures").toHttpUrl().newBuilder()
        if (since != null) url.addQueryParameter("since", since.toString())
        call(Request.Builder().url(url.build()).build(), { text -> decode<SpotCapturesJson>(text).captures.map { it.toSpotCapture() } }, onResult)
    }

    /** `POST /v2/spots/{id}/captures` — captures the place at the position last measured inside
     *  it; the server checks it against the area. A place already captured answers the first
     *  capture. Outside the area is an [ApiException] with code 422. */
    fun captureSpot(id: Long, lat: Double, lon: Double, onResult: (Result<SpotCapture>) -> Unit) {
        val request = Request.Builder()
            .url(v2("spots", id.toString(), "captures"))
            .post(jsonBody(SpotCaptureRequestJson(lat, lon)))
            .build()
        call(request, { text -> decode<SpotCaptureJson>(text).toSpotCapture() }, onResult)
    }

    private fun SpotCaptureJson.toSpotCapture() = SpotCapture(spotId, parseInstant(capturedAt))

    private fun parseInstant(text: String): Instant = OffsetDateTime.parse(text).toInstant()

    private fun SpotJson.toSpot() = Spot(id, category, name, address, description, inscription, memorial, startDate, wikipedia, lon, lat)

    /** `GET /v2/tracks/{id}/route-metrics` (`docs/IMPLEMENTATION.md` §4.3.1) — see
     *  [RouteMetrics]. */
    fun trackMetrics(id: String, onResult: (Result<RouteMetrics>) -> Unit) {
        val request = Request.Builder().url(v2("tracks", id, "route-metrics")).build()
        call(request, { text ->
            val json = decode<RouteMetricsJson>(text)
            RouteMetrics(
                json.trackId,
                json.points.map { TrackMetricPoint(it.lon, it.lat, it.speedMps, it.timeS) },
                json.bands.map { PaceBand(it.band, it.start, it.end) },
            )
        }, onResult)
    }

    /** `GET /v2/tracks/{id}/route-points` — the recorded points, unedited and with any
     *  Private location already clipped off, and the saved edit. A refusal (`409`: no
     *  recording kept, points without times) is the server's own wording. */
    fun trackPoints(id: String, onResult: (Result<RoutePoints>) -> Unit) {
        val request = Request.Builder().url(v2("tracks", id, "route-points")).build()
        call(request, { text ->
            val json = decode<RoutePointsJson>(text)
            RoutePoints(json.points.map { RoutePoint(it[0], it[1], it[2].toLong()) }, json.edit?.toRouteEdit())
        }, onResult)
    }

    /**
     * `POST /v2/tracks/{id}/route-edit` — the whole new edit, or null (or an empty one) to
     * go back to the track as recorded, and [splitAt], a point's time, to also split the track
     * there (`docs/SPEC.md` FR-5.9). The server answers `202` and reprocesses it in the
     * background, the track Pending meanwhile; `409` when a reprocess is already running; a
     * `422` [SPLIT_HIDES_PART] for a split that would leave a part inside a Private location,
     * which goes ahead when sent again with [allowHidden].
     */
    fun routeEdit(id: String, edit: RouteEdit?, splitAt: Long? = null, allowHidden: Boolean = false, onResult: (Result<Unit>) -> Unit) {
        val body = RouteEditRequestJson(edit?.toJson(), splitAt, allowHidden = splitAt != null && allowHidden)
        val request = Request.Builder()
            .url(v2("tracks", id, "route-edit"))
            .post(jsonBody(body))
            .build()
        call(request, { }, onResult)
    }

    private fun RouteEditJson.toRouteEdit() = RouteEdit(
        keep = keep?.let { it[0] to it[1] },
        remove = remove.orEmpty().map { it[0] to it[1] },
        drop = drop.orEmpty(),
        // Keyed by time, which JSON can only carry as an object key.
        move = move.orEmpty().entries.associate { (t, at) -> t.toLong() to (at[0] to at[1]) },
    )

    private fun RouteEdit.toJson() = RouteEditJson(
        keep = keep?.let { listOf(it.first, it.second) },
        remove = remove.map { listOf(it.first, it.second) }.ifEmpty { null },
        drop = drop.ifEmpty { null },
        move = move.entries.associate { (t, at) -> t.toString() to listOf(at.first, at.second) }.ifEmpty { null },
    )

    /**
     * `GET /v2/photos?track=` or `?trip=` (`docs/SPEC.md` FR-15.3) — one track's photos,
     * or every photo of a Trip's tracks, in route order. Exactly one of the two is given.
     */
    fun photos(track: String?, trip: String?, onResult: (Result<List<Photo>>) -> Unit) {
        val url = (BuildConfig.API_BASE_URL + API_V2 + "/photos").toHttpUrl().newBuilder()
            .apply { if (track != null) addQueryParameter("track", track) }
            .apply { if (trip != null) addQueryParameter("trip", trip) }
            .build()
        call(Request.Builder().url(url).build(), { text -> decode<PhotosJson>(text).photos.map { it.toPhoto() } }, onResult)
    }

    /**
     * `POST /v2/photos/place` (FR-15.1) — where an upload of a photo with this EXIF would be
     * placed on [trackId]'s track, storing nothing: its `route_at`. A
     * [PhotoNeedsPlaceException] when the server can't tell, for the user to choose.
     */
    fun checkPhotoPlace(trackId: String, exif: PhotoExif, onResult: (Result<Instant>) -> Unit) {
        val placed = exif.lat != null && exif.lon != null
        val body = PhotoPlaceRequestJson(
            trackId = trackId,
            takenAt = exif.takenAt?.toString(),
            takenLocal = exif.takenLocal.takeIf { exif.takenAt == null },
            lat = exif.lat.takeIf { placed },
            lon = exif.lon.takeIf { placed },
        )
        val request = Request.Builder()
            .url(BuildConfig.API_BASE_URL + API_V2 + "/photos/place")
            .post(jsonBody(body))
            .build()
        call(request, { text -> parseInstant(decode<PhotoPlaceJson>(text).routeAt) }) { result ->
            onResult(result.recoverCatching { throw needsPlace(it) })
        }
    }

    /**
     * `POST /v2/photos` (FR-15.1) — a photo already resized ([file] and its [thumb]), what its
     * EXIF said, where on the track it goes ([routeAt]: the placement check's answer or the
     * user's, which wins at upload) and its [caption]. Answers with the photo as stored.
     */
    fun uploadPhoto(
        trackId: String,
        file: PhotoImage,
        thumb: PhotoImage,
        exif: PhotoExif,
        routeAt: Instant,
        caption: String,
        onResult: (Result<Photo>) -> Unit,
    ) {
        val body = MultipartBody.Builder()
            .setType(MultipartBody.FORM)
            .addFormDataPart("track_id", trackId)
            .addFormDataPart("file", "photo", file.file.asRequestBody(file.contentType.toMediaType()))
            .addFormDataPart("thumb", "thumb", thumb.file.asRequestBody(thumb.contentType.toMediaType()))
            .apply {
                if (exif.takenAt != null) addFormDataPart("taken_at", exif.takenAt.toString())
                else exif.takenLocal?.let { addFormDataPart("taken_local", it) }
                if (exif.lat != null && exif.lon != null) {
                    addFormDataPart("lat", exif.lat.toString())
                    addFormDataPart("lon", exif.lon.toString())
                }
                addFormDataPart("route_at", routeAt.toString())
                if (caption.isNotEmpty()) addFormDataPart("caption", caption)
            }
            .build()
        val request = Request.Builder().url(BuildConfig.API_BASE_URL + API_V2 + "/photos").post(body).build()
        call(request, { text -> decode<PhotoJson>(text).toPhoto() }) { result ->
            onResult(result.recoverCatching { throw needsPlace(it) })
        }
    }

    /** `PATCH /v2/photos/{id}` (FR-15.4) — a field given changes: [caption] (empty clears it),
     *  [routeAt] the photo's new moment on its track, which the server clamps to the track. */
    fun updatePhoto(id: String, caption: String?, routeAt: Instant?, onResult: (Result<Photo>) -> Unit) {
        val request = Request.Builder()
            .url(v2("photos", id))
            .patch(jsonBody(PhotoPatchJson(caption, routeAt?.toString())))
            .build()
        call(request, { text -> decode<PhotoJson>(text).toPhoto() }, onResult)
    }

    /** `DELETE /v2/photos/{id}` (FR-15.5) — the photo and both its images. */
    fun deletePhoto(id: String, onResult: (Result<Unit>) -> Unit) {
        val request = Request.Builder().url(v2("photos", id)).delete().build()
        call(request, { }) { result ->
            val done = deleteDone(result)
            if (done.isSuccess) forgetPhoto(id)
            onResult(done)
        }
    }

    /** `photo_needs_place` as its own exception, so the Photos tab can tell it from a failure. */
    private fun needsPlace(failure: Throwable): Throwable =
        if (failure is ApiException && failure.code == 422 && failure.errorCode == "photo_needs_place") {
            PhotoNeedsPlaceException(failure.message.orEmpty())
        } else {
            failure
        }

    private fun PhotoJson.toPhoto() = Photo(
        id = id,
        trackId = trackId,
        takenAt = takenAt?.let(::parseInstant),
        routeAt = parseInstant(routeAt),
        lon = lon,
        lat = lat,
        caption = caption?.takeIf { it.isNotEmpty() },
        width = width,
        height = height,
        url = url,
        thumbUrl = thumbUrl,
        timezone = timezone,
    )

    /** `GET /v2/private-locations` — every one, newest first. */
    fun privateLocations(onResult: (Result<List<PrivateLocation>>) -> Unit) {
        val request = Request.Builder().url(BuildConfig.API_BASE_URL + API_V2 + "/private-locations").build()
        call(request, { text -> decode<List<PrivateLocationJson>>(text).map { it.toPrivateLocation() } }, onResult)
    }

    /** `GET /v2/private-locations/hidden` — how many of the account's tracks they hide entirely. */
    fun hiddenTrackCount(onResult: (Result<Int>) -> Unit) {
        val request = Request.Builder().url(BuildConfig.API_BASE_URL + API_V2 + "/private-locations/hidden").build()
        call(request, { text -> decode<HiddenTracksJson>(text).count }, onResult)
    }

    /**
     * `POST /v2/private-locations`, or with [id] `PATCH /v2/private-locations/{id}` — the
     * whole circle either way. Answers with it as saved (the name trimmed). A refusal — a
     * radius or place out of range, a 21st location, the demo account — is the server's own
     * wording, in the app's language.
     */
    fun savePrivateLocation(
        id: String?,
        name: String,
        lon: Double,
        lat: Double,
        radiusM: Int,
        onResult: (Result<PrivateLocation>) -> Unit,
    ) {
        val body = jsonBody(PrivateLocationInputJson(name, lon, lat, radiusM))
        val url = if (id == null) v2("private-locations") else v2("private-locations", id)
        val request = Request.Builder().url(url).apply { if (id == null) post(body) else patch(body) }.build()
        call(request, { text -> decode<PrivateLocationJson>(text).toPrivateLocation() }, onResult)
    }

    /** `DELETE /v2/private-locations/{id}`. */
    fun deletePrivateLocation(id: String, onResult: (Result<Unit>) -> Unit) {
        val request = Request.Builder().url(v2("private-locations", id)).delete().build()
        call(request, { }) { onResult(deleteDone(it)) }
    }

    private fun PrivateLocationJson.toPrivateLocation() = PrivateLocation(id, name, lon, lat, radiusM)

    /** `GET /v2/trips` — every Trip of the account, newest first (`docs/SPEC.md` FR-13). */
    fun trips(onResult: (Result<List<Trip>>) -> Unit) {
        val request = Request.Builder().url(BuildConfig.API_BASE_URL + API_V2 + "/trips").build()
        call(request, { text -> decode<TripsJson>(text).trips.map { it.toTrip() } }, onResult)
    }

    /** `GET /v2/trips/{id}` — one Trip. A `404` ([ApiException]) is one that doesn't exist
     *  or isn't this account's, which the server doesn't tell apart (FR-13.5). */
    fun trip(id: String, onResult: (Result<Trip>) -> Unit) {
        val request = Request.Builder().url(v2("trips", id)).build()
        call(request, { text -> decode<TripJson>(text).toTrip() }, onResult)
    }

    /** `POST /v2/trips` — a new Trip with [trackIds] in it, in one step (FR-13.2). A
     *  refusal (a blank or long name, a demo account) is the server's own wording. */
    fun createTrip(name: String, description: String, trackIds: Collection<String>, onResult: (Result<Trip>) -> Unit) {
        val request = Request.Builder()
            .url(BuildConfig.API_BASE_URL + API_V2 + "/trips")
            .post(jsonBody(TripCreateJson(name, description, trackIds.toList())))
            .build()
        call(request, { text -> decode<TripJson>(text).toTrip() }, onResult)
    }

    /** `PATCH /v2/trips/{id}` — both fields every time: an empty [description] clears it. */
    fun updateTrip(id: String, name: String, description: String, onResult: (Result<Trip>) -> Unit) {
        val request = Request.Builder()
            .url(v2("trips", id))
            .patch(jsonBody(TripInputJson(name, description)))
            .build()
        call(request, { text -> decode<TripJson>(text).toTrip() }, onResult)
    }

    /** `DELETE /v2/trips/{id}` — the Trip alone; its tracks stay. */
    fun deleteTrip(id: String, onResult: (Result<Unit>) -> Unit) {
        val request = Request.Builder().url(v2("trips", id)).delete().build()
        call(request, { }) { onResult(deleteDone(it)) }
    }

    /** `POST` ([add]) or `DELETE /v2/trips/{id}/tracks` with [trackIds] (FR-13.3): puts
     *  them in the Trip, or takes them out. Answers with the Trip as it now is. */
    fun changeTripTracks(id: String, trackIds: Collection<String>, add: Boolean, onResult: (Result<Trip>) -> Unit) {
        val body = jsonBody(TripTracksJson(trackIds.toList()))
        val request = Request.Builder()
            .url(v2("trips", id, "tracks"))
            .apply { if (add) post(body) else delete(body) }
            .build()
        call(request, { text -> decode<TripJson>(text).toTrip() }, onResult)
    }

    /** `POST /v2/trips/{id}/send` — a copy of the Trip to [email] (FR-13.7). Succeeds
     *  whether or not the address has an account: the server never says. */
    fun sendTrip(id: String, email: String, onResult: (Result<Unit>) -> Unit) {
        val request = Request.Builder()
            .url(v2("trips", id, "send"))
            .post(jsonBody(EmailJson(email)))
            .build()
        call(request, { }, onResult)
    }

    /** `GET /v2/trip-sends` — the Trips tab's inbox. */
    fun tripSends(onResult: (Result<TripInbox>) -> Unit) {
        val request = Request.Builder().url(BuildConfig.API_BASE_URL + API_V2 + "/trip-sends").build()
        call(request, { text ->
            val json = decode<TripInboxJson>(text)
            TripInbox(
                sends = json.sends.map { TripSend(it.id, it.tripName, it.from, it.trackCount) },
                copying = json.copying.map { TripCopying(it.tripName, it.from) },
            )
        }, onResult)
    }

    /** `POST /v2/trip-sends/{id}/accept` ([accept]) or `DELETE /v2/trip-sends/{id}` (decline). */
    fun answerTripSend(id: String, accept: Boolean, onResult: (Result<Unit>) -> Unit) {
        val url = if (accept) v2("trip-sends", id, "accept") else v2("trip-sends", id)
        val request = Request.Builder().url(url)
            .apply { if (accept) post(EMPTY_BODY) else delete() }
            .build()
        call(request, { }, onResult)
    }

    private fun TripJson.toTrip(): Trip {
        TrackTypes.merge(stats.byType.filter { it.label.isNotEmpty() }.associate { it.trackType to TrackTypes.Info(null, it.label) })
        return toTripOnly()
    }

    private fun TripJson.toTripOnly() = Trip(
        id = id,
        name = name,
        description = description.orEmpty(),
        from = from,
        trackIds = trackIds,
        stats = TripTotals("", stats.count, stats.distanceMeters, stats.movingSeconds),
        byType = stats.byType.map { TripTotals(it.trackType, it.count, it.distanceMeters, it.movingSeconds) },
    )

    private fun AreaTrackRowJson.toTrack() = Track(
        id = id,
        startedAt = startedAt,
        trackType = trackType,
        timezone = timezone,
        name = name,
        distanceMeters = distanceMeters,
        movingSeconds = movingSeconds,
        description = null,
        bbox = bbox?.takeIf { it.size == 4 },
        pending = pending,
        edited = false,
        isPrivate = private,
        trips = trips.map { TripRef(it.id, it.name) },
    )

    private fun TrackRowJson.toTrack() = Track(
        id = id,
        startedAt = startedAt,
        trackType = trackType,
        timezone = timezone,
        name = name,
        distanceMeters = distanceMeters,
        movingSeconds = movingSeconds,
        description = description,
        bbox = bbox?.takeIf { it.size == 4 },
        pending = pending,
        edited = edited,
        isPrivate = private,
        routeEdit = routeEdit,
        photos = photos,
        trips = trips.map { TripRef(it.id, it.name) },
    )

    private fun AccountJson.toProfile() =
        Profile(email, isDemo, emailVerified, displayName, country, timezone, locale, avatarUrl, imperial = unitSystem == "imperial")

    private fun ExportStatusJson.toExportStatus() = ExportStatus(
        state = state,
        expiresAt = expiresAt?.let(::parseInstant),
        totalSize = totalSize,
        parts = parts.map { ExportPart(it.n, it.size, it.name, it.url) },
    )

    /**
     * `GET /v2/tracks/histogram?days=&before=` — one page of the days that have track
     * (`docs/IMPLEMENTATION.md` §4.7's track-day pagination mode): the [limit] most recent,
     * or the [limit] most recent strictly before [before]. The newest day and the account's first
     * are the Dates filter's bounds (`map/AreaController`).
     */
    fun trackDayPage(limit: Int, before: String?, onResult: (Result<TrackDayPage>) -> Unit) {
        val url = (BuildConfig.API_BASE_URL + API_V2 + "/tracks/histogram").toHttpUrl().newBuilder()
            .addQueryParameter("days", limit.toString())
            .apply { if (before != null) addQueryParameter("before", before) }
            .build()
        call(Request.Builder().url(url).build(), ::parseTrackDays, onResult)
    }

    /**
     * `GET /v2/tracks/histogram?from=&to=` — every day with track in a calendar window,
     * both ends inclusive (`docs/IMPLEMENTATION.md` §4.8). Profile asks for everything up to the
     * end of this year in one call, the same single query the web's page runs for its grids.
     */
    fun trackDays(from: String, to: String, onResult: (Result<TrackDayPage>) -> Unit) {
        val url = (BuildConfig.API_BASE_URL + API_V2 + "/tracks/histogram").toHttpUrl().newBuilder()
            .addQueryParameter("from", from)
            .addQueryParameter("to", to)
            .build()
        call(Request.Builder().url(url).build(), ::parseTrackDays, onResult)
    }

    private fun parseTrackDays(body: String): TrackDayPage {
        val json = decode<HistogramJson>(body)
        return TrackDayPage(json.buckets.map { TrackDay(it.date, it.count, it.distanceMeters) }, json.earliest?.ifEmpty { null })
    }

    /**
     * How many of the account's tracks use each `track_type` — what the recording Edit screen's
     * Type picker lists, the same per-type counts the web client's Type facet is built from.
     * Read from the same unpaginated `GET /v2/tracks` as [tracks], since there is
     * no dedicated facets endpoint and this list already carries every live row.
     */
    fun trackTypeCounts(onResult: (Result<Map<String, Int>>) -> Unit) {
        val request = Request.Builder().url(BuildConfig.API_BASE_URL + API_V2 + "/tracks").build()
        call(request, { body ->
            val decoded = decode<TracksJson>(body)
            TrackTypes.merge(decoded.types.described())
            buildMap {
                for (row in decoded.tracks) {
                    if (row.trackType.isNotEmpty()) merge(row.trackType, 1, Int::plus)
                }
            }
        }, onResult)
    }

    /** Each row of a `GET /v2/tracks` body the tracks tile draws — one with a bbox and
     *  not Pending — with that bbox as `[minLon, minLat, maxLon, maxLat]`. */

    /** A response body as its wire class (Wire.kt). */
    private inline fun <reified T> decode(text: String): T = apiJson.decodeFromString(text)

    /** A request body from its wire class (Wire.kt). */
    private inline fun <reified T> jsonBody(value: T): RequestBody = apiJson.encodeToString(value).toRequestBody(JSON)

    private val EMPTY_BODY: RequestBody = ByteArray(0).toRequestBody(null, 0, 0)

    /**
     * Every endpoint that mints a session answers with the same body, and all of them carry
     * `session_token` — the field a browser ignores (it already has the credential as a
     * `Set-Cookie`) and a native client exists to read.
     */
    private fun authenticate(path: String, body: RequestBody, onResult: (Result<Account>) -> Unit) {
        val request = Request.Builder().url(BuildConfig.API_BASE_URL + API_V2 + path).post(body).build()
        call(request, { text ->
            val token = decode<SessionTokenJson>(text).sessionToken
            if (token.isEmpty()) throw IOException("the server returned no session token")
            Account(token = token, profile = decode<AccountJson>(text).toProfile())
        }, onResult)
    }

    private fun <T> call(request: Request, parse: (String) -> T, onResult: (Result<T>) -> Unit) {
        client.newCall(request).enqueue(object : Callback {
            override fun onFailure(call: Call, e: IOException) {
                deliver(Result.failure(e))
            }

            override fun onResponse(call: Call, response: Response) {
                val body = readBody(response).getOrElse {
                    deliver(Result.failure(it))
                    return
                }
                if (refusedBuild(response)) return
                deliver(
                    if (response.isSuccessful) runCatching { parse(body) }
                    else Result.failure(ApiException.from(response.code, body)),
                )
            }

            private fun deliver(result: Result<T>) {
                main.post { onResult(result) }
            }
        })
    }
}

/** What `GET /v2/map/layers` answered: the document, and its ETag to revalidate with. */
data class MapLayersResponse(val text: String, val etag: String?)

/** One time span asked about in [HoldMyTrackApi.trackOverlaps], under the caller's [key]. */
data class OverlapSpan(val key: String, val start: Instant, val end: Instant)

/** The live track a span overlaps: its [id], to open it on the map, its [name] (empty when it
 *  has none) and type, and its start in the zone it was recorded in, which titles it when it has
 *  no name and gives the day the map opens on. */
data class TrackOverlap(val id: String, val name: String, val trackType: String, val startedAt: String, val timezone: String?)
