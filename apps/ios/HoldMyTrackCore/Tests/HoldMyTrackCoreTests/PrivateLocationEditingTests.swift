import Foundation
import Testing

@testable import HoldMyTrackCore

/// The Private location editor's decisions (root docs/SPEC.md FR-7.1).
struct PrivateLocationEditingTests {
    private typealias E = PrivateLocationEditing
    private let home = PrivateLocation(id: "a", name: "Home", lon: -81.5, lat: 41.2, radiusM: 300)

    @Test func aNewOneIs200MetresAtTheCentreWithNoName() {
        #expect(E.Draft.new(lon: 2, lat: 48) == E.Draft(id: nil, name: "", lon: 2, lat: 48, radiusM: 200))
    }

    @Test func theRadiusMovesIn10MetreStepsWithinTheServersBounds() {
        #expect(E.radius(204) == 200)
        #expect(E.radius(206) == 210)
        #expect(E.radius(3) == 50)
        #expect(E.radius(9_999) == 2_000)
    }

    @Test func aNewOneFliesInFromTooFarOutAndASavedOneNeverOpensFurtherOut() {
        #expect(E.placeZoom(5) == 14)
        #expect(E.placeZoom(12) == 12)
        #expect(E.openZoom(10) == 14)
        #expect(E.openZoom(16) == 16)
    }

    @Test func aDraftIsDirtyOnlyWhenItWouldChangeWhatsSaved() {
        var draft = E.Draft(home)
        #expect(!E.dirty(draft, saved: [home]))
        draft.name = " Home "
        #expect(!E.dirty(draft, saved: [home]), "the name is compared trimmed")
        draft.radiusM = 310
        #expect(E.dirty(draft, saved: [home]))
        #expect(E.dirty(E.Draft.new(lon: 0, lat: 0), saved: [home]), "a new one is always a change")
    }

    @Test func aTapOnTheCircleBeingEditedWinsWhereCirclesOverlap() {
        #expect(E.hit([("b", false), ("", true)]) == .selected)
        #expect(E.hit([("b", false)]) == .saved("b"))
        #expect(E.hit([]) == .empty)
    }

    @Test func theRingIsClosedAndEveryPointIsTheRadiusAway() {
        let ring = E.ring(lon: -81.5, lat: 41.2, radiusM: 300)
        #expect(ring.count == 65)
        #expect(ring.first! == ring.last!)
        for p in ring {
            // Haversine, as the server clips.
            let φ1 = 41.2 * .pi / 180, φ2 = p.lat * .pi / 180, Δφ = φ2 - φ1, Δλ = (p.lon + 81.5) * .pi / 180
            let a = sin(Δφ / 2) * sin(Δφ / 2) + cos(φ1) * cos(φ2) * sin(Δλ / 2) * sin(Δλ / 2)
            let d = 2 * E.earthRadiusM * asin(sqrt(a))
            #expect(abs(d - 300) < 0.01)
        }
    }
}