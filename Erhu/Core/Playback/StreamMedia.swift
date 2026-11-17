import AVFoundation
import Foundation
import UniformTypeIdentifiers

/// Feeds streamed songs to the player through the app's own connection, so a song starts at
/// once: the first seconds of songs likely to play next are fetched ahead ("heads", kept in
/// memory), the player is given those immediately while the rest streams, and every request
/// shares one warm connection to the server instead of the player opening a new one per song.
///
/// Used for songs the server sends unchanged (it answers byte ranges); converted streams go to
/// the player directly. All state lives on [queue].
final class StreamMedia: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    static let shared = StreamMedia()
    let queue = DispatchQueue(label: "erhu.stream.media")
    /// About four seconds of a 256 kbps song: enough to start playing while the rest arrives.
    static let headSize = 128 * 1024
    private static let headLimit = 60

    struct Head {
        let length: Int64
        let data: Data
    }

    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.default
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.httpMaximumConnectionsPerHost = 4
        let operations = OperationQueue()
        operations.underlyingQueue = queue
        operations.maxConcurrentOperationCount = 1
        return URLSession(configuration: config, delegate: self, delegateQueue: operations)
    }()

    private var heads: [String: Head] = [:]
    private var headOrder: [String] = []
    private var headsLoading: Set<String> = []
    private final class Handler {
        var onResponse: (HTTPURLResponse) -> Bool
        var onData: (Data) -> Void
        var onDone: (Error?) -> Void
        var responded = false
        init(onResponse: @escaping (HTTPURLResponse) -> Bool, onData: @escaping (Data) -> Void, onDone: @escaping (Error?) -> Void) {
            self.onResponse = onResponse
            self.onData = onData
            self.onDone = onDone
        }
    }
    private var handlers: [Int: Handler] = [:]

    // MARK: Heads

    /// Fetches the start of [url] ahead, unless it is already here or on its way.
    func prefetchHead(_ url: URL) {
        queue.async { [self] in
            let key = url.absoluteString
            guard heads[key] == nil, !headsLoading.contains(key) else { return }
            headsLoading.insert(key)
            var request = URLRequest(url: url)
            request.timeoutInterval = 20
            request.setValue("bytes=0-\(Self.headSize - 1)", forHTTPHeaderField: "Range")
            var length: Int64?
            var data = Data()
            _ = start(request, onResponse: { response in
                length = Self.totalLength(response, offset: 0)
                return response.statusCode == 206 || response.statusCode == 200
            }, onData: { chunk in
                if data.count < Self.headSize { data.append(chunk.prefix(Self.headSize - data.count)) }
            }, onDone: { [self] error in
                headsLoading.remove(key)
                guard error == nil || data.count >= Self.headSize, let length, !data.isEmpty else { return }
                heads[key] = Head(length: length, data: data)
                headOrder.removeAll { $0 == key }
                headOrder.append(key)
                if headOrder.count > Self.headLimit { heads[headOrder.removeFirst()] = nil }
            })
        }
    }

    /// The start of [url] if fetched ahead (call on [queue]).
    func head(_ url: URL) -> Head? { heads[url.absoluteString] }

    // MARK: Requests

    /// Starts [request] on the shared connection; returns its id for [cancel]. Call on [queue].
    func start(_ request: URLRequest, onResponse: @escaping (HTTPURLResponse) -> Bool,
               onData: @escaping (Data) -> Void, onDone: @escaping (Error?) -> Void) -> Int {
        let task = session.dataTask(with: request)
        handlers[task.taskIdentifier] = Handler(onResponse: onResponse, onData: onData, onDone: onDone)
        task.resume()
        return task.taskIdentifier
    }

    /// Call on [queue].
    func cancel(_ id: Int) {
        handlers[id] = nil
        session.getAllTasks { tasks in tasks.first { $0.taskIdentifier == id }?.cancel() }
    }

    /// The whole file's length from a reply to a range request starting at [offset].
    static func totalLength(_ response: HTTPURLResponse, offset: Int64) -> Int64? {
        if let range = response.value(forHTTPHeaderField: "Content-Range"),
           let total = range.split(separator: "/").last.flatMap({ Int64($0) }) {
            return total
        }
        if response.statusCode == 200, response.expectedContentLength > 0 {
            return response.expectedContentLength + offset
        }
        return nil
    }

    /// The reply is checked when its first data (or its end) arrives, from the task itself.
    private func accept(_ task: URLSessionTask, _ handler: Handler) -> Bool {
        if handler.responded { return true }
        handler.responded = true
        guard let http = task.response as? HTTPURLResponse, handler.onResponse(http) else {
            handlers[task.taskIdentifier] = nil
            task.cancel()
            handler.onDone(URLError(.badServerResponse))
            return false
        }
        return true
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard let handler = handlers[dataTask.taskIdentifier], accept(dataTask, handler) else { return }
        handler.onData(data)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let handler = handlers[task.taskIdentifier] else { return }
        if error == nil, !accept(task, handler) { return }
        handlers[task.taskIdentifier] = nil
        handler.onDone(error)
    }
}

