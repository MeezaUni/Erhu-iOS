import AVFoundation
import CryptoKit
import Foundation

/// Ogg originals remain untouched. Xiph decodes into a disposable PCM CAF for the same
/// AVAudioEngine readers used by playback, seeking, EQ, waveforms and transitions.
enum DecodedAudioSource {
    static let extensions: Set<String> = ["ogg", "oga", "opus"]
    private static let lock = NSLock()
    private static var pinned: Set<String> = []
    private static let pinsLock = NSLock()
    static let budget: Int64 = 1024 * 1024 * 1024
    static var folder: URL { LibraryPaths.cachesFolder.appending(path: "decoded-audio", directoryHint: .isDirectory) }

    static func requiresDecoder(_ url: URL) -> Bool { extensions.contains(url.pathExtension.lowercased()) }
    static func key(_ url: URL) -> String {
        let attrs = (try? FileManager.default.attributesOfItem(atPath: url.path)) ?? [:]
        let text = "\(url.path)|\(attrs[.size] ?? 0)|\((attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0)"
        return SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    static func cachedURL(_ url: URL) -> URL { folder.appending(path: key(url) + ".caf") }
    static func isPrepared(_ url: URL) -> Bool { !requiresDecoder(url) || FileManager.default.fileExists(atPath: cachedURL(url).path) }

    static func pin(_ urls: [URL]) {
        let keys = Set(urls.filter(requiresDecoder).map { key($0) + ".caf" })
        pinsLock.withLock { pinned = keys }
    }

    static func inspect(_ url: URL) throws -> [String: Any] {
        guard let info = try ERHUOggDecoder.inspect(url) else { throw CocoaError(.fileReadCorruptFile) }
        return info
    }

    @discardableResult static func prepare(_ url: URL) throws -> URL {
        guard requiresDecoder(url) else { return url }
        return try lock.withLock {
            try Task.checkCancellation()
            let target = cachedURL(url)
            if FileManager.default.fileExists(atPath: target.path) { return target }
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let info = try inspect(url)
            let frames = (info["frames"] as? NSNumber)?.int64Value ?? -1
            let channels = (info["channels"] as? NSNumber)?.int64Value ?? 0
            guard frames > 0, (1...2).contains(channels), frames < (Int64.max - 64 * 1024 * 1024) / (channels * 4) else { throw CocoaError(.fileReadCorruptFile) }
            let needed = frames * channels * 4 + 64 * 1024 * 1024
            trim(protecting: target.lastPathComponent)
            if let free = try? folder.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage,
               free < needed { throw CocoaError(.fileWriteOutOfSpace) }
            let temporary = folder.appending(path: ".\(UUID().uuidString).caf")
            defer { try? FileManager.default.removeItem(at: temporary) }
            try ERHUOggDecoder.decode(url, to: temporary, isCancelled: { Task.isCancelled })
            let decoded = try AVAudioFile(forReading: temporary)
            guard decoded.length == frames, cachedURL(url) == target else { throw CocoaError(.fileReadCorruptFile) }
            try FileManager.default.moveItem(at: temporary, to: target)
            trim(protecting: target.lastPathComponent)
            return target
        }
    }

    static func open(_ url: URL, allowDecoding: Bool = true) throws -> AVAudioFile {
        guard requiresDecoder(url) else { return try AVAudioFile(forReading: url) }
        let target: URL
        if allowDecoding { target = try prepare(url) }
        else {
            target = cachedURL(url)
            guard FileManager.default.fileExists(atPath: target.path) else { throw CocoaError(.fileReadNoSuchFile) }
        }
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: target.path)
        return try AVAudioFile(forReading: target)
    }

    private static func trim(protecting name: String) {
        let protected = pinsLock.withLock { pinned }.union([name])
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey])) ?? []
        let entries = files.filter { $0.pathExtension == "caf" && !$0.lastPathComponent.hasPrefix(".") }.compactMap { url -> (URL, Int64, Date)? in
            guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]) else { return nil }
            return (url, Int64(values.fileSize ?? 0), values.contentModificationDate ?? .distantPast)
        }.sorted { $0.2 < $1.2 }
        var total = entries.reduce(Int64(0)) { $0 + $1.1 }
        for (url, size, _) in entries where total > budget && !protected.contains(url.lastPathComponent) {
            if (try? FileManager.default.removeItem(at: url)) != nil { total -= size }
        }
    }

    static func tags(_ url: URL) -> FileTags {
        guard let info = try? inspect(url), let values = info["tags"] as? [String: String] else { return FileTags() }
        var tags = FileTags()
        tags.title = values["TITLE"]; tags.artist = values["ARTIST"]; tags.album = values["ALBUM"]
        tags.albumArtist = values["ALBUMARTIST"] ?? values["ALBUM ARTIST"]
        tags.trackNumber = TagReader.leadingNumber(values["TRACKNUMBER"])
        tags.discNumber = TagReader.leadingNumber(values["DISCNUMBER"])
        tags.year = TagReader.year(values["DATE"] ?? values["YEAR"])
        tags.genres = values["GENRE"].map { [$0] } ?? []
        tags.bpmText = values["BPM"] ?? values["TEMPO"]
        tags.lyrics = values["LYRICS"] ?? values["UNSYNCEDLYRICS"]
        tags.composer = values["COMPOSER"]; tags.isCompilation = values["COMPILATION"] == "1"
        tags.hasArtwork = values["METADATA_BLOCK_PICTURE"] != nil || values["COVERART"] != nil
        return tags
    }

    static func artwork(_ url: URL) -> Data? {
        guard let info = try? inspect(url), let values = info["tags"] as? [String: String] else { return nil }
        if let text = values["METADATA_BLOCK_PICTURE"], let block = Data(base64Encoded: text) { return FLACTags.pictureBlock(block)?.data }
        return values["COVERART"].flatMap { Data(base64Encoded: $0) }
    }
}
