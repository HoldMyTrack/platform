import Testing
@testable import HoldMyTrackCore

/// The Edit sheet's height and the Tracks sheet hidden under it.
struct EditSheetTests {
    @Test func shortContentKeepsItsOwnHeight() {
        #expect(EditSheet.height(content: 300, maximum: 800, minimum: 160) == 300)
    }

    @Test func tallContentStopsAtTheShareOfTheScreen() {
        #expect(EditSheet.height(content: 700, maximum: 800, minimum: 160) == 440)
    }

    @Test func contentNotLaidOutYetTakesTheMinimum() {
        #expect(EditSheet.height(content: 0, maximum: 800, minimum: 160) == 160)
    }

    @Test func aTinyScreenNeverGetsMoreThanItHas() {
        #expect(EditSheet.height(content: 0, maximum: 100, minimum: 160) == 100)
    }

    @Test func aTapFindsItsSegmentEitherWay() {
        #expect(EditSheet.segment(at: 10, width: 300, count: 3, rightToLeft: false) == 0)
        #expect(EditSheet.segment(at: 250, width: 300, count: 3, rightToLeft: false) == 2)
        #expect(EditSheet.segment(at: 10, width: 300, count: 3, rightToLeft: true) == 2)
        #expect(EditSheet.segment(at: 250, width: 300, count: 3, rightToLeft: true) == 0)
        #expect(EditSheet.segment(at: 300, width: 300, count: 3, rightToLeft: false) == 2)
        #expect(EditSheet.segment(at: -5, width: 300, count: 3, rightToLeft: false) == 0)
        #expect(EditSheet.segment(at: 10, width: 0, count: 3, rightToLeft: false) == nil)
    }

    @Test func reasonsEndAsSentences() {
        #expect(EditSheet.sentence("Check exactly one track to edit its route") == "Check exactly one track to edit its route.")
        #expect(EditSheet.sentence("Photos belong to one track.") == "Photos belong to one track.")
    }

    @Test func theTracksSheetHidesWhileAnEditorIsOpen() {
        #expect(MapChrome.sheetShown(normal: true, recording: false, onLibrary: false, editing: false))
        #expect(!MapChrome.sheetShown(normal: true, recording: false, onLibrary: false, editing: true))
        #expect(!MapChrome.sheetShown(normal: false, recording: false, onLibrary: false, editing: false))
    }

    @Test func whileRecordingOnlyLibraryAndSyncKeepTheSheet() {
        #expect(!MapChrome.sheetShown(normal: true, recording: true, onLibrary: false, editing: false))
        #expect(MapChrome.sheetShown(normal: true, recording: true, onLibrary: true, editing: false))
    }
}
