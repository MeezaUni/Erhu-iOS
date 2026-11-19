import Foundation

/// Monthly listening statistics (Android's ListeningStatsDao + ListeningStatsRepository). Every
/// ranking is ordered by plays, then by the most recent play, then by name and id, so ties always
/// come out in the same order. Each event lands in the local calendar month it happened in.
extension LibraryDatabase {
    static let topLimit = 5

    /// One play of [songId]: one small transaction. Unknown songs record nothing.
    func recordPlay(songId: Int64, at date: Date = Date(), calendar: Calendar = .current) throws {
        let at = Int64(date.timeIntervalSince1970 * 1000)
        let (month, day) = Self.keys(date, calendar: calendar)
        try db.transaction {
            try db.execute("""
                INSERT OR IGNORE INTO listening_stats (month_key, song_id, play_count, listened_ms, last_played_at)
                SELECT ?, id, 0, 0, ? FROM songs WHERE id = ?
                """, [month, at, songId])
            let changed = try db.execute("""
                UPDATE listening_stats SET play_count = play_count + 1, last_played_at = ?
                WHERE month_key = ? AND song_id = ?
                """, [at, month, songId])
            if changed > 0 {
                try db.execute("INSERT OR IGNORE INTO listening_days (day, play_count) VALUES (?, 0)", [day])
                try db.execute("UPDATE listening_days SET play_count = play_count + 1 WHERE day = ?", [day])
                try db.execute("INSERT OR IGNORE INTO listening_daily (day_key, song_id) VALUES (?, ?)", [day, songId])
                try db.execute("UPDATE listening_daily SET play_count = play_count + 1, last_played_at = ? WHERE day_key = ? AND song_id = ?",
                               [at, day, songId])
            }
        }
    }

    /// Adds [ms] of actual playing time of [songId] to its month. Unknown songs record nothing.
    func addListened(songId: Int64, ms: Int64, at date: Date = Date(), calendar: Calendar = .current) throws {
        guard ms > 0 else { return }
        let at = Int64(date.timeIntervalSince1970 * 1000)
        let (month, day) = Self.keys(date, calendar: calendar)
        try db.transaction {
            try db.execute("""
                INSERT OR IGNORE INTO listening_stats (month_key, song_id, play_count, listened_ms, last_played_at)
                SELECT ?, id, 0, 0, ? FROM songs WHERE id = ?
                """, [month, at, songId])
            let changed = try db.execute("UPDATE listening_stats SET listened_ms = listened_ms + ? WHERE month_key = ? AND song_id = ?",
                                         [ms, month, songId])
            if changed > 0 {
                try db.execute("INSERT OR IGNORE INTO listening_daily (day_key, song_id, last_played_at) VALUES (?, ?, ?)", [day, songId, at])
                try db.execute("UPDATE listening_daily SET listened_ms = listened_ms + ? WHERE day_key = ? AND song_id = ?", [ms, day, songId])
            }
        }
    }

    static func keys(_ date: Date, calendar: Calendar) -> (month: String, day: String) {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        let month = String(format: "%04d-%02d", c.year ?? 0, c.month ?? 0)
        return (month, month + String(format: "-%02d", c.day ?? 0))
    }

    /// Months with at least one play, newest first ("YYYY-MM").
    func listeningMonths() throws -> [String] {
        try db.query("SELECT DISTINCT month_key FROM listening_stats WHERE play_count > 0 ORDER BY month_key DESC") { $0.string("month_key") }
    }

    func capsule(month: String, limit: Int = LibraryDatabase.topLimit) throws -> SoundCapsule {
        let range = ListeningRange.months(month, month)
        let ranked = try rankings(range, limit: limit)
        let sums = try totals(range)
        let days = try db.query("SELECT day FROM listening_days WHERE play_count > 0 ORDER BY day ASC") { $0.string("day") }
        return SoundCapsule(
            month: month, totalPlays: sums.plays, listenedMs: sums.listenedMs,
            longestStreakDays: Self.longestStreakTouching(days: days, month: month),
            topSongs: ranked.songs, topAlbums: ranked.albums, topArtists: ranked.artists, uniqueTracks: sums.tracks
        )
    }

