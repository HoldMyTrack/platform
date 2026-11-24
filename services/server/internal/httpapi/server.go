// Package httpapi is cmd/holdmytrack serve: the JSON API, the tile endpoints and the
// server-rendered pages. Routing is stdlib net/http's ServeMux method+pattern matching, with
// no router dependency; the database is pgx directly, with no ORM.
package httpapi

import (
	"context"
	"encoding/json"
	"log/slog"
	"net/http"
	"runtime"
	"runtime/debug"
	"strings"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/HoldMyTrack/platform/services/server/internal/budget"
	"github.com/HoldMyTrack/platform/services/server/internal/config"
	"github.com/HoldMyTrack/platform/services/server/internal/mail"
	"github.com/HoldMyTrack/platform/services/server/internal/mapstyle"
	"github.com/HoldMyTrack/platform/services/server/internal/metrics"
	"github.com/HoldMyTrack/platform/services/server/internal/storage"
	"github.com/HoldMyTrack/platform/services/server/internal/web"
)

// devOrigins lists the origins a credentialed cross-origin request may come from in local
// development, where the app's dev server and the API are separate origins: a cookie session
// rules out "*" (serve's doc comment). apps/web's dev server (5173), and the dev servers
// apps/web/tests/smoke.mjs, flows.mjs and build.mjs spawn for themselves (5180, 5181, 4183), so
// those suites sign in as a real browser does. A deployment serves the app from its own origin
// and allows none of them: a page on a visitor's own localhost:5173, some other project's dev
// server, could otherwise post to the API as a trusted origin.
var devOrigins = map[string]bool{
	"http://localhost:5173": true,
	"http://localhost:5180": true,
	"http://localhost:5181": true,
	"http://localhost:4183": true,
}

// apiPrefix and tilesPrefix are where the API's major version lives: route() and tileRoute()
// register under them.
const apiPrefix = "/v2"
const tilesPrefix = "/tiles/v1"

func route(method, path string) string     { return method + " " + apiPrefix + path }
func tileRoute(method, path string) string { return method + " " + tilesPrefix + path }

type Server struct {
	pool   *pgxpool.Pool
	store  *storage.Store
	log    *slog.Logger
	mux    *http.ServeMux
	mailer mail.Sender
	// afterResponse runs work whose length would tell a caller something, once
	// the handler has returned: on its own goroutine, or inline in tests that read its mail.
	afterResponse func(func())
	appBaseURL    string
	// corsOrigins is devOrigins in local development, none on a deployment.
	corsOrigins map[string]bool
	// csp is every response's Content-Security-Policy (csp.go), and cspParts what it's built from,
	// for a page that adds a widget's origin (renderAuthPage).
	csp                   string
	cspParts              cspParts
	basemapOrigin         string
	satellite             mapstyle.Satellite
	imagery               imageryCache
	version               string
	skipEmailVerification bool
	google                googleOAuth
	facebook              facebookOAuth
	// visitors counts unique web visitors (visitors.go); nil without a database.
	visitors      *visitorCounter
	apple         appleOAuth
	turnstile     turnstile
	pages         *web.Renderer
	uploadLimiter *fixedWindowLimiter
	// fileChecks bounds the uploads parsed at once, fileWaits those holding or waiting for a
	// parse (checkUpload).
	fileChecks         chan struct{}
	fileWaits          chan struct{}
	tileLimiter        *fixedWindowLimiter
	syncLimiter        *fixedWindowLimiter
	routePointsLimiter *fixedWindowLimiter
	gpxLimiter         *fixedWindowLimiter
	statsCardLimiter   *fixedWindowLimiter
	syncTrackLimiter   *fixedWindowLimiter
	signupLimiter      *fixedWindowLimiter
	googleNonceLimiter *fixedWindowLimiter
	budget             *budget.Gate
	minAndroidBuild    int
	minIOSBuild        int
}

// defaultUploadsPerHour is how many files one account may send to `POST /v2/tracks/upload`
// in an hour: five of the clients' 20-file batches, plenty to bring a season in by hand, and a
// stop to a script pouring a whole archive in one file at a time (ADR-0039). UPLOADS_PER_HOUR
// overrides it, for a load test's target.
const defaultUploadsPerHour = 100

