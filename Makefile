# Thin wrapper around docker compose, the front door for every language in the repository.
# Nothing here is logic; anything that grows logic belongs in a script under the package it
# serves. `make help` is the command reference docs/DEVELOPMENT.md points to.

COMPOSE := docker compose
TEST    := $(COMPOSE) --profile test run --rm test
# A throwaway Go toolchain for services/server's unit tests, so `make test` needs Docker and
# nothing else, like every other target here. Named volumes keep the module and build
# caches between runs. It shares compose's db container's network namespace, so the
# database tests reach their holdmytrack_test database at localhost:5432. testdata, and
# apps/web/public for the sitemap the guide pages' test reads, are mounted where their relative
# paths land.
GO      := docker run --rm -v $(CURDIR)/services/server:/src -w /src -v $(CURDIR)/testdata:/testdata:ro \
             -v $(CURDIR)/apps/web/public:/apps/web/public:ro \
             -v holdmytrack-go-mod:/go/pkg/mod -v holdmytrack-go-build:/root/.cache/go-build \
             --network container:$$($(COMPOSE) ps -q db) \
             -e TEST_DATABASE_URL=postgres://holdmytrack:holdmytrack@localhost:5432/holdmytrack_test \
             golang:1.27-bookworm

# The host port compose publishes the API on: .env's API_PORT, as compose reads it.
API_PORT        ?= $(or $(shell sed -n 's/^API_PORT=//p' .env 2>/dev/null),8080)
IOS_DESTINATION ?= platform=iOS Simulator,name=iPhone 17
IOS_UI_TESTS    ?= HoldMyTrackUITests
# Empty runs every Android instrumented test; a class name runs that one.
ANDROID_TESTS   ?=

.DEFAULT_GOAL := help
.PHONY: help up down logs shell build typecheck basemap test-go test-unit verify verify-build doc-checks test test-android test-android-device test-ios test-all e2e-stack e2e-web e2e-android e2e-ios ui-compare clean

help: ## List targets
	@grep -hE '^[a-z0-9-]+:.*?## ' $(MAKEFILE_LIST) | awk -F':.*?## ' '{printf "  %-20s %s\n", $$1, $$2}'

up: ## Start the whole stack (web on :5173, api on :8080, db, rustfs, migrate, worker)
	$(COMPOSE) up

down: ## Stop the stack; keeps every volume
	$(COMPOSE) down

logs: ## Follow the web (Vite) log; docker compose logs -f worker for ingest jobs
	$(COMPOSE) logs -f web

shell: ## Interactive shell in the web container
	$(COMPOSE) run --rm web bash

build: ## Typecheck and build apps/web to dist/ (run before verify:build outside make)
	$(COMPOSE) run --rm web npm run build

typecheck: ## Typecheck apps/web (tsc --noEmit)
	$(COMPOSE) run --rm web npm run typecheck

basemap: ## Re-cut the test basemap extract (404s once build-basemap.sh's BUILD ages out)
	$(COMPOSE) run --rm web npm run basemap

test-go: ## Go tests (services/server), one package at a time, against compose's holdmytrack_test db
	$(COMPOSE) up -d --wait db
	$(COMPOSE) exec -T db sh -c 'createdb -U holdmytrack holdmytrack_test 2>/dev/null || true'
	$(GO) go test -p 1 ./...

# verify:style compares against the style and layers documents in services/server/internal/mapstyle,
# verify:api-types against the API contract in services/server/api, the client rule cases read
# testdata/ and the Play screenshots' rules brand/; the web container sees none of these otherwise,
# so each is mounted where the relative paths land.
test-unit: ## Web unit tests and drift checks (fix: npm run build:style / gen:api-types)
	$(COMPOSE) run --rm -v $(CURDIR)/services/server/internal/mapstyle:/services/server/internal/mapstyle:ro \
	  -v $(CURDIR)/services/server/api:/services/server/api:ro \
	  -v $(CURDIR)/testdata:/testdata:ro \
	  -v $(CURDIR)/brand:/brand:ro \
	  web sh -c "npm run test:unit && npm run verify:style && npm run verify:api-types"

verify: ## Headless Playwright map checks against a dev server (test profile)
	$(TEST) npm run verify:map

verify-build: ## Build, then run the same checks against the production bundle
	$(TEST) sh -c "npm run build && npm run verify:build"

doc-checks: ## Document citations, the writing rules a pattern can catch, and the user-flow list
	scripts/check-doc-refs.sh
	scripts/check-doc-style.sh
	scripts/check-user-flows.py

test: test-go test-unit verify verify-build doc-checks ## Every CI test suite that needs only Docker

# The two below run on the host, with each app's own toolchain.
test-android: ## Android JUnit tests and lint (JDK 17 and the Android SDK)
	cd apps/android/holdmytrack && ./gradlew --continue :app:testDebugUnitTest :app:lintDebug

test-ios: ## iOS design-file drift, the scripts' tests, package tests and the app's unit tests (Xcode; IOS_DESTINATION)
	@command -v xcodebuild >/dev/null || { echo "test-ios needs macOS with Xcode"; exit 1; }
	cd apps/ios && scripts/make-design.py --check
	cd apps/ios/scripts && python3 -m unittest test_check_strings
	cd apps/ios/HoldMyTrackCore && swift test
	cd apps/ios && xcodebuild test -project HoldMyTrack.xcodeproj -scheme HoldMyTrack \
	  -destination '$(IOS_DESTINATION)' -only-testing:HoldMyTrackTests

