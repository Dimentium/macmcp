import Foundation
import MCP
import PDFKit

enum AttachmentTextReaderError: Error {
    case invalidRequest
    case invalidSidecarResponse
    case fileOutsideStorage
    case unsupportedContentType
    case textExtractionFailed
}

struct AttachmentStorage: Sendable {
    static let maximumAttachmentBytes = 10 * 1_024 * 1_024

    let directoryURL: URL

    init(
        directoryURL: URL = LocalUserPaths.homeDirectoryURL()
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Caches", isDirectory: true)
            .appendingPathComponent("MacMCP", isDirectory: true)
            .appendingPathComponent("attachments", isDirectory: true)
    ) {
        self.directoryURL = directoryURL
    }

    func prepare() throws {
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: directoryURL.path
        )
        clear()
    }

    func clear() {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: nil
        ) else {
            return
        }
        for entry in entries {
            try? FileManager.default.removeItem(at: entry)
        }
    }

    func fileURL(forSidecarPath path: String) throws -> URL {
        guard !path.isEmpty, path.utf8.count <= 4_096 else {
            throw AttachmentTextReaderError.fileOutsideStorage
        }

        let root = directoryURL.resolvingSymlinksInPath().standardizedFileURL.path
        let fileURL = URL(fileURLWithPath: path)
            .resolvingSymlinksInPath()
            .standardizedFileURL
        guard fileURL.path.hasPrefix(root + "/") else {
            throw AttachmentTextReaderError.fileOutsideStorage
        }

        let values = try fileURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true,
              let size = values.fileSize,
              size >= 0,
              size <= Self.maximumAttachmentBytes
        else {
            throw AttachmentTextReaderError.fileOutsideStorage
        }
        return fileURL
    }

    func remove(_ fileURL: URL) {
        try? FileManager.default.removeItem(at: fileURL)
    }
}

struct AttachmentTextReader: Sendable {
    static let publicToolName = "mail.read_attachment_text"
    private static let maximumExtractedTextBytes = 48_000

    private struct SidecarDownload: Decodable {
        let filePath: String
        let filename: String
        let contentType: String

        enum CodingKeys: String, CodingKey {
            case filePath = "file_path"
            case filename
            case contentType = "content_type"
        }
    }

    private struct ExtractedAttachment: Encodable {
        let filename: String
        let contentType: String
        let text: String
        let textTruncated: Bool

        enum CodingKeys: String, CodingKey {
            case filename
            case contentType = "content_type"
            case text
            case textTruncated = "text_truncated"
        }
    }

    let router: GatewayRouter
    let policy: ReaderPolicy
    let storage: AttachmentStorage

    func read(arguments: [String: Value]?) async -> CallTool.Result {
        do {
            try validate(arguments: arguments)
            let result = try await router.callRaw(
                publicName: Self.publicToolName,
                arguments: arguments,
                policy: policy
            )
            guard result.isError != true else {
                return UntrustedContentFilter().filter(result, publicToolName: Self.publicToolName)
            }

            let download = try decodeDownload(result)
            let fileURL = try storage.fileURL(forSidecarPath: download.filePath)
            defer { storage.remove(fileURL) }

            let extractedText = try extractText(from: fileURL, contentType: download.contentType)
            let textTruncated = extractedText.utf8.count > Self.maximumExtractedTextBytes
            let output = ExtractedAttachment(
                filename: download.filename,
                contentType: download.contentType,
                text: UntrustedContentFilter.boundedUTF8(
                    extractedText,
                    limit: Self.maximumExtractedTextBytes
                ),
                textTruncated: textTruncated
            )
            let text = String(
                decoding: try JSONEncoder().encode(output),
                as: UTF8.self
            )
            return UntrustedContentFilter().filter(
                CallTool.Result(content: [.text(text)]),
                publicToolName: Self.publicToolName
            )
        } catch {
            return CallTool.Result(
                content: [.text("Unable to read attachment")],
                isError: true
            )
        }
    }

    private func validate(arguments: [String: Value]?) throws {
        guard let arguments,
              let messageID = arguments["message_id"]?.stringValue,
              !messageID.isEmpty,
              messageID.utf8.count <= 4_096,
              let partID = arguments["part_id"]?.stringValue,
              partID.range(
                of: "^[1-9][0-9]*(\\.[1-9][0-9]*)*$",
                options: .regularExpression
              ) != nil
        else {
            throw AttachmentTextReaderError.invalidRequest
        }
    }

    private func decodeDownload(_ result: CallTool.Result) throws -> SidecarDownload {
        guard result.content.count == 1,
              case let .text(text, _, _) = result.content[0],
              let data = text.data(using: .utf8)
        else {
            throw AttachmentTextReaderError.invalidSidecarResponse
        }
        return try JSONDecoder().decode(SidecarDownload.self, from: data)
    }

    private func extractText(from fileURL: URL, contentType: String) throws -> String {
        switch normalizedContentType(contentType) {
        case "application/pdf":
            guard let text = PDFDocument(url: fileURL)?.string,
                  !text.isEmpty
            else {
                throw AttachmentTextReaderError.textExtractionFailed
            }
            return text
        case "text/plain", "text/csv", "text/markdown", "text/xml",
             "application/json", "application/xml":
            let data = try Data(contentsOf: fileURL, options: .mappedIfSafe)
            guard let text = String(data: data, encoding: .utf8) else {
                throw AttachmentTextReaderError.textExtractionFailed
            }
            return text
        default:
            throw AttachmentTextReaderError.unsupportedContentType
        }
    }

    private func normalizedContentType(_ value: String) -> String {
        value.split(separator: ";", maxSplits: 1)
            .first
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() } ?? ""
    }
}