func New(pool *pgxpool.Pool, store *storage.Store, log *slog.Logger, mailer mail.Sender, appBaseURL, basemapOrigin string, satellite mapstyle.Satellite, version string, skipEmailVerification bool, google GoogleOAuthConfig, facebook FacebookOAuthConfig, apple AppleOAuthConfig, pages *web.Renderer) *Server {
	s := &Server{
		pool: pool, store: store, log: log, mux: http.NewServeMux(), mailer: mailer,
		afterResponse: func(f func()) { go f() },
		appBaseURL:    appBaseURL, basemapOrigin: basemapOrigin, satellite: satellite, version: version,
		skipEmailVerification: skipEmailVerification,
		corsOrigins:           map[string]bool{},
		google:                newGoogleOAuth(google),
		facebook:              newFacebookOAuth(facebook),
		apple:                 newAppleOAuth(apple),
		pages:                 pages,
		uploadLimiter:         newFixedWindowLimiter(defaultUploadsPerHour, time.Hour),
		fileChecks:            make(chan struct{}, runtime.GOMAXPROCS(0)),
		fileWaits:             make(chan struct{}, 4*runtime.GOMAXPROCS(0)),
		tileLimiter:           newFixedWindowLimiter(defaultTilesPerMinute, time.Minute),
		syncLimiter:           newFixedWindowLimiter(syncRequestsPerHour, time.Hour),
		routePointsLimiter:    newFixedWindowLimiter(routePointsPerHour, time.Hour),
		gpxLimiter:            newFixedWindowLimiter(gpxDownloadsPerHour, time.Hour),
		statsCardLimiter:      newFixedWindowLimiter(statsCardsPerHour, time.Hour),
		syncTrackLimiter:      newFixedWindowLimiter(syncTracksPerHour, time.Hour),
		signupLimiter:         newFixedWindowLimiter(defaultSignupsPerHour, time.Hour),
		googleNonceLimiter:    newFixedWindowLimiter(googleNoncesPerHour, time.Hour),
	}
	local := config.IsLocal(appBaseURL)
	if local {
		s.corsOrigins = devOrigins
	}
	s.cspParts = cspParts{assets: assetOrigins(appBaseURL, basemapOrigin, satellite.Tiles), local: local}
	s.csp = contentSecurityPolicy(s.cspParts)
	if pool != nil {
		s.visitors = &visitorCounter{pool: pool, log: log}
	}
	s.registerPages()
	s.mux.HandleFunc(route("POST", "/auth/signup"), s.handleSignup)
	s.mux.HandleFunc(route("POST", "/auth/login"), s.handleLogin)
	s.mux.HandleFunc(route("POST", "/auth/logout"), s.handleLogout)
	s.mux.HandleFunc(route("GET", "/auth/me"), s.handleMe)
	s.mux.HandleFunc(route("POST", "/auth/demo"), s.handleDemoStart)
	s.mux.HandleFunc(route("POST", "/auth/forgot-password"), s.handleForgotPassword)
	s.mux.HandleFunc(route("POST", "/auth/reset-password"), s.handleResetPassword)
	s.mux.HandleFunc(route("POST", "/auth/verify-email"), s.handleVerifyEmail)
	// Sign in with Google (google_auth.go) and Facebook (facebook_auth.go) — GET, not POST:
	// start and callback are all full-page browser navigations, not fetch() calls.
	s.mux.HandleFunc(route("GET", "/auth/providers"), s.handleAuthProviders)
	s.mux.HandleFunc(route("GET", "/auth/google/start"), s.handleGoogleStart)
	s.mux.HandleFunc(route("GET", "/auth/google/callback"), s.handleGoogleCallback)
	s.mux.HandleFunc(route("GET", "/auth/facebook/start"), s.handleFacebookStart)
	s.mux.HandleFunc(route("GET", "/auth/facebook/callback"), s.handleFacebookCallback)
	// Apple posts the browser back (apple_auth.go), so its callback is the one POST here.
	s.mux.HandleFunc(route("GET", "/auth/apple/start"), s.handleAppleStart)
	s.mux.HandleFunc(route("POST", "/auth/apple/callback"), s.handleAppleCallback)
	s.mux.HandleFunc(route("POST", "/auth/apple/notifications"), s.handleAppleNotifications)
	// Native clients (docs/IMPLEMENTATION.md §4.9): an id_token from Android's Credential
	// Manager, and the one-time code a browser-tab round trip above ends with for an app.
	s.mux.HandleFunc(route("POST", "/auth/google/nonce"), s.handleGoogleNonce)
	s.mux.HandleFunc(route("POST", "/auth/google/token"), s.handleGoogleToken)
	s.mux.HandleFunc(route("POST", "/auth/apple/token"), s.handleAppleToken)
	s.mux.HandleFunc(route("POST", "/auth/handoff"), s.handleAuthHandoff)
	// Plain requireAuth, not requireVerified — these two exist specifically to help an
	// account that hasn't verified yet (auth_email.go's own doc comments on each).
	s.mux.HandleFunc(route("POST", "/auth/resend-verification"), s.requireAuth(s.handleResendVerification))
	s.mux.HandleFunc(route("PATCH", "/auth/email"), s.requireAuth(s.handleChangeEmail))
	s.mux.HandleFunc(route("POST", "/auth/verify-code"), s.requireAuth(s.handleVerifyCode))
	// requireNotDemo below: account and track changes a demo account must never reach
	// (docs/SPEC.md FR-2.1). requireVerified alone covers everything else a signed-in but
	// unverified real account must not reach yet.
	s.mux.HandleFunc(route("PATCH", "/account/settings"), s.requireNotDemo(s.handleUpdateSettings))
	// Readable by a demo session, whose Settings screen shows the fields, disabled.
	s.mux.HandleFunc(route("GET", "/account/settings/options"), s.requireVerified(s.handleSettingsOptions))
	s.mux.HandleFunc(route("POST", "/account/avatar"), s.requireNotDemo(s.handleUploadAvatar))
	s.mux.HandleFunc(route("GET", "/account/avatar"), s.requireVerified(s.budgeted(budget.ReadsPaused, s.handleGetAvatar)))
	s.mux.HandleFunc(route("DELETE", "/account/avatar"), s.requireNotDemo(s.handleDeleteAvatar))
	// requireAuth alone: an unverified account can be deleted too. closeAccount refuses a demo.
	s.mux.HandleFunc(route("DELETE", "/account"), s.requireAuth(s.handleDeleteAccount))
	// exports.go — downloading your data. A demo session sees "none" and is refused a request.
	s.mux.HandleFunc(route("POST", "/account/export"), s.requireNotDemo(s.handleRequestExport))
	s.mux.HandleFunc(route("GET", "/account/export"), s.requireVerified(s.handleGetExport))
	s.mux.HandleFunc(route("GET", "/account/exports/{id}/parts/{n}"), s.requireVerified(s.budgeted(budget.ReadsPaused, s.handleDownloadExportPart)))
	s.mux.HandleFunc(route("POST", "/account/exports/{id}/parts/{n}/link"), s.requireVerified(s.handleCreateExportLink))
	// No session: the link's token is the credential (handleCreateExportLink).
	s.mux.HandleFunc(route("GET", "/export-downloads/{token}"), s.budgeted(budget.ReadsPaused, s.handleDownloadExportLink))
	s.mux.HandleFunc(route("POST", "/tracks/upload"), s.requireNotDemo(s.budgeted(budget.AddingPaused, s.handleUpload)))
	s.mux.HandleFunc(route("GET", "/tracks"), s.requireVerified(s.handleListTracks))
	s.mux.HandleFunc(route("GET", "/tracks/area"), s.requireVerified(s.handleListArea))
	s.mux.HandleFunc(route("GET", "/tracks/gpx"), s.requireVerified(s.budgeted(budget.ReadsPaused, s.handleTracksGPX)))
	s.mux.HandleFunc(route("GET", "/tracks/{id}"), s.requireVerified(s.handleGetTrack))
	s.mux.HandleFunc(route("GET", "/track-types"), s.requireVerified(s.handleTrackTypes))
	s.mux.HandleFunc(route("PATCH", "/tracks/{id}"), s.requireNotDemo(s.handleUpdateTrack))
	s.mux.HandleFunc(route("DELETE", "/tracks/{id}"), s.requireNotDemo(s.handleDeleteTrack))
	s.mux.HandleFunc(route("POST", "/tracks/overlaps"), s.requireVerified(s.handleTrackOverlaps))
	s.mux.HandleFunc(route("POST", "/tracks/stats-card"), s.requireVerified(s.handleStatsCard))
	s.mux.HandleFunc(route("GET", "/tracks/pending"), s.requireVerified(s.handleTracksPending))
	s.mux.HandleFunc(route("GET", "/tracks/summary"), s.requireVerified(s.handleTrackSummary))
	s.mux.HandleFunc(route("GET", "/tracks/histogram"), s.requireVerified(s.handleTrackHistogram))
	s.mux.HandleFunc(route("GET", "/tracks/graph-stats"), s.requireVerified(s.handleTrackGraphStats))
	s.mux.HandleFunc(route("GET", "/tracks/trends"), s.requireVerified(s.handleTrackTrends))
	s.mux.HandleFunc(route("GET", "/tracks/{id}/route-metrics"), s.requireVerified(s.handleTrackRouteMetrics))
	s.mux.HandleFunc(route("GET", "/tracks/{id}/route-points"), s.requireVerified(s.budgeted(budget.ReadsPaused, s.handleTrackRoutePoints)))
	s.mux.HandleFunc(route("POST", "/tracks/{id}/route-edit"), s.requireNotDemo(s.handleTrackRouteEdit))
	s.mux.HandleFunc(route("GET", "/private-locations"), s.requireVerified(s.handleListPrivateLocations))
	s.mux.HandleFunc(route("GET", "/private-locations/hidden"), s.requireVerified(s.handleHiddenTracks))
	s.mux.HandleFunc(route("POST", "/private-locations"), s.requireNotDemo(s.handleCreatePrivateLocation))
	s.mux.HandleFunc(route("PATCH", "/private-locations/{id}"), s.requireNotDemo(s.handleUpdatePrivateLocation))
	s.mux.HandleFunc(route("DELETE", "/private-locations/{id}"), s.requireNotDemo(s.handleDeletePrivateLocation))
	s.mux.HandleFunc(route("GET", "/trips"), s.requireVerified(s.handleListTrips))
	s.mux.HandleFunc(route("POST", "/trips"), s.requireNotDemo(s.handleCreateTrip))
	s.mux.HandleFunc(route("GET", "/trips/{id}"), s.requireVerified(s.handleGetTrip))
	s.mux.HandleFunc(route("PATCH", "/trips/{id}"), s.requireNotDemo(s.handleUpdateTrip))
	s.mux.HandleFunc(route("DELETE", "/trips/{id}"), s.requireNotDemo(s.handleDeleteTrip))
	s.mux.HandleFunc(route("POST", "/trips/{id}/tracks"), s.requireNotDemo(s.handleAddTripTracks))
	s.mux.HandleFunc(route("DELETE", "/trips/{id}/tracks"), s.requireNotDemo(s.handleRemoveTripTracks))
	// Sending a copy of a Trip (trip_sends.go).
	s.mux.HandleFunc(route("POST", "/trips/{id}/send"), s.requireNotDemo(s.handleSendTrip))
	s.mux.HandleFunc(route("GET", "/trip-sends"), s.requireVerified(s.handleListTripSends))
	s.mux.HandleFunc(route("POST", "/trip-sends/{id}/accept"), s.requireNotDemo(s.budgeted(budget.AddingPaused, s.handleAcceptTripSend)))
	s.mux.HandleFunc(route("DELETE", "/trip-sends/{id}"), s.requireNotDemo(s.handleDeclineTripSend))
	// Track photos (photos.go).
	s.mux.HandleFunc(route("GET", "/photos"), s.requireVerified(s.handleListPhotos))
	s.mux.HandleFunc(route("POST", "/photos"), s.requireNotDemo(s.budgeted(budget.AddingPaused, s.handleUploadPhoto)))
	s.mux.HandleFunc(route("POST", "/photos/place"), s.requireNotDemo(s.handlePlacePhoto))
	s.mux.HandleFunc(route("GET", "/photos/{id}"), s.requireVerified(s.budgeted(budget.ReadsPaused, s.handleGetPhoto)))
	s.mux.HandleFunc(route("GET", "/photos/{id}/thumb"), s.requireVerified(s.budgeted(budget.ReadsPaused, s.handleGetPhotoThumb)))
	s.mux.HandleFunc(route("PATCH", "/photos/{id}"), s.requireNotDemo(s.handleUpdatePhoto))
	s.mux.HandleFunc(route("DELETE", "/photos/{id}"), s.requireNotDemo(s.handleDeletePhoto))
	s.mux.HandleFunc(route("GET", "/uploads"), s.requireVerified(s.handleListUploads))
	s.mux.HandleFunc(route("GET", "/uploads/active"), s.requireVerified(s.handleActiveUploads))
	s.mux.HandleFunc(route("POST", "/uploads/seen"), s.requireNotDemo(s.handleUploadsSeen))
	s.mux.HandleFunc(route("GET", "/uploads/{external_id}"), s.requireVerified(s.handleUploadStatus))
	s.mux.HandleFunc(route("GET", "/coverage/status"), s.requireVerified(s.handleCoverageStatus))
	s.mux.HandleFunc(route("GET", "/map/layers"), s.requireVerified(s.handleMapLayers))
	s.mux.HandleFunc(route("POST", "/sync/tracks"), s.requireNotDemo(s.budgeted(budget.AddingPaused, s.handleSyncTracks)))
	s.mux.HandleFunc(route("POST", "/sync/known"), s.requireNotDemo(s.handleSyncKnown))
	s.tile("/tracks/{z}/{x}/{y}", s.handleTracksTile)
	s.tile("/fog-vector/{z}/{x}/{y}", s.budgeted(budget.ReadsPaused, s.handleFogVectorTile))
	s.tile("/spots/{z}/{x}/{y}", s.handleSpotsTile)
	s.tile("/bike-paths/{z}/{x}/{y}", s.handleBikePathsTile)
	s.mux.HandleFunc(route("GET", "/spots"), s.requireVerified(s.handleSpotsInArea))
	s.mux.HandleFunc(route("GET", "/spots/captures"), s.requireVerified(s.handleListSpotCaptures))
	s.mux.HandleFunc(route("GET", "/spots/{id}"), s.requireVerified(s.handleSpotDetail))
	s.mux.HandleFunc(route("POST", "/spots/{id}/captures"), s.requireNotDemo(s.handleCaptureSpot))
	// §4.2.4's Country/Region zoom tiers: live MVT, not precomputed (admin_country_tiles.go).
	s.tile("/countries/{z}/{x}/{y}", s.handleCountryFogTile)
	s.tile("/regions/{z}/{x}/{y}", s.handleRegionFogTile)
	s.tile("/counties/{z}/{x}/{y}", s.handleCountyFogTile)
	s.tile("/cities/{z}/{x}/{y}", s.handleCityFogTile)
	// Deliberately not behind requireAuth, unlike every API route above it. The style
	// document is derived entirely from the public Protomaps basemap and contains no
	// per-user data — only layer definitions and the asset URLs a client would need
	// anyway to fetch an archive this server already publishes unauthenticated. Requiring
	// a session would also couple basemap rendering to session state on mobile, where the
	// app can usefully draw a map before the user has signed in.
	s.mux.HandleFunc(route("GET", "/map/style/{flavor}"), s.handleMapStyle)
	s.mux.HandleFunc(route("GET", "/map/imagery"), s.handleMapImagery)
	s.mux.HandleFunc("GET /healthz", s.handleHealthz)
	removeStaleGPXFiles(log)
	return s
}

