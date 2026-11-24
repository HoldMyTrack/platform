/**
 * The Android app's bridge, present when Library runs in the app's web view (its
 * `web/WebPageActivity.kt`). A web view saves no browser download, so the app downloads the
 * GPX itself, with its own session, and asks where to save it.
 */
export interface AppBridge {
  /** Downloads `ids`, comma-separated, as `GET /v2/tracks/gpx` would. */
  downloadGpx(ids: string): void;
}

/** The app's bridge on `scope`, or null in a browser. */
export function appBridge(scope: unknown = globalThis): AppBridge | null {
  const bridge = (scope as { HoldMyTrackApp?: unknown }).HoldMyTrackApp;
  return bridge && typeof (bridge as AppBridge).downloadGpx === 'function' ? (bridge as AppBridge) : null;
}
