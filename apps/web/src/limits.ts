/**
 * The server's limits on what a user types, applied here too so a limit shows before a 400
 * does. tests/apiLimits.test.mjs checks each against the API contract
 * (services/server/api/), and the server's own test checks the contract against its handlers.
 * Lengths are in characters.
 */
export const MAX_TRACK_TYPE_LEN = 50;
export const MAX_TRACK_NAME_LEN = 200;
export const MAX_TRACK_DESCRIPTION_LEN = 2000;
export const TRIP_MAX_NAME_LEN = 200;
export const TRIP_MAX_DESCRIPTION_LEN = 2000;
export const MAX_PHOTO_CAPTION_LEN = 500;
export const PRIVATE_LOCATION_MAX_NAME_LEN = 100;
export const PRIVATE_LOCATION_MIN_RADIUS_M = 50;
export const PRIVATE_LOCATION_MAX_RADIUS_M = 2000;
/** The most tracks one GPX download takes (`GET /v2/tracks/gpx`, the server's maxGPXTracks). */
export const MAX_DOWNLOAD_TRACKS = 100;