// registerPages adds the server-rendered HTML pages (pages.go, auth_pages.go, ADR-0012) —
// outside the API, since they're pages a browser navigates to, not API. In production Caddy sends
// this server everything that isn't a static asset (apps/web/docker/Caddyfile); in dev, Vite's
// proxy (apps/web/vite.config.ts) lists these paths one by one, so a new page goes there too.
func (s *Server) registerPages() {
	// About is the signed-out home page too (appShell), so its canonical link is `/`.
	s.mux.HandleFunc("GET /about", s.staticPage("about", "meta.about_title", "meta.home_description", "/"))
	s.mux.HandleFunc("GET /help", s.staticPage("help", "meta.help_title", "meta.help_description", ""))
	s.mux.HandleFunc("GET /guides", s.staticPage("guides", "meta.guides_title", "meta.guides_description", ""))
	s.mux.HandleFunc("GET /contacts", s.staticPage("contacts", "meta.contacts_title", "meta.contacts_description", ""))
	s.mux.HandleFunc("GET /privacy", s.staticPage("privacy", "meta.privacy_title", "meta.privacy_description", ""))
	for _, g := range web.Guides {
		s.mux.HandleFunc("GET "+g.Href, s.staticPage(g.Page, "meta."+g.MetaKey+"_title", "meta."+g.MetaKey+"_description", ""))
	}
	s.mux.Handle("GET /static/", s.pages.StaticHandler())
	s.mux.HandleFunc("POST /logout", s.sameOrigin(s.handleLogoutPage))
	s.mux.HandleFunc("POST /language", s.sameOrigin(s.handleLanguageForm)) // language.go
	// auth_pages.go — every POST is a form, so every POST is behind sameOrigin.
	s.mux.HandleFunc("GET /signin", s.handleSignInPage)
	s.mux.HandleFunc("POST /signin", s.sameOrigin(s.handleSignInForm))
	s.mux.HandleFunc("GET /signup", s.handleSignUpPage)
	s.mux.HandleFunc("POST /signup", s.sameOrigin(s.handleSignUpForm))
	s.mux.HandleFunc("POST /demo", s.sameOrigin(s.handleDemoForm))
	s.mux.HandleFunc("GET /forgot", s.handleForgotPage)
	s.mux.HandleFunc("POST /forgot", s.sameOrigin(s.handleForgotForm))
	s.mux.HandleFunc("GET /reset", s.handleResetPage)
	s.mux.HandleFunc("POST /reset", s.sameOrigin(s.handleResetForm))
	s.mux.HandleFunc("GET /verify", s.handleVerifyPage)
	s.mux.HandleFunc("POST /verify", s.sameOrigin(s.handleVerifyForm))
	s.mux.HandleFunc("GET /verify-pending", s.handleVerifyPendingPage)
	s.mux.HandleFunc("POST /verify-pending/resend", s.sameOrigin(s.handleVerifyResendForm))
	s.mux.HandleFunc("POST /verify-pending/email", s.sameOrigin(s.handleVerifyChangeEmailForm))
	s.mux.HandleFunc("POST /verify-pending/code", s.sameOrigin(s.handleVerifyCodeForm))
	// settings_page.go.
	s.mux.HandleFunc("GET /settings", s.handleSettingsPage)
	s.mux.HandleFunc("POST /settings", s.sameOrigin(s.handleSettingsForm))
	s.mux.HandleFunc("POST /settings/avatar", s.sameOrigin(s.handleSettingsAvatarForm))
	s.mux.HandleFunc("POST /settings/avatar/remove", s.sameOrigin(s.handleSettingsAvatarRemoveForm))
	s.mux.HandleFunc("POST /settings/export", s.sameOrigin(s.handleSettingsExportForm))
	s.mux.HandleFunc("POST /settings/delete", s.sameOrigin(s.handleSettingsDeleteForm))
	s.mux.HandleFunc("GET /profile", s.handleProfilePage)   // profile_page.go
	s.mux.HandleFunc("GET /sync", s.handleSyncPage)         // sync_page.go
	s.mux.HandleFunc("GET /library", s.handleLibraryPage)   // library_page.go
	s.mux.HandleFunc("GET /admin", s.handleAdminStatsPage)  // admin_stats_page.go
	s.mux.HandleFunc("GET /admin/users", s.handleAdminPage) // admin_pages.go
	s.mux.HandleFunc("GET /admin/users/{id}", s.handleAdminUserPage)
	// The React app — the map (pages.go's appShell). `/{$}` is the root alone; "/" below is
	// everything else nothing more specific claims.
	s.mux.HandleFunc("GET /{$}", s.appShell("meta.home_title"))
	s.mux.HandleFunc("/", s.notFound)
}

