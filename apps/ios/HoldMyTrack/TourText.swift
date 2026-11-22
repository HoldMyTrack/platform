import Foundation

/// Each TourStep.text and TourSteps.card key's title and body.
enum TourText {
    static func of(_ key: String) -> (title: String, body: String) {
        switch key {
        case "welcome": (
            String(localized: "tour.welcome.title", defaultValue: "Welcome to HoldMyTrack", comment: "The tour's first step."),
            String(localized: "tour.welcome.body", defaultValue: "It keeps the journeys you choose and turns them into maps. This tour shows where everything is.", comment: "The tour's first step."))
        case "tracks": (
            String(localized: "tour.tracks.title", defaultValue: "Your tracks", comment: "The tour: the list of tracks."),
            String(localized: "tour.tracks.body", defaultValue: "Every track on the map, newest first: the list follows the map as you move it. Tap one to fly to it. Tick several to edit or hide them together.", comment: "The tour: the list of tracks."))
        case "range": (
            String(localized: "tour.range.title", defaultValue: "Dates", comment: "The tour: the Dates filter."),
            String(localized: "tour.range.body", defaultValue: "All time, unless you set From or To. Picking a date moves the map onto the tracks it matches.", comment: "The tour: the Dates filter."))
        case "trips": (
            String(localized: "tour.trips.title", defaultValue: "Trips", comment: "The tour and the Trips tab's first-time card."),
            String(localized: "tour.trips.body", defaultValue: "Group your tracks into Trips: a holiday, a multi-day hike, a race weekend. A Trip shows only its own tracks, and you can send someone a copy.", comment: "The tour and the Trips tab's first-time card."))
        case "layers": (
            String(localized: "tour.layers.title", defaultValue: "Layers", comment: "The tour: the Layers menu."),
            String(localized: "tour.layers.body", defaultValue: "Tick the roads and paths you want on the map. Show layers turns them all on or off at once.", comment: "The tour: the Layers menu."))
        case "places": (
            String(localized: "tour.places.title", defaultValue: "Places", comment: "The tour: the Places menu."),
            String(localized: "tour.places.body", defaultValue: "Waterfalls, viewpoints, historic sites and more: tick the kinds you want on the map, and tap one to see what it is. Show places turns them all on or off.", comment: "The tour: the Places menu."))
        case "export": (
            String(localized: "tour.export.title", defaultValue: "Export", comment: "The tour: the map image export."),
            String(localized: "tour.export.body", defaultValue: "Save what's on the map as an image. Tick tracks in the list first to make them bold, and Show stats adds a card with their distance and time.", comment: "The tour: the map image export."))
        case "fog": (
            String(localized: "tour.fog.title", defaultValue: "Fog of War", comment: "The tour and Fog's first-time card."),
            String(localized: "tour.fog.body", defaultValue: "Everywhere you've ever been, for all time: Dates and the filters don't apply here. Fog clears whole places, from countries down to towns, and zoomed in, exactly along your routes. Auto picks the level from the zoom. Pick a level to keep it at every zoom, or Exact to clear the fog only along your routes.", comment: "The tour and Fog's first-time card."))
        case "fog_exact": (
            String(localized: "tour.fog.title", defaultValue: "Fog of War", comment: "The tour and Fog's first-time card."),
            String(localized: "tour.fog_exact.body", defaultValue: "Everywhere you've ever been, for all time: Dates and the filters don't apply here. Zoomed in, the fog lifts exactly along your routes.", comment: "The demo's tour: Fog at exact coverage."))
        case "fog_cities": (
            String(localized: "tour.fog_cities.title", defaultValue: "Fog of War: towns", comment: "The demo's tour: Fog's town level."),
            String(localized: "tour.fog_cities.body", defaultValue: "Zoomed out, a whole town clears once any track is in it. Tap a place to see its name and how much of it you've explored.", comment: "The demo's tour: Fog's town level."))
        case "fog_counties": (
            String(localized: "tour.fog_counties.title", defaultValue: "Fog of War: counties", comment: "The demo's tour: Fog's county level."),
            String(localized: "tour.fog_counties.body", defaultValue: "Further out, a whole county clears.", comment: "The demo's tour: Fog's county level."))
        case "fog_regions": (
            String(localized: "tour.fog_regions.title", defaultValue: "Fog of War: states and regions", comment: "The demo's tour: Fog's region level."),
            String(localized: "tour.fog_regions.body", defaultValue: "Then a whole state or region. Every fogged one is a place you haven't been yet.", comment: "The demo's tour: Fog's region level."))
        case "fog_countries": (
            String(localized: "tour.fog_countries.title", defaultValue: "Fog of War: countries", comment: "The demo's tour: Fog's country level."),
            String(localized: "tour.fog_countries.body", defaultValue: "And a whole country. Auto follows the zoom, as you just saw. Pick a level to keep it at every zoom, or Exact to clear the fog only along your routes.", comment: "The demo's tour: Fog's country level."))
        case "record": (
            String(localized: "tour.record.title", defaultValue: "Record", comment: "The tour: the record button."),
            String(localized: "tour.record.body", defaultValue: "Tap to record a walk or a ride with the phone's GPS, tap again to pause, and hold to stop. Recordings wait on this phone until you send them from Sync.", comment: "The tour: the record button."))
        case "record_demo": (
            String(localized: "tour.record.title", defaultValue: "Record", comment: "The tour: the record button."),
            String(localized: "tour.record_demo.body", defaultValue: "Tap to record a walk or a ride with the phone's GPS, tap again to pause, and hold to stop. In your own account, recordings are sent to your map from Sync.", comment: "The demo's tour: the record button; the demo can't send."))
        case "sync": (
            String(localized: "tour.sync.title", defaultValue: "Sync", comment: "The tour: the Sync tab."),
            String(localized: "tour.sync.body", defaultValue: "Bring in this phone's recordings. Nothing is ticked to start with: only what you tick is sent. You don't need to bring everything, only the journeys you want to keep.", comment: "The tour: the Sync tab, which lists the phone's recordings and leads to Upload and Sync history."))
        case "sync_demo": (
            String(localized: "tour.sync.title", defaultValue: "Sync", comment: "The tour: the Sync tab."),
            String(localized: "tour.sync_demo.body", defaultValue: "In your own account, your recordings are sent from here, and your files uploaded. The demo can't send: sign out and create an account to start yours.", comment: "The demo's tour: the Sync tab."))
        default: (
            String(localized: "tour.done.title", defaultValue: "That's the tour", comment: "The tour's last step."),
            String(localized: "tour.done.body", defaultValue: "Take it again any time from Take a tour, here on the You tab.", comment: "The tour's last step, on the You tab's Take a tour."))
        }
    }
}