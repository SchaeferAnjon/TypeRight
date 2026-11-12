//
//  CoachStream.swift
//  TypeRight
//
//  AI answers as they arrive. The providers and our backend all speak OpenAI-compatible
//  server-sent events, so the JSON the model writes comes in small pieces; a card can go up as
//  soon as the part it shows first is complete (the English words, the sentence's edits) and the
//  rest fills in after. One URLSession is kept for every AI request so its connections stay open,
//  and is warmed up when the user starts typing.
//

import Foundation

// MARK: - JSON that is still arriving

/// A JSON value with only the parts that have fully arrived: a string still being written is left
/// out, numbers count once something follows them, arrays and objects say whether they were closed.
indirect enum PartialJSON: Equatable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case null
    case array([PartialJSON], closed: Bool)
    case object([String: PartialJSON], closed: Bool)

    /// What `text` holds so far, from its first `{` (some models put a code fence before it).
    static func parse(_ text: String) -> PartialJSON? {
        let bytes = Array(text.utf8)
        guard let open = bytes.firstIndex(of: UInt8(ascii: "{")) else { return nil }
        var reader = Reader(bytes: bytes, at: open)
        return reader.value()
    }

    subscript(key: String) -> PartialJSON? {
        if case let .object(members, _) = self { return members[key] }
        return nil
    }

    var string: String? {
        if case let .string(value) = self { return value }
        return nil
    }

    var bool: Bool? {
        if case let .bool(value) = self { return value }
        return nil
    }

    var items: [PartialJSON]? {
        if case let .array(items, _) = self { return items }
        return nil
    }

    var isClosed: Bool {
        switch self {
        case let .array(_, closed), let .object(_, closed): closed
        default: true
        }
    }

    private struct Reader {
        let bytes: [UInt8]
        var i: Int

        init(bytes: [UInt8], at start: Int) {
            self.bytes = bytes
            i = start
        }

        private static let quote = UInt8(ascii: "\"")
        private static let backslash = UInt8(ascii: "\\")

        private mutating func skipSpace() {
            while i < bytes.count, [0x20, 0x0A, 0x0D, 0x09].contains(bytes[i]) {
                i += 1
            }
        }

        /// nil when nothing complete starts here; the reader then sits at the end.
        mutating func value() -> PartialJSON? {
            skipSpace()
            guard i < bytes.count else { return nil }
            switch bytes[i] {
            case UInt8(ascii: "{"): return object()
            case UInt8(ascii: "["): return array()
            case Self.quote: return string().map(PartialJSON.string)
            case UInt8(ascii: "t"): return literal("true", .bool(true))
            case UInt8(ascii: "f"): return literal("false", .bool(false))
            case UInt8(ascii: "n"): return literal("null", .null)
            default: return number()
            }
        }

        private mutating func object() -> PartialJSON {
            i += 1
            var members: [String: PartialJSON] = [:]
            while true {
                skipSpace()
                guard i < bytes.count else { return .object(members, closed: false) }
                if bytes[i] == UInt8(ascii: "}") {
                    i += 1
                    return .object(members, closed: true)
                }
                if bytes[i] == UInt8(ascii: ",") {
                    i += 1
                    continue
                }
                guard bytes[i] == Self.quote, let key = string() else {
                    i = bytes.count
                    return .object(members, closed: false)
                }
                skipSpace()
                guard i < bytes.count, bytes[i] == UInt8(ascii: ":") else {
                    i = bytes.count
                    return .object(members, closed: false)
                }
                i += 1
                guard let member = value() else { return .object(members, closed: false) }
                members[key] = member
            }
        }

        private mutating func array() -> PartialJSON {
            i += 1
            var items: [PartialJSON] = []
            while true {
                skipSpace()
                guard i < bytes.count else { return .array(items, closed: false) }
                if bytes[i] == UInt8(ascii: "]") {
                    i += 1
                    return .array(items, closed: true)
                }
                if bytes[i] == UInt8(ascii: ",") {
                    i += 1
                    continue
                }
                guard let item = value() else { return .array(items, closed: false) }
                items.append(item)
            }
        }

        private mutating func literal(_ word: String, _ value: PartialJSON) -> PartialJSON? {
            let expected = Array(word.utf8)
            guard i + expected.count <= bytes.count, bytes[i ..< i + expected.count].elementsEqual(expected) else {
                i = bytes.count
                return nil
            }
            i += expected.count
            return value
        }

        /// A number at the very end may still be growing (`1` of `12`), so it only counts once
        /// something follows it.
        private mutating func number() -> PartialJSON? {
            let start = i
            while i < bytes.count, Array("+-0123456789.eE".utf8).contains(bytes[i]) {
                i += 1
            }
            guard i > start, i < bytes.count, let value = Double(String(decoding: bytes[start ..< i], as: UTF8.self)) else {
                i = bytes.count
                return nil
            }
            return .number(value)
        }

        private mutating func string() -> String? {
            i += 1
            var out: [UInt8] = []
            while i < bytes.count {
                let byte = bytes[i]
                if byte == Self.quote {
                    i += 1
                    return String(decoding: out, as: UTF8.self)
                }
                guard byte == Self.backslash else {
                    out.append(byte)
                    i += 1
                    continue
                }
                guard i + 1 < bytes.count else { break }
                let escaped = bytes[i + 1]
                switch escaped {
                case UInt8(ascii: "n"): out.append(0x0A)
                case UInt8(ascii: "t"): out.append(0x09)
                case UInt8(ascii: "r"): out.append(0x0D)
                case UInt8(ascii: "b"): out.append(0x08)
                case UInt8(ascii: "f"): out.append(0x0C)
                case UInt8(ascii: "u"):
                    guard let scalar = unicodeEscape() else {
                        i = bytes.count
                        return nil
                    }
                    out.append(contentsOf: Array(String(Character(scalar)).utf8))
                    continue
                default: out.append(escaped)
                }
                i += 2
            }
            i = bytes.count
            return nil
        }

        /// `\uXXXX`, or a surrogate pair of two of them; the reader moves past it.
        private mutating func unicodeEscape() -> Unicode.Scalar? {
            func hex(at index: Int) -> UInt32? {
                guard index + 4 <= bytes.count else { return nil }
                return UInt32(String(decoding: bytes[index ..< index + 4], as: UTF8.self), radix: 16)
            }
            guard let high = hex(at: i + 2) else { return nil }
            i += 6
            guard (0xD800 ... 0xDBFF).contains(high) else { return Unicode.Scalar(high) ?? "\u{FFFD}" }
            guard i + 6 <= bytes.count, bytes[i] == Self.backslash, bytes[i + 1] == UInt8(ascii: "u"),
                  let low = hex(at: i + 2) else { return nil }
            i += 6
            return Unicode.Scalar(0x10000 + ((high - 0xD800) << 10) + (low &- 0xDC00)) ?? "\u{FFFD}"
        }
    }
}