// ServeHTTP is serve with each response counted and timed for internal/metrics, and a
// handler's panic recovered into a 500.
func (s *Server) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	rec := &statusRecorder{ResponseWriter: w}
	start := time.Now()
	defer func() {
		// A handler's panic is answered here rather than by net/http, which would only drop
		// the connection and print a plain-text line the log shipping can't parse. Recorded
		// as a 500 like any other, and counted on its own for the alert.
		p := recover()
		if p != nil {
			if p == http.ErrAbortHandler {
				panic(p)
			}
			metrics.HTTPPanics.Inc()
			s.log.Error("handler panicked", "method", r.Method, "route", r.Pattern, "client", appClient(r.UserAgent()), "panic", p, "stack", string(debug.Stack()))
			if !rec.wroteHeader {
				if isAPIPath(r.URL.Path) {
					writeAPIError(rec, "internal error", http.StatusInternalServerError)
				} else {
					http.Error(rec, "internal error", http.StatusInternalServerError)
				}
			}
			rec.status = http.StatusInternalServerError
		}
		// r.Pattern is the ServeMux pattern that matched (set by s.mux.ServeHTTP on this same
		// request), never the path itself, so the label has one value per route.
		route := r.Pattern
		if route == "" {
			route = "unmatched"
		}
		status := rec.status
		if status == 0 {
			status = http.StatusOK
		}
		// A handler without its own clientGone check answers a cancelled query with a 500;
		// counted as the 499 it is, with no "request failed" line.
		if status == http.StatusInternalServerError && p == nil && r.Context().Err() != nil {
			status = statusClientClosedRequest
		}
		// Any other 500, whoever logged its cause: the handler's own error line doesn't know
		// which build of the app made the call, and a fault only old installs hit looks
		// different. A 503 is left out: the daily-capacity gate and /healthz answer it on purpose.
		if status == http.StatusInternalServerError && p == nil {
			s.log.Error("request failed", "method", r.Method, "route", route, "status", status, "client", appClient(r.UserAgent()))
		}
		metrics.HTTPRequests.WithLabelValues(route, metrics.StatusClass(status)).Inc()
		metrics.HTTPDuration.WithLabelValues(route).Observe(time.Since(start).Seconds())
		if s.visitors != nil && countsAsVisitor(route, status, r.UserAgent(), fromApp(r)) {
			ip, ua := clientIP(r), r.UserAgent()
			go func() {
				ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
				defer cancel()
				s.visitors.record(ctx, time.Now(), ip, ua)
			}()
		}
	}()
	s.serve(rec, r)
}

