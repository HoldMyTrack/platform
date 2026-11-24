import Testing
@testable import HoldMyTrackCore

struct TripFormsTests {
    @Test func lengthCountsWhatTheServerCounts() {
        #expect(TripForms.length("Lakeside") == 8)
        // One family emoji shown, seven scalars sent.
        #expect(TripForms.length("👨‍👩‍👧‍👦") == 7)
    }

    @Test func aPastePastTheLimitKeepsWhatFits() {
        #expect(TripForms.fitting("abcdef", room: 4) == "abcd")
        #expect(TripForms.fitting("abc", room: 10) == "abc")
        #expect(TripForms.fitting("abc", room: 0) == "")
    }

    @Test func aCharacterIsNeverCutInHalf() {
        #expect(TripForms.fitting("a👨‍👩‍👧‍👦b", room: 5) == "a")
        #expect(TripForms.fitting("a👨‍👩‍👧‍👦b", room: 8) == "a👨‍👩‍👧‍👦")
    }
}