// MARK: - What the cards show first

extension CoachTranslation {
    /// The translation once its English is complete; the IPA and the note follow as they arrive.
    static func partial(_ json: PartialJSON) -> CoachTranslation? {
        guard let english = json["english"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines), !english.isEmpty else { return nil }
        return CoachTranslation(english: english, ipa: json["ipa"]?.string ?? "", note: json["note"]?.string ?? "")
    }
}

extension CoachSentenceCheck {
    /// Something to show once the answer says `ok`, or once every edit has arrived: the corrected
    /// sentence is the original with the edits put in, made here so the model never writes it.
    /// Reasons fill in as their notes arrive (note n belongs to edit n).
    static func partial(_ json: PartialJSON, original: String) -> CoachSentenceCheck? {
        if json["ok"]?.bool == true { return CoachSentenceCheck(ok: true, corrected: "", changes: []) }
        guard case let .array(items, closed: true)? = json["edits"] else { return nil }
        let edits = items.compactMap { item -> (from: String, to: String)? in
            guard let from = item["from"]?.string, let to = item["to"]?.string else { return nil }
            return (from, to)
        }
        let notes = json["notes"]?.items ?? []
        let (corrected, placed) = CoachText.applying(edits, to: original)
        if placed.count < edits.count {
            Logger.warning("TypeRight: \(edits.count - placed.count) of \(edits.count) edits do not fit the sentence, left out", category: Logger.llm)
        }
        let changes = placed.map { index in
            let note = notes.indices.contains(index) ? notes[index] : nil
            return Change(from: edits[index].from, to: edits[index].to,
                          why: note?["why"]?.string ?? "", type: note?["type"]?.string ?? "other")
        }
        return CoachSentenceCheck(ok: changes.isEmpty, corrected: changes.isEmpty ? "" : corrected, changes: changes)
    }
}

// MARK: - The connection

/// What one streamed request took, for the timing line in the log.
struct CoachStreamTiming: Sendable {
    var sent: TimeInterval = 0
    var headers: TimeInterval?
    var firstToken: TimeInterval?
    var done: TimeInterval?
    var reusedConnection: Bool?
    var tokensIn: Int?
    var tokensOut: Int?