// appClient is the User-Agent when one of HoldMyTrack's own apps sent it — the Android app's
// "HoldMyTrack-Android/0.13 (62da50b; 812)" or the iOS app's — and "" for anything else. A browser's agent stays out
// of the logs: it says more about the person than the build, and the web app is the server's
// own build anyway. Cut to a length a real one never reaches, since any client can claim it.
func appClient(userAgent string) string {
	const prefix, maxLen = "HoldMyTrack-", 64
	if !strings.HasPrefix(userAgent, prefix) {
		return ""
	}
	if len(userAgent) > maxLen {
		return userAgent[:maxLen]
	}
	return userAgent
}

// statusRecorder keeps the status a handler answered with, for ServeHTTP's metrics. Unwrap
// lets http.ResponseController reach the real writer's Flush and deadlines through it.
type statusRecorder struct {
	http.ResponseWriter
	status      int
	wroteHeader bool
}

func (r *statusRecorder) WriteHeader(status int) {
	if !r.wroteHeader {
		r.status, r.wroteHeader = status, true
	}
	r.ResponseWriter.WriteHeader(status)
}

func (r *statusRecorder) Write(b []byte) (int, error) {
	if !r.wroteHeader {
		r.status, r.wroteHeader = http.StatusOK, true
	}
	return r.ResponseWriter.Write(b)
}

