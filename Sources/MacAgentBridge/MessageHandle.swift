import Foundation

struct MessageHandle: Codable, Equatable, Hashable, Sendable {
    let account: String
    let mailbox: String
    let uidValidity: UInt32
    let uid: UInt32

    init(opaqueValue: String) throws {
        let parts = opaqueValue.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4,
              let account = Self.decode(String(parts[0])),
              let mailbox = Self.decode(String(parts[1])),
              Self.validSegment(account), Self.validSegment(mailbox),
              let uidValidity = UInt32(parts[2]),
              let uid = UInt32(parts[3]), uid > 0
        else {
            throw MessageHandleError.malformed
        }
        self.account = account
        self.mailbox = mailbox
        self.uidValidity = uidValidity
        self.uid = uid
    }

    var checkpointKey: String {
        Data((account + "\u{0000}" + mailbox).utf8).base64EncodedString()
    }

    private static func decode(_ value: String) -> String? {
        var base64 = value.replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        guard let data = Data(base64Encoded: base64), !data.isEmpty,
              let decoded = String(data: data, encoding: .utf8), !decoded.isEmpty
        else { return nil }
        return decoded
    }

    private static func validSegment(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 1_024 &&
            !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
    }
}

enum MessageHandleError: LocalizedError, Equatable {
    case malformed

    var errorDescription: String? { "Malformed mail-mcp message handle" }
}