    /// Listening over [period] (shared stats cards): this month and this year from the monthly
    /// table, which covers them exactly; the last 7 or 30 days (today included) by day.
    func periodStats(_ period: StatsPeriod, now: Date = Date(), calendar: Calendar = .current,
                     limit: Int = LibraryDatabase.topLimit) throws -> PeriodStats {
        let range = ListeningRange.of(period, now: now, calendar: calendar)
        let ranked = try rankings(range, limit: limit)
        let sums = try totals(range)
        return PeriodStats(period: period, topSongs: ranked.songs, topAlbums: ranked.albums, topArtists: ranked.artists,
                           totalPlays: sums.plays, listenedMs: sums.listenedMs, uniqueTracks: sums.tracks)
    }

    private func rankings(_ range: ListeningRange, limit: Int) throws
        -> (songs: [RankedSong], albums: [RankedAlbum], artists: [RankedArtist]) {
        let t = range.table, w = range.condition, args = range.arguments
        let songs = try db.query("""
            SELECT s.*, SUM(st.play_count) AS plays FROM \(t) st
            INNER JOIN songs s ON s.id = st.song_id
            WHERE \(w) AND st.play_count > 0
            GROUP BY s.id
            ORDER BY plays DESC, MAX(st.last_played_at) DESC, s.title COLLATE NOCASE ASC, s.id ASC
            LIMIT ?
            """, args + [limit]) { RankedSong(song: Self.song($0), plays: $0.int("plays")) }
        let albums = try db.query("""
            SELECT a.*, SUM(st.play_count) AS plays FROM \(t) st
            INNER JOIN songs s ON s.id = st.song_id
            INNER JOIN albums a ON a.id = s.album_id
            WHERE \(w) AND st.play_count > 0
            GROUP BY a.id
            ORDER BY plays DESC, MAX(st.last_played_at) DESC, a.title COLLATE NOCASE ASC, a.id ASC
            LIMIT ?
            """, args + [limit]) { RankedAlbum(album: Self.album($0), plays: $0.int("plays")) }
        let artists = try db.query("""
            SELECT ar.*, SUM(st.play_count) AS plays FROM \(t) st
            INNER JOIN (
                SELECT DISTINCT song_id, artist_id FROM song_artist_cross_ref WHERE is_unresolved = 0
            ) credit ON credit.song_id = st.song_id
            INNER JOIN artists ar ON ar.id = credit.artist_id AND ar.is_unresolved = 0
            WHERE \(w) AND st.play_count > 0
            GROUP BY ar.id
            ORDER BY plays DESC, MAX(st.last_played_at) DESC, ar.name COLLATE NOCASE ASC, ar.id ASC
            LIMIT ?
            """, args + [limit]) { RankedArtist(artist: Self.artist($0), plays: $0.int("plays")) }
        return (songs, albums, artists)
    }

    /// Plays, listening time and how many different tracks were played.
    private func totals(_ range: ListeningRange) throws -> (plays: Int, listenedMs: Int64, tracks: Int) {
        try db.query("""
            SELECT COALESCE(SUM(play_count), 0) AS plays, COALESCE(SUM(listened_ms), 0) AS listened_ms,
                COUNT(DISTINCT CASE WHEN play_count > 0 THEN song_id END) AS tracks
            FROM \(range.table) st WHERE \(range.condition)
            """, range.arguments) { ($0.int("plays"), $0.int64("listened_ms"), $0.int("tracks")) }.first ?? (0, 0, 0)
    }

    /// The longest run of consecutive listening days that includes at least one day of [month].
    /// A run may start before the month, but days after its end are not counted, so a finished
    /// month never changes. 0 when the month has no listening day. Days are "YYYY-MM-DD".
    static func longestStreakTouching(days: [String], month: String) -> Int {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        let lastDay = month + "-31"
        var best = 0
        var runLength = 0
        var runTouches = false
        var previous: Date?
        for key in Set(days).sorted() where key <= lastDay {
            guard let day = formatter.date(from: key) else { continue }
            if let previous, calendar.date(byAdding: .day, value: 1, to: previous) == day {
                // continues the run
            } else {
                runLength = 0
                runTouches = false
            }
            runLength += 1
            runTouches = runTouches || key.hasPrefix(month)
            if runTouches { best = max(best, runLength) }
            previous = day
        }
        return best
    }