func (r *statusRecorder) Unwrap() http.ResponseWriter { return r.ResponseWriter }

// serve sets CORS headers before delegating to the mux. This has to happen here, not
// just as a nice-to-have: apps/web (:5173) and this server (:8080) are different origins in
// dev, and a cross-origin POST with a multipart/form-data body is a CORS "simple request" —
// the browser sends it through with no preflight, the server processes it fully, but without
// Access-Control-Allow-Origin the browser still blocks the JS from reading the response.
// That surfaces as a generic NetworkError in fetch(), with no indication in the response
// itself that anything went wrong — the request can be seen succeeding in the Network tab
// while the calling code sees only a rejected promise.
//
// Requests carry a session cookie, so "*" can't be the allowed origin: browsers refuse
// Access-Control-Allow-Credentials beside a wildcard. The request's own Origin is reflected
// back when it's on the allowlist, never any origin, which would let any site ride a visitor's
// session.
func (s *Server) serve(w http.ResponseWriter, r *http.Request) {
	s.setSecurityHeaders(w.Header())
	if origin := r.Header.Get("Origin"); s.corsOrigins[origin] {
		w.Header().Set("Access-Control-Allow-Origin", origin)
		w.Header().Set("Access-Control-Allow-Credentials", "true")
		// A GPX download's file name, which the page reads to save it under (GET /v2/tracks/gpx).
		w.Header().Set("Access-Control-Expose-Headers", "Content-Disposition")
		w.Header().Set("Vary", "Origin")
	}
	w.Header().Set("Access-Control-Allow-Methods", "GET, POST, PATCH, DELETE, OPTIONS")
	w.Header().Set("Access-Control-Allow-Headers", "Content-Type")
	if r.Method == http.MethodOptions {
		w.WriteHeader(http.StatusNoContent)
		return
	}
	if s.crossSiteAPIWrite(r) {
		writeAPIError(w, "cross-origin request refused", http.StatusForbidden)
		return
	}
	if s.refuseOutdatedApp(w, r) {
		return
	}
	if !setsOwnBodyLimit(r) {
		r.Body = http.MaxBytesReader(w, r.Body, maxJSONBodyBytes)
	}
	s.mux.ServeHTTP(w, r)
}

