import Foundation

enum TunnelClientLogSource: String, Sendable {
    case stdout
    case stderr
    case lifecycle
}

/// Bounded, redacted local diagnostics for the optional OpenAI tunnel runtime.
/// The file is intentionally not included in `macmcp diagnose` output.
final class TunnelClientLogStore: @unchecked Sendable {
    static let defaultMaximumBytes = 10 * 1024 * 1024
    static let defaultArchivedFileCount = 4

    let fileURL: URL
    let maximumBytes: Int
    let archivedFileCount: Int

    private let lock = NSLock()
    private let fileManager: FileManager

    init(
        fileURL: URL = TunnelClientLogStore.defaultFileURL(),
        maximumBytes: Int = TunnelClientLogStore.defaultMaximumBytes,
        archivedFileCount: Int = TunnelClientLogStore.defaultArchivedFileCount,
        fileManager: FileManager = .default
    ) {
        self.fileURL = fileURL
        self.maximumBytes = max(1, maximumBytes)
        self.archivedFileCount = max(0, archivedFileCount)
        self.fileManager = fileManager
    }

    static func defaultFileURL() -> URL {
        MacMCPPaths.logFile("chatgpt-tunnel.log")
    }

    func append(source: TunnelClientLogSource, data: Data, date: Date = Date()) {
        guard let entry = TunnelClientLogRedactor.entry(source: source, data: data, date: date) else {
            return
        }
        lock.withLock {
            try? appendLocked(entry)
        }
    }

    func recordLifecycle(_ message: String, date: Date = Date()) {
        append(source: .lifecycle, data: Data(message.utf8), date: date)
    }

    private func appendLocked(_ entry: Data) throws {
        let directoryURL = fileURL.deletingLastPathComponent()
        try fileManager.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directoryURL.path)

        let currentSize = (try? fileManager.attributesOfItem(atPath: fileURL.path)[.size] as? NSNumber)?
            .intValue ?? 0
        if currentSize > 0, currentSize + entry.count > maximumBytes {
            try rotateLocked()
        }

        if !fileManager.fileExists(atPath: fileURL.path) {
            guard fileManager.createFile(atPath: fileURL.path, contents: nil) else {
                throw CocoaError(.fileWriteUnknown)
            }
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
        }
        let handle = try FileHandle(forWritingTo: fileURL)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: entry)
    }

    private func rotateLocked() throws {
        if archivedFileCount == 0 {
            try fileManager.removeItem(at: fileURL)
            return
        }

        let oldestURL = archivedFileURL(index: archivedFileCount)
        if fileManager.fileExists(atPath: oldestURL.path) {
            try fileManager.removeItem(at: oldestURL)
        }
        if archivedFileCount > 1 {
            for index in stride(from: archivedFileCount - 1, through: 1, by: -1) {
                let sourceURL = archivedFileURL(index: index)
                guard fileManager.fileExists(atPath: sourceURL.path) else { continue }
                try fileManager.moveItem(at: sourceURL, to: archivedFileURL(index: index + 1))
            }
        }
        if fileManager.fileExists(atPath: fileURL.path) {
            try fileManager.moveItem(at: fileURL, to: archivedFileURL(index: 1))
        }
    }

    private func archivedFileURL(index: Int) -> URL {
        let extensionName = fileURL.pathExtension
        let stem = fileURL.deletingPathExtension().lastPathComponent
        let name = extensionName.isEmpty
            ? "\(stem).\(index)"
            : "\(stem).\(index).\(extensionName)"
        return fileURL.deletingLastPathComponent().appendingPathComponent(name)
    }
}

final class TunnelClientLogCapture: @unchecked Sendable {
    let standardOutput = Pipe()
    let standardError = Pipe()

    private let store: TunnelClientLogStore
    private let lock = NSLock()
    private let readGroup = DispatchGroup()
    private var buffers: [TunnelClientLogSource: Data] = [:]
    private var isFinishing = false
    private var isFinished = false

    private static let maximumInputLineBytes = 16 * 1024