/// Answers the player's requests for one streamed song: from the head fetched ahead when it
/// covers them, otherwise from the server over the shared connection, passing data on as it
/// arrives. Lives on [StreamMedia.queue].
final class StreamResourceLoader: NSObject, AVAssetResourceLoaderDelegate, @unchecked Sendable {
    static let scheme = "erhu-media"
    let remote: URL
    private let contentType: String
    private var length: Int64?
    private var running: [AVAssetResourceLoadingRequest: Int] = [:]

    init(remote: URL, fileExtension: String) {
        self.remote = remote
        contentType = UTType(filenameExtension: fileExtension)?.identifier ?? UTType.audio.identifier
    }

    /// The URL the player is given (a scheme it doesn't know, so it asks this loader).
    var playerURL: URL {
        var parts = URLComponents()
        parts.scheme = Self.scheme
        parts.host = "song"
        parts.path = "/" + UUID().uuidString
        return parts.url!
    }

    func resourceLoader(_ resourceLoader: AVAssetResourceLoader,
                        shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest) -> Bool {
        let media = StreamMedia.shared
        let head = media.head(remote)
        if length == nil { length = head?.length }
        if let info = loadingRequest.contentInformationRequest, let length {
            fill(info, length: length)
        }
        guard let dataRequest = loadingRequest.dataRequest else {
            if length != nil { loadingRequest.finishLoading(); return true }
            probe(loadingRequest)
            return true
        }
        var offset = dataRequest.requestedOffset
        let end: Int64? = dataRequest.requestsAllDataToEndOfResource ? length : offset + Int64(dataRequest.requestedLength)
        // What the head covers, at once.
        if let head, length != nil, offset < Int64(head.data.count) {
            let upTo = min(Int64(head.data.count), end ?? Int64(head.data.count))
            if upTo > offset {
                dataRequest.respond(with: head.data.subdata(in: Int(offset)..<Int(upTo)))
                offset = upTo
            }
        }
        if let end, offset >= end {
            loadingRequest.finishLoading()
            return true
        }
        // The rest from the server.
        var request = URLRequest(url: remote)
        request.timeoutInterval = 25
        request.setValue("bytes=\(offset)-\(end.map { String($0 - 1) } ?? "")", forHTTPHeaderField: "Range")
        let startOffset = offset
        let id = media.start(request, onResponse: { [weak self] response in
            guard let self else { return false }
            guard response.statusCode == 206 || (response.statusCode == 200 && startOffset == 0) else {
                if self.running.removeValue(forKey: loadingRequest) != nil {
                    loadingRequest.finishLoading(with: URLError(.badServerResponse))
                }
                return false
            }
            if self.length == nil { self.length = StreamMedia.totalLength(response, offset: startOffset) }
            if let info = loadingRequest.contentInformationRequest, let length = self.length { self.fill(info, length: length) }
            return true
        }, onData: { data in
            dataRequest.respond(with: data)
        }, onDone: { [weak self] error in
            guard let self, self.running.removeValue(forKey: loadingRequest) != nil else { return }
            if let error, (error as? URLError)?.code != .cancelled {
                loadingRequest.finishLoading(with: error)
            } else if error == nil {
                loadingRequest.finishLoading()
            }
        })
        running[loadingRequest] = id
        return true
    }

    func resourceLoader(_ resourceLoader: AVAssetResourceLoader, didCancel loadingRequest: AVAssetResourceLoadingRequest) {
        if let id = running.removeValue(forKey: loadingRequest) { StreamMedia.shared.cancel(id) }
    }

    /// Learns the file's length (a one-byte request) for a request that asks only for it.
    private func probe(_ loadingRequest: AVAssetResourceLoadingRequest) {
        var request = URLRequest(url: remote)
        request.timeoutInterval = 25
        request.setValue("bytes=0-1", forHTTPHeaderField: "Range")
        let id = StreamMedia.shared.start(request, onResponse: { [weak self] response in
            guard let self, let length = StreamMedia.totalLength(response, offset: 0) else {
                if self?.running.removeValue(forKey: loadingRequest) != nil {
                    loadingRequest.finishLoading(with: URLError(.badServerResponse))
                }
                return false
            }
            self.length = length
            if let info = loadingRequest.contentInformationRequest { self.fill(info, length: length) }
            return true
        }, onData: { _ in }, onDone: { [weak self] error in
            guard let self, self.running.removeValue(forKey: loadingRequest) != nil else { return }
            if self.length != nil { loadingRequest.finishLoading() } else if let error { loadingRequest.finishLoading(with: error) }
        })
        running[loadingRequest] = id
    }

    private func fill(_ info: AVAssetResourceLoadingContentInformationRequest, length: Int64) {
        info.contentType = contentType
        info.contentLength = length
        info.isByteRangeAccessSupported = true
    }
}