// maxJSONBodyBytes bounds every request body that doesn't set a limit of its own. The handlers
// decode JSON or a form straight from the body and check lengths after, so without it one huge
// "name", or a route edit's list of millions of point indexes, is held whole in memory first.
// The largest legitimate body, a Trip's 10,000 track ids or a 10,000-entry route edit, is a
// few hundred KB.
const maxJSONBodyBytes = 1 << 20

// ownBodyLimitRoutes are the routes whose handler bounds the body itself, at a size above
// maxJSONBodyBytes: the multipart uploads (a track file, a photo, an avatar), a phone
// sync's batch of tracks, and the overlap check over everything a phone could offer. Matched by route, never by the client's Content-Type, which any
// caller can set to skip the cap on a JSON route.
var ownBodyLimitRoutes = map[string]bool{
	"POST " + apiPrefix + "/tracks/upload":   true,
	"POST " + apiPrefix + "/photos":          true,
	"POST " + apiPrefix + "/account/avatar":  true,
	"POST " + apiPrefix + "/sync/tracks":     true,
	"POST " + apiPrefix + "/tracks/overlaps": true,
	"POST /settings/avatar":                  true,
}

// setsOwnBodyLimit reports whether r's handler bounds the body itself (ownBodyLimitRoutes).
func setsOwnBodyLimit(r *http.Request) bool {
	return ownBodyLimitRoutes[r.Method+" "+r.URL.Path]
}