    static var now: TimeInterval { ProcessInfo.processInfo.systemUptime }

    func ms(_ value: TimeInterval?) -> String {
        value.map { String(Int((($0 - sent) * 1000).rounded())) } ?? "-"
    }
}

enum CoachNet {
    /// The body of a reply, line by line, after its status and headers.
    typealias Lines = @Sendable (URLRequest) async throws -> (URLResponse, AsyncThrowingStream<String, Error>)
    /// A whole reply at once (tests, and the adapter below).
    typealias Send = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    /// One session for every AI request, kept for the app's lifetime so connections are reused.
    static let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.waitsForConnectivity = false
        config.httpMaximumConnectionsPerHost = 4
        return URLSession(configuration: config)
    }()

    static let lines: Lines = { request in
        let metrics = MetricsTap()
        let (bytes, response) = try await session.bytes(for: request, delegate: metrics)
        let stream = AsyncThrowingStream<String, Error> { continuation in
            let reading = Task {
                do {
                    for try await line in bytes.lines {
                        continuation.yield(line)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in reading.cancel() }
        }
        return (response, stream)
    }

    /// A reply read whole, handed on line by line.
    static func lines(from send: @escaping Send) -> Lines {
        { request in
            let (data, response) = try await send(request)
            let text = String(decoding: data, as: UTF8.self)
            let stream = AsyncThrowingStream<String, Error> { continuation in
                for line in text.split(whereSeparator: \.isNewline) {
                    continuation.yield(String(line))
                }
                continuation.finish()
            }
            return (response, stream)
        }
    }

    /// Reads a whole body from its lines (error replies).
    static func body(of lines: AsyncThrowingStream<String, Error>) async -> Data {
        var text = ""
        do {
            for try await line in lines {
                text += line + "\n"
                if text.utf8.count > 4000 { break }
            }
        } catch {
            Logger.debug("TypeRight: error reply could not be read to the end: \(error.localizedDescription)", category: Logger.llm)
        }
        return Data(text.utf8)
    }

    // MARK: Warming up

    private static let warmLock = NSLock()
    nonisolated(unsafe) private static var warmedAt: [String: TimeInterval] = [:]
    /// A connection left idle this long may have been closed by the server.
    static let warmAgain: TimeInterval = 45

    /// Opens a connection to `url`'s server (DNS, TCP, TLS) without asking it anything that costs
    /// tokens or carries a key, so the card's request does not wait for that. At most once per
    /// `warmAgain` per server, and not while a request just used it.
    static func warm(_ url: URL) {
        guard let host = url.host, let scheme = url.scheme else { return }
        let now = CoachStreamTiming.now
        let due = warmLock.withLock {
            guard now - (warmedAt[host] ?? -.infinity) >= warmAgain else { return false }
            warmedAt[host] = now
            return true
        }
        guard due, let origin = URL(string: "\(scheme)://\(host)/") else { return }
        var request = URLRequest(url: origin, timeoutInterval: 10)
        request.httpMethod = "HEAD"
        Task.detached(priority: .utility) {
            let start = CoachStreamTiming.now
            do {
                let (_, response) = try await session.data(for: request)
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                Logger.info("⏱ warm \(host): \(Int((CoachStreamTiming.now - start) * 1000)) ms (HTTP \(status))", category: Logger.llm)
            } catch {
                Logger.info("⏱ warm \(host) failed: \((error as? URLError)?.code.rawValue ?? -1)", category: Logger.llm)
            }
        }
    }

    /// A request is going to `url` now: its connection is fresh again.
    static func used(_ url: URL) {
        guard let host = url.host else { return }
        let now = CoachStreamTiming.now
        warmLock.withLock { warmedAt[host] = now }
    }
}

/// Records whether a request reused an open connection.
private final class MetricsTap: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_: URLSession, task _: URLSessionTask, didFinishCollecting metrics: URLSessionTaskMetrics) {
        guard let last = metrics.transactionMetrics.last else { return }
        let connect = last.connectStartDate.flatMap { start in last.connectEndDate.map { Int($0.timeIntervalSince(start) * 1000) } }
        let ttfb = last.requestStartDate.flatMap { start in last.responseStartDate.map { Int($0.timeIntervalSince(start) * 1000) } }
        Logger.info("⏱ connection: reused \(last.isReusedConnection), connect \(connect.map(String.init) ?? "-") ms, request→first byte \(ttfb.map(String.init) ?? "-") ms, \(last.networkProtocolName ?? "?")", category: Logger.llm)
    }
}
