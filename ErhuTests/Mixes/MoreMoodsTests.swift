import XCTest
@testable import Erhu

final class MoreMoodsTests: XCTestCase {
    func testGenresDecideTheNewMoods() {
        XCTAssertTrue(Moods.isFeelGood(track(1, genre: "Funk")))
        XCTAssertTrue(Moods.isParty(track(2, genre: "Dancehall")))
        XCTAssertTrue(Moods.isRomantic(track(3, genre: "R&B/Soul")))
        XCTAssertTrue(Moods.isSad(track(4, genre: "Emo")))
        XCTAssertTrue(Moods.isDark(track(5, genre: "Phonk")))
        XCTAssertTrue(Moods.isFocus(track(6, genre: "Modern Classical")))
        // Untagged songs never get a mood.
        for mood in [Moods.isFeelGood, Moods.isParty, Moods.isRomantic, Moods.isSad, Moods.isDark, Moods.isFocus] {
            XCTAssertFalse(mood(track(7)))
        }
    }

    func testTrustedTempoVetoesAMismatch() {
        XCTAssertFalse(Moods.isParty(track(1, genre: "House", bpm: 80)))
        XCTAssertFalse(Moods.isRomantic(track(2, genre: "Soul", bpm: 140)))
        XCTAssertFalse(Moods.isSad(track(3, genre: "Blues", bpm: 150)))
        XCTAssertFalse(Moods.isFeelGood(track(4, genre: "Pop", bpm: 170)))
        // An implausible BPM tag is ignored rather than trusted.
        XCTAssertTrue(Moods.isParty(track(5, genre: "House", bpm: 40)))
    }

    func testConflictingGenresStayOut() {
        XCTAssertFalse(Moods.isFocus(track(1, genre: "Ambient; Techno")))
        XCTAssertFalse(Moods.isRomantic(track(2, genre: "R&B; Drill")))
        XCTAssertFalse(Moods.isFeelGood(track(3, genre: "Pop; Emo")))
    }

    func testThrowbackNeedsARealOldYear() {
        XCTAssertTrue(Moods.isThrowback(track(1, year: 2005), currentYear: 2026))
        XCTAssertFalse(Moods.isThrowback(track(2, year: 2015), currentYear: 2026))
        XCTAssertFalse(Moods.isThrowback(track(3, year: 1970), currentYear: 2026))
        XCTAssertFalse(Moods.isThrowback(track(4, year: 0), currentYear: 2026))
        XCTAssertFalse(Moods.isThrowback(track(5), currentYear: 2026))
    }

    func testLibraryFilterUsesTheSongYear() {
        let old = Song(id: 1, title: "Old", artist: "A", album: "B", durationMs: 1, path: "1.mp3", year: 1999)
        let new = Song(id: 2, title: "New", artist: "A", album: "B", durationMs: 1, path: "2.mp3", year: 2024)
        XCTAssertTrue(LibraryMood.throwback.matches(old, currentYear: 2026))
        XCTAssertFalse(LibraryMood.throwback.matches(new, currentYear: 2026))
    }
}