func (s *Server) setSecurityHeaders(h http.Header) {
	h.Set("Content-Security-Policy", s.csp)
	h.Set("X-Frame-Options", "DENY")
	h.Set("X-Content-Type-Options", "nosniff")
	h.Set("Referrer-Policy", "strict-origin-when-cross-origin")
}

// crossSiteAPIWrite reports a state-changing /v2/ request a browser sent from another site.
// SameSite=Lax keeps the session cookie off such a request, but not off the response: a
// hostile page's auto-submitted form to /v2/auth/login, with an enctype="text/plain" body
// shaped into valid JSON, set the attacker's session in the victim's browser, so whatever the
// victim uploaded next went to the attacker's account. A browser always sends Origin on a
// POST, PATCH or DELETE, so one naming a different origin than this app's (or the dev
// allowlist's) is refused. The native apps send no Origin, and pass, and so does Apple's own
// site posting Sign in with Apple's answer back, which only the round trip's state makes count.
func (s *Server) crossSiteAPIWrite(r *http.Request) bool {
	switch r.Method {
	case http.MethodGet, http.MethodHead, http.MethodOptions:
		return false
	}
	if !strings.HasPrefix(r.URL.Path, apiPrefix+"/") {
		return false
	}
	origin := r.Header.Get("Origin")
	if origin == "" || (r.URL.Path == appleCallbackPath && origin == appleIssuer) {
		return false
	}
	return !s.corsOrigins[origin] && !s.isSameOrigin(r)
}

// healthzResponse carries MinAndroidBuild and MinIOSBuild for scripts/check-contract-release.sh:
// the contract has to keep serving every release of each app from its minimum on.
type healthzResponse struct {
	Status          string `json:"status"`
	Version         string `json:"version"`
	MinAndroidBuild int    `json:"min_android_build"`
	MinIOSBuild     int    `json:"min_ios_build"`
}

func (s *Server) handleHealthz(w http.ResponseWriter, r *http.Request) {
	if err := s.pool.Ping(r.Context()); err != nil {
		http.Error(w, "db unreachable", http.StatusServiceUnavailable)
		return
	}
	writeJSON(w, http.StatusOK, healthzResponse{Status: "ok", Version: s.version, MinAndroidBuild: s.minAndroidBuild, MinIOSBuild: s.minIOSBuild})
}

func writeJSON(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(v)
}
