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

    @Test func theTracksSheetHidesWhileAnEditorIsOpen() {
        #expect(MapChrome.sheetShown(normal: true, recording: false, onSync: false, editing: false))
        #expect(!MapChrome.sheetShown(normal: true, recording: false, onSync: false, editing: true))
        #expect(!MapChrome.sheetShown(normal: false, recording: false, onSync: false, editing: false))
    }

    @Test func whileRecordingOnlyTheSyncTabKeepsTheSheet() {
        #expect(!MapChrome.sheetShown(normal: true, recording: true, onSync: false, editing: false))
        #expect(MapChrome.sheetShown(normal: true, recording: true, onSync: true, editing: false))
    }
}