    init(store: TunnelClientLogStore) {
        self.store = store
        observe(standardOutput.fileHandleForReading, source: .stdout)
        observe(standardError.fileHandleForReading, source: .stderr)
    }

    deinit {
        finish()
    }

    func closeParentWriteHandles() {
        standardOutput.fileHandleForWriting.closeFile()
        standardError.fileHandleForWriting.closeFile()
    }

    func finish() {
        let shouldFinish: Bool = lock.withLock {
            guard !isFinishing, !isFinished else { return false }
            isFinishing = true
            standardOutput.fileHandleForReading.readabilityHandler = nil
            standardError.fileHandleForReading.readabilityHandler = nil
            return true
        }
        guard shouldFinish else { return }

        // A readability callback may already be queued when the process exits.
        // Keep accepting its bytes until both pipes have been drained.
        let finalOutput = standardOutput.fileHandleForReading.readDataToEndOfFile()
        let finalError = standardError.fileHandleForReading.readDataToEndOfFile()
        consume(finalOutput, source: .stdout, flushRemainder: true)
        consume(finalError, source: .stderr, flushRemainder: true)
        readGroup.wait()

        let remaining: [(TunnelClientLogSource, Data)] = lock.withLock {
            isFinished = true
            isFinishing = false
            let values = buffers.map { ($0.key, $0.value) }.filter { !$0.1.isEmpty }
            buffers.removeAll()
            return values
        }
        for (source, data) in remaining {
            store.append(source: source, data: data)
        }
    }

    private func observe(_ handle: FileHandle, source: TunnelClientLogSource) {
        handle.readabilityHandler = { [weak self] readableHandle in
            guard let self else {
                readableHandle.readabilityHandler = nil
                return
            }
            self.readGroup.enter()
            defer { self.readGroup.leave() }
            let data = readableHandle.availableData
            guard !data.isEmpty else {
                readableHandle.readabilityHandler = nil
                return
            }
            self.consume(data, source: source)
        }
    }

    private func consume(_ data: Data, source: TunnelClientLogSource, flushRemainder: Bool = false) {
        guard !data.isEmpty || flushRemainder else { return }
        let lines: [Data] = lock.withLock {
            guard !isFinished else { return [] }
            var pending = buffers[source] ?? Data()
            pending.append(data)
            if pending.count > Self.maximumInputLineBytes,
               !pending.contains(UInt8(ascii: "\n")) {
                buffers[source] = Data()
                return [Data("tunnel-client log record exceeded the size limit".utf8)]
            }

            var records: [Data] = []
            while let newlineIndex = pending.firstIndex(of: UInt8(ascii: "\n")) {
                let line = Data(pending[..<newlineIndex])
                pending.removeSubrange(...newlineIndex)
                if line.count <= Self.maximumInputLineBytes {
                    records.append(line)
                } else {
                    records.append(Data("tunnel-client log record exceeded the size limit".utf8))
                }
            }
            if flushRemainder, !pending.isEmpty {
                records.append(pending)
                pending.removeAll()
            }
            buffers[source] = pending
            return records
        }
        for line in lines {
            store.append(source: source, data: line)
        }
    }
}

enum TunnelClientLogRedactor {
    private static let maximumTextBytes = 1_024
    private static let allowedTextKeys: Set<String> = [
        "time", "level", "msg", "message", "component", "request_kind", "channel", "phase", "reason", "error"
    ]
    private static let allowedNumberKeys: Set<String> = ["status_code"]
    private static let allowedBooleanKeys: Set<String> = ["final_response"]
    private static let renderedDetailKeys = [
        "request_kind", "channel", "phase", "reason", "error", "status_code", "final_response"
    ]

    static func entry(source: TunnelClientLogSource, data: Data, date: Date) -> Data? {
        let raw = String(decoding: data, as: UTF8.self)
        if source == .lifecycle {
            let message = sanitizedText(raw)
            guard !message.isEmpty else { return nil }
            return renderedEntry(
                source: source,
                date: date,
                level: "INFO",
                component: nil,
                message: message,
                details: [:]
            )
        }

        // Never reflect raw tunnel-client output. Unknown fields can include
        // request metadata, paths, or nested diagnostic objects.
        guard let fields = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }

        var level = source == .stderr ? "WARN" : "INFO"
        var component: String?
        var message = "tunnel-client event"
        var details: [String: String] = [:]
        for (key, value) in fields {
            let normalizedKey = key.lowercased()
            if allowedTextKeys.contains(normalizedKey), let value = value as? String {
                let sanitizedValue = sanitizedText(value)
                switch normalizedKey {
                case "level":
                    level = normalizedLevel(sanitizedValue)
                case "component":
                    component = sanitizedValue
                case "msg", "message":
                    if message == "tunnel-client event" || normalizedKey == "msg" {
                        message = sanitizedValue
                    }
                case "time":
                    break
                default:
                    details[normalizedKey] = sanitizedValue
                }
            } else if allowedNumberKeys.contains(normalizedKey), value is NSNumber {
                details[normalizedKey] = String(describing: value)
            } else if allowedBooleanKeys.contains(normalizedKey), let value = value as? Bool {
                details[normalizedKey] = value ? "true" : "false"
            }
        }

        guard !isRoutineStartupNoise(message: message, component: component, level: level) else {
            return nil
        }
        return renderedEntry(
            source: source,
            date: date,
            level: level,
            component: component,
            message: message,
            details: details
        )
    }

    private static func renderedEntry(
        source: TunnelClientLogSource,
        date: Date,
        level: String,
        component: String?,
        message: String,
        details: [String: String]
    ) -> Data {
        let componentPrefix = component.map { " [\($0)]" } ?? ""
        let renderedDetails = renderedDetailKeys.compactMap { key in
            details[key].map { "\(key)=\($0)" }
        }.joined(separator: " ")
        let detailSuffix = renderedDetails.isEmpty ? "" : " \(renderedDetails)"
        let timestamp = timestampFormatter.string(from: date)
        return Data("\(timestamp) \(level) [\(source.rawValue)]\(componentPrefix) \(message)\(detailSuffix)\n".utf8)
    }

    private static let timestampFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static func normalizedLevel(_ value: String) -> String {
        switch value.lowercased() {
        case "trace", "debug": return "DEBUG"
        case "warn", "warning": return "WARN"
        case "error", "fatal": return "ERROR"
        default: return "INFO"
        }
    }

    private static func isRoutineStartupNoise(message: String, component: String?, level: String) -> Bool {
        guard level == "INFO" else { return false }
        if [
            "OnStart hook executing",
            "OnStart hook executed",
            "run",
            "provided",
            "supplied",
            "invoking",
            "tls trust summary",
            "admin ui enabled",
            "tunnel-client startup summary",
            "harpoon enabled"
        ].contains(message) {
            return true
        }
        return component == "harpoon" && message == "harpoon startup catalog digest"
    }

    private static func sanitizedText(_ input: String) -> String {
        var result = input.unicodeScalars
            .filter { !CharacterSet.controlCharacters.contains($0) }
            .map(String.init)
            .joined()
        result = replacing(#"(?i)bearer\s+[^\s\"']+"#, in: result, with: "Bearer [redacted]")
        result = replacing(#"(?i)(?:sk|rk|key)[_-][A-Za-z0-9_-]+"#, in: result, with: "[redacted-key]")
        result = replacing(#"(?i)(authorization|api[_-]?key|token|secret|password)\s*[:=]\s*[^\s,;]+"#, in: result, with: "$1=[redacted]")
        result = replacing(#"tunnel_[A-Za-z0-9_-]+"#, in: result, with: "[redacted-tunnel]")
        result = replacing(#"(?i)[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}"#, in: result, with: "[redacted-email]")
        if result.utf8.count > maximumTextBytes {
            result = String(decoding: result.utf8.prefix(maximumTextBytes), as: UTF8.self) + " [truncated]"
        }
        return result
    }

    private static func replacing(_ pattern: String, in text: String, with replacement: String) -> String {
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return text }
        let range = NSRange(text.startIndex..., in: text)
        return expression.stringByReplacingMatches(in: text, range: range, withTemplate: replacement)
    }
}
