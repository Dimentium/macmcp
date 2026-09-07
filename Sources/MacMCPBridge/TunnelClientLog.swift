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
    private var buffers: [TunnelClientLogSource: Data] = [:]
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
        let remaining: [(TunnelClientLogSource, Data)] = lock.withLock {
            guard !isFinished else { return [] }
            isFinished = true
            standardOutput.fileHandleForReading.readabilityHandler = nil
            standardError.fileHandleForReading.readabilityHandler = nil
            let values = buffers.map { ($0.key, $0.value) }.filter { !$0.1.isEmpty }
            buffers.removeAll()
            return values
        }
        let finalOutput = standardOutput.fileHandleForReading.readDataToEndOfFile()
        let finalError = standardError.fileHandleForReading.readDataToEndOfFile()
        for (source, data) in remaining {
            store.append(source: source, data: data)
        }
        if !finalOutput.isEmpty {
            store.append(source: .stdout, data: finalOutput)
        }
        if !finalError.isEmpty {
            store.append(source: .stderr, data: finalError)
        }
    }

    private func observe(_ handle: FileHandle, source: TunnelClientLogSource) {
        handle.readabilityHandler = { [weak self] readableHandle in
            let data = readableHandle.availableData
            guard !data.isEmpty else {
                readableHandle.readabilityHandler = nil
                return
            }
            self?.consume(data, source: source)
        }
    }

    private func consume(_ data: Data, source: TunnelClientLogSource) {
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

    static func entry(source: TunnelClientLogSource, data: Data, date: Date) -> Data? {
        let raw = String(decoding: data, as: UTF8.self)
        let text = sanitizedText(raw)
        guard !text.isEmpty else { return nil }

        var record: [String: Any] = [
            "timestamp": ISO8601DateFormatter().string(from: date),
            "source": source.rawValue
        ]
        if let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)),
           let fields = object as? [String: Any] {
            for (key, value) in fields {
                let normalizedKey = key.lowercased()
                if allowedTextKeys.contains(normalizedKey), let value = value as? String {
                    record[normalizedKey] = sanitizedText(value)
                } else if allowedNumberKeys.contains(normalizedKey), value is NSNumber {
                    record[normalizedKey] = value
                } else if allowedBooleanKeys.contains(normalizedKey), let value = value as? Bool {
                    record[normalizedKey] = value
                }
            }
            record["event"] = "tunnel-client"
        } else {
            record["event"] = "tunnel-client-output"
            record["message"] = text
        }

        guard let encoded = try? JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]) else {
            return nil
        }
        var result = encoded
        result.append(UInt8(ascii: "\n"))
        return result
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
