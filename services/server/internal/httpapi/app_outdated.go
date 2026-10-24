package httpapi

import (
	"net/http"
	"strconv"
	"strings"
)

// An app build older than its platform's minimum (MIN_ANDROID_BUILD, MIN_IOS_BUILD) is refused
// on /v1/ with 426 app_outdated, which the app answers with its Update screen
// (apps/android/docs/SPEC.md FR-1.8, docs/IMPLEMENTATION.md §4.33).

// The apps' User-Agents start with these, then the release number and, in brackets, the commit
// and the build: "HoldMyTrack-Android/0.13 (62da50b; 812)", "HoldMyTrack-iOS/0.1 (62da50b; 1400)".
const (
	androidAgentPrefix = "HoldMyTrack-Android/"
	iosAgentPrefix     = "HoldMyTrack-iOS/"
)

// SetMinAndroidBuild sets the oldest Android versionCode /v1/ still answers; 0, the default,
// answers every build.
func (s *Server) SetMinAndroidBuild(n int) {
	s.minAndroidBuild = n
}

// SetMinIOSBuild sets the oldest iOS build number /v1/ still answers; 0, the default, answers
// every build.
func (s *Server) SetMinIOSBuild(n int) {
	s.minIOSBuild = n
}

// androidBuild is the versionCode in an Android User-Agent, and false for any other agent.
func androidBuild(userAgent string) (int, bool) { return agentBuild(userAgent, androidAgentPrefix) }

// iosBuild is the build number in an iOS User-Agent, and false for any other agent.
func iosBuild(userAgent string) (int, bool) { return agentBuild(userAgent, iosAgentPrefix) }

// agentBuild is the build in a User-Agent starting with prefix. A build from before the agent
// carried one reads as 0: it's older than any minimum.
func agentBuild(userAgent, prefix string) (int, bool) {
	rest, ok := strings.CutPrefix(userAgent, prefix)
	if !ok {
		return 0, false
	}
	_, inBrackets, ok := strings.Cut(rest, "(")
	if !ok {
		return 0, true
	}
	inBrackets, _, _ = strings.Cut(inBrackets, ")")
	parts := strings.Split(inBrackets, ";")
	n, err := strconv.Atoi(strings.TrimSpace(parts[len(parts)-1]))
	if err != nil || n < 0 {
		return 0, true
	}
	return n, true
}

// appOutdated reports a request from an app build below its platform's minimum. A browser, or
// anything else that isn't one of the apps, is never refused, and neither is a platform whose
// minimum is 0.
func appOutdated(userAgent string, minAndroid, minIOS int) bool {
	if build, ok := androidBuild(userAgent); ok {
		return minAndroid > 0 && build < minAndroid
	}
	if build, ok := iosBuild(userAgent); ok {
		return minIOS > 0 && build < minIOS
	}
	return false
}

// refuseOutdatedApp answers 426 to a /v1/ request from a build below the minimum, and reports
// whether it did.
func (s *Server) refuseOutdatedApp(w http.ResponseWriter, r *http.Request) bool {
	if !strings.HasPrefix(r.URL.Path, apiPrefix+"/") || !appOutdated(r.UserAgent(), s.minAndroidBuild, s.minIOSBuild) {
		return false
	}
	httpErrorT(w, r, http.StatusUpgradeRequired, "error.app_outdated")
	return true
}