    /// Every month row with counted plays, for songs still in the library (smart mixes).
    func monthlyPlays() throws -> [MonthlyPlays] {
        try db.query("""
            SELECT st.song_id, st.month_key, st.play_count, st.last_played_at FROM listening_stats st
            INNER JOIN songs s ON s.id = st.song_id
            WHERE st.play_count > 0
            ORDER BY st.song_id ASC, st.month_key ASC
            """) { MonthlyPlays(songId: $0.int64("song_id"), month: $0.string("month_key"), plays: $0.int("play_count"),
                                lastPlayedAt: $0.int64("last_played_at")) }
    }

    /// The songs of a [SmartPlaylist], computed from current data; [limit] -1 means all.
    func smartPlaylistSongs(_ playlist: SmartPlaylist, limit: Int = -1) throws -> [Song] {
        switch playlist {
        case .mostPlayed:
            return try db.query("""
                SELECT s.* FROM songs s
                INNER JOIN listening_stats st ON st.song_id = s.id
                GROUP BY s.id
                HAVING SUM(st.play_count) > 0
                ORDER BY SUM(st.play_count) DESC,
                    MAX(CASE WHEN st.play_count > 0 THEN st.last_played_at END) DESC,
                    s.title COLLATE NOCASE ASC, s.id ASC
                LIMIT ?
                """, [limit], Self.song)
        case .recentlyAdded:
            return try db.query("SELECT * FROM songs ORDER BY date_modified DESC, id DESC LIMIT ?", [limit], Self.song)
        case .recentlyPlayed:
            return try db.query("""
                SELECT s.* FROM songs s
                INNER JOIN listening_stats st ON st.song_id = s.id AND st.play_count > 0
                GROUP BY s.id
                ORDER BY MAX(st.last_played_at) DESC, s.title COLLATE NOCASE ASC, s.id ASC
                LIMIT ?
                """, [limit], Self.song)
        case .favorites:
            return try db.query("SELECT * FROM songs WHERE is_favorite = 1 ORDER BY title COLLATE NOCASE ASC, id ASC LIMIT ?",
                                [limit], Self.song)
        case .neverPlayed:
            return try db.query("""
                SELECT * FROM songs
                WHERE id NOT IN (SELECT song_id FROM listening_stats WHERE play_count > 0)
                ORDER BY title COLLATE NOCASE ASC, id ASC
                LIMIT ?
                """, [limit], Self.song)
        }
    }
}

/// Which stored listening a statistic reads: months (inclusive "YYYY-MM" keys) or days from a
/// "YYYY-MM-DD" key on.
enum ListeningRange: Equatable {
    case months(String, String)
    case daysFrom(String)

    static func of(_ period: StatsPeriod, now: Date, calendar: Calendar) -> ListeningRange {
        let (month, _) = LibraryDatabase.keys(now, calendar: calendar)
        switch period {
        case .thisMonth: return .months(month, month)
        case .thisYear:
            let year = String(month.prefix(4))
            return .months(year + "-01", year + "-12")
        case .last7Days, .last30Days:
            let back = period == .last7Days ? 6 : 29
            let start = calendar.date(byAdding: .day, value: -back, to: now) ?? now
            return .daysFrom(LibraryDatabase.keys(start, calendar: calendar).day)
        }
    }

    var table: String {
        switch self {
        case .months: "listening_stats"
        case .daysFrom: "listening_daily"
        }
    }

    var condition: String {
        switch self {
        case .months: "st.month_key >= ? AND st.month_key <= ?"
        case .daysFrom: "st.day_key >= ?"
        }
    }

    var arguments: [SQLBindable] {
        switch self {
        case .months(let first, let last): [first, last]
        case .daysFrom(let day): [day]
        }
    }
}
