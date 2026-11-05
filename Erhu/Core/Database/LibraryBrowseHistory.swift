import Foundation

struct LibraryBrowseFact: Hashable, Sendable {
    var addedAt: Int64 = 0
    var lastPlayedAt: Int64 = 0
    var plays = 0
}

extension LibraryDatabase {
    func libraryBrowseFacts() throws -> [Int64: LibraryBrowseFact] {
        let rows = try db.query("""
            SELECT s.id, COALESCE(i.added_at, s.date_modified) AS added_at,
                MAX(COALESCE(r.played_at, 0), COALESCE(p.last_played_at, 0)) AS last_played,
                COALESCE(p.plays, 0) AS plays
            FROM songs s
            LEFT JOIN library_imports i ON i.song_id = s.id
            LEFT JOIN recently_played r ON r.kind = 'SONG' AND r.item_id = s.id
            LEFT JOIN (
                SELECT song_id, SUM(play_count) AS plays, MAX(last_played_at) AS last_played_at
                FROM listening_stats WHERE play_count > 0 GROUP BY song_id
            ) p ON p.song_id = s.id
            """) { r in
                (r.int64("id"), LibraryBrowseFact(addedAt: r.int64("added_at"), lastPlayedAt: r.int64("last_played"), plays: r.int("plays")))
            }
        return Dictionary(rows, uniquingKeysWith: { first, _ in first })
    }

    func albumPlaybackTimes() throws -> [Int64: Int64] {
        let rows = try db.query("SELECT item_id, played_at FROM recently_played WHERE kind = 'ALBUM'") {
            ($0.int64("item_id"), $0.int64("played_at"))
        }
        return Dictionary(rows, uniquingKeysWith: max)
    }
}