test-all: test test-android test-ios ## test, test-android and test-ios

# The dev stack up and answering, for the apps' flows: api and worker for the test account and
# its uploads, web for the basemap the iOS export renders. --build, so the flows run against this
# checkout's server rather than whichever image was built last. Every checkout shares the one
# compose project, so a checkout without .env (a new worktree) would rebuild it with defaults.
e2e-stack:
	@test -f .env || { echo "e2e-stack: no .env here; copy it (and any compose.override.yaml) from your main checkout"; exit 1; }
	$(COMPOSE) up -d --build
	curl -sf -o /dev/null --retry 60 --retry-delay 2 --retry-all-errors http://localhost:$(API_PORT)/healthz
	curl -sf -o /dev/null --retry 60 --retry-delay 2 --retry-all-errors http://localhost:5173/

e2e-web: verify verify-build ## Web end-to-end: the Playwright map checks, dev server and production bundle

e2e-android: e2e-stack test-android-device ## Android instrumented tests with the dev stack: the UI Automator flows and the recording stores

# with-android-emulator.sh starts an emulator when no device is attached, and stops it after.
# The debug app talks to the web's dev server at localhost:5173, which every debug build forwards
# to the emulator with adb reverse (app/build.gradle.kts). Gradle
# uninstalls both APKs after a run, and the app's data with them, unless told to leave them.
# Gradle passes when the APK fails to install and no test runs, so the result files are read:
# at least one test per device, none failed.
ANDROID_TEST_RESULTS := apps/android/holdmytrack/app/build/outputs/androidTest-results/connected/debug
test-android-device: ## Android instrumented tests on an emulator, no dev stack: the flows need e2e-android (ANDROID_TESTS narrows, ANDROID_AVD picks the AVD)
	rm -rf $(ANDROID_TEST_RESULTS)
	cd apps/android/holdmytrack && ../../../scripts/with-android-emulator.sh ./gradlew :app:connectedDebugAndroidTest \
	  -Pandroid.injected.androidTest.leaveApksInstalledAfterRun=true \
	  $(if $(ANDROID_TESTS),-Pandroid.testInstrumentationRunnerArguments.class=$(ANDROID_TESTS))
	@for f in $(ANDROID_TEST_RESULTS)/TEST-*.xml; do \
	  grep -q 'tests="[1-9]' "$$f" && ! grep -qE '(failures|errors)="[1-9]' "$$f" || { echo "no test ran, or one failed: $$f"; exit 1; }; \
	done

# HMT_API_BASE_URL on the command line outranks Config/Local.xcconfig, so the tests reach the
# stack e2e-stack checked rather than skipping: the web's dev server, as a Debug build does.
e2e-ios: e2e-stack ## iOS end-to-end: the UI tests on a simulator (IOS_DESTINATION, IOS_UI_TESTS narrow it)
	cd apps/ios && xcodebuild test -project HoldMyTrack.xcodeproj -scheme HoldMyTrack \
	  -destination '$(IOS_DESTINATION)' -only-testing:$(IOS_UI_TESTS) HMT_API_BASE_URL=http://localhost:5173

# Each app's shot test captures apps/docs/ui-states.json's entries on the demo account; both skip
# unless asked (uiShots, HMT_UI_SHOTS). The Android shots are pulled from the app's files folder
# before the emulator script stops an emulator it started.
UI_SHOTS := ui-compare
ui-compare: e2e-stack ## Android and iOS side by side, one static page: ui-compare/index.html (IOS_DESTINATION picks the iPhone)
	rm -rf $(UI_SHOTS) && mkdir -p $(UI_SHOTS)/android
	cd apps/android/holdmytrack && ../../../scripts/with-android-emulator.sh sh -c '\
	  adb shell rm -rf /sdcard/Android/data/dev.holdmytrack.android/files/ui-shots; \
	  ./gradlew :app:connectedDebugAndroidTest -Pandroid.injected.androidTest.leaveApksInstalledAfterRun=true \
	    -Pandroid.testInstrumentationRunnerArguments.class=dev.holdmytrack.android.shots.UiShotsTest \
	    -Pandroid.testInstrumentationRunnerArguments.uiShots=true; \
	  adb pull /sdcard/Android/data/dev.holdmytrack.android/files/ui-shots/. ../../../$(UI_SHOTS)/android'
	cd apps/ios && TEST_RUNNER_HMT_UI_SHOTS=1 xcodebuild test -project HoldMyTrack.xcodeproj -scheme HoldMyTrack \
	  -destination '$(IOS_DESTINATION)' -only-testing:HoldMyTrackUITests/UIShotsTests \
	  -resultBundlePath ../../$(UI_SHOTS)/ios.xcresult HMT_API_BASE_URL=http://localhost:5173 || true
	python3 scripts/ui-compare.py --android $(UI_SHOTS)/android --ios $(UI_SHOTS)/ios.xcresult --out $(UI_SHOTS)/index.html

clean: ## Stop and drop every volume (database, object store, node_modules)
	$(COMPOSE) down -v
