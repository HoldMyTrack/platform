import Testing
@testable import HoldMyTrackCore

/// A failed removal is said under its own Trip, folded or not.
struct TripRemoveNoteTests {
    @Test func theOpenTripSaysItUnderItsNumbers() {
        #expect(TripRemoveNote.place(tripID: "a", expanded: true, failedTripID: "a") == .afterStats)
    }

    @Test func aFoldedOrClosedTripSaysItUnderItsFolder() {
        #expect(TripRemoveNote.place(tripID: "a", expanded: false, failedTripID: "a") == .afterFolder)
    }

    @Test func anotherTripsFailureIsNotSaidHere() {
        #expect(TripRemoveNote.place(tripID: "b", expanded: true, failedTripID: "a") == nil)
        #expect(TripRemoveNote.place(tripID: "b", expanded: false, failedTripID: nil) == nil)
    }
}
