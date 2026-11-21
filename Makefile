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

.DEFAULT_GOAL := help
.PHONY: help up down logs shell build typecheck basemap test-go test-unit verify verify-build doc-checks test test-android test-ios test-all e2e-stack e2e-web e2e-android e2e-ios clean

help: ## List targets
	@grep -hE '^[a-z0-9-]+:.*?## ' $(MAKEFILE_LIST) | awk -F':.*?## ' '{printf "  %-14s %s\n", $$1, $$2}'

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

# verify:style compares against services/server/internal/mapstyle/styles, and verify:api-types
# against the API contract in services/server/api, and the client rule cases read testdata/; the web
# container sees none of these otherwise, so each is mounted where the relative paths land.
test-unit: ## Web unit tests and drift checks (fix: npm run build:style / gen:api-types)
	$(COMPOSE) run --rm -v $(CURDIR)/services/server/internal/mapstyle/styles:/services/server/internal/mapstyle/styles:ro \
	  -v $(CURDIR)/services/server/api:/services/server/api:ro \
	  -v $(CURDIR)/testdata:/testdata:ro \
	  web sh -c "npm run test:unit && npm run verify:style && npm run verify:api-types"

verify: ## Headless Playwright map checks against a dev server (test profile)
	$(TEST) npm run verify:map

verify-build: ## Build, then run the same checks against the production bundle
	$(TEST) sh -c "npm run build && npm run verify:build"

doc-checks: ## Document citations and the writing rules a pattern can catch
	scripts/check-doc-refs.sh
	scripts/check-doc-style.sh

test: test-go test-unit verify verify-build doc-checks ## Every CI test suite that needs only Docker

# The two below run on the host, with each app's own toolchain.
test-android: ## Android JUnit tests and lint (JDK 17 and the Android SDK)
	cd apps/android/holdmytrack && ./gradlew --continue :app:testDebugUnitTest :app:lintDebug

test-ios: ## iOS design-file drift, package tests and the app's unit tests (Xcode; IOS_DESTINATION)
	@command -v xcodebuild >/dev/null || { echo "test-ios needs macOS with Xcode"; exit 1; }
	cd apps/ios && scripts/make-design.py --check
	cd apps/ios/HoldMyTrackCore && swift test
	cd apps/ios && xcodebuild test -project HoldMyTrack.xcodeproj -scheme HoldMyTrack \
	  -destination '$(IOS_DESTINATION)' -only-testing:HoldMyTrackTests

test-all: test test-android test-ios ## test, test-android and test-ios

# The dev stack up and answering, for the apps' flows: api and worker for the test account and
# its uploads, web for the basemap the iOS export renders.
e2e-stack:
	$(COMPOSE) up -d
	curl -sf -o /dev/null --retry 60 --retry-delay 2 --retry-all-errors http://localhost:$(API_PORT)/healthz
	curl -sf -o /dev/null --retry 60 --retry-delay 2 --retry-all-errors http://localhost:5173/

e2e-web: verify verify-build ## Web end-to-end: the Playwright map checks, dev server and production bundle

# The emulator reaches the host's API at 10.0.2.2; -P rebuilds the debug app against it.
# Gradle passes when the APK fails to install and no test runs, so the result files are read:
# at least one test per device, none failed.
ANDROID_TEST_RESULTS := apps/android/holdmytrack/app/build/outputs/androidTest-results/connected/debug
e2e-android: e2e-stack ## Android end-to-end: the UI Automator flows on a running emulator
	@adb devices | grep -q 'device$$' || { echo "no emulator: start one (Android Studio's Device Manager, or emulator -avd <name>)"; exit 1; }
	rm -rf $(ANDROID_TEST_RESULTS)
	cd apps/android/holdmytrack && ./gradlew :app:connectedDebugAndroidTest -Pholdmytrack.apiBaseUrl=http://10.0.2.2:$(API_PORT)
	@for f in $(ANDROID_TEST_RESULTS)/TEST-*.xml; do \
	  grep -q 'tests="[1-9]' "$$f" && ! grep -qE '(failures|errors)="[1-9]' "$$f" || { echo "no flow ran, or one failed: $$f"; exit 1; }; \
	done

# HMT_API_BASE_URL on the command line outranks Config/Local.xcconfig, so the tests reach the
# stack e2e-stack checked rather than skipping.
e2e-ios: e2e-stack ## iOS end-to-end: the UI tests on a simulator (IOS_DESTINATION, IOS_UI_TESTS narrow it)
	cd apps/ios && xcodebuild test -project HoldMyTrack.xcodeproj -scheme HoldMyTrack \
	  -destination '$(IOS_DESTINATION)' -only-testing:$(IOS_UI_TESTS) HMT_API_BASE_URL=http://localhost:$(API_PORT)

clean: ## Stop and drop every volume (database, object store, node_modules)
	$(COMPOSE) down -v
