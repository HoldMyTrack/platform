import CoreLocation
import HoldMyTrackCore
import Testing
import UIKit

@testable import HoldMyTrack

/// The map image is made without a basemap or Satellite it can't reach, as Android's leaves out
/// the tiles it couldn't load (apps/android/docs/SPEC.md FR-2.11).
@MainActor
struct ExportRendererTests {
    /// Both sources at an address that refuses every connection.
    private let style = JSONValue.parse(Data(##"""
    {"version": 8,
     "sources": {"protomaps": {"type": "raster", "tiles": ["http://127.0.0.1:9/b/{z}/{x}/{y}.png"], "tileSize": 256},
                 "satellite": {"type": "raster", "tiles": ["http://127.0.0.1:9/s/{z}/{x}/{y}.png"], "tileSize": 256}},
     "layers": [{"id": "bg", "type": "background", "paint": {"background-color": "#e8e4da"}},
                {"id": "earth", "type": "raster", "source": "protomaps"},
                {"id": "satellite", "type": "raster", "source": "satellite"}]}
    """##.utf8))!

    @Test func unreachableTilesAreLeftOutRatherThanFailingTheImage() async throws {
        var state = MapState()
        state.satellite = true
        let empty = LayersDocument(JSONValue.parse(Data(#"{"views": {}, "groups": []}"#.utf8))!)!
        let steps = ExportStyle.steps(style: style, document: empty, state: state, apiBase: URL(string: "http://127.0.0.1:9")!)
        let renderer = ExportRenderer()
        // A short time per step: a refused tile fails at once, and a retried one would time out.
        let result: Result<ExportRenderer.Picture, Error> = await withCheckedContinuation { done in
            renderer.render(steps: steps, center: CLLocationCoordinate2D(latitude: 50, longitude: 10), zoom: 5, heading: 0, pitch: 0,
                            window: CGSize(width: 100, height: 100), pixelWidth: 200, pixelHeight: 200, stepTime: 3) { done.resume(returning: $0) }
        }
        let picture = try result.get()
        #expect(picture.image.size.width > 0)
        #expect(picture.step.leftOut == ["satellite", "protomaps"], "Satellite first, then the basemap")
        #expect(!picture.step.satellite)
    }
}
