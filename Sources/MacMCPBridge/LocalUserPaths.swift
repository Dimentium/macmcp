import Darwin
import Foundation

enum LocalUserPaths {
    static func homeDirectoryURL() -> URL {
        homeDirectoryURL(environment: ProcessInfo.processInfo.environment)
    }

    static func homeDirectoryURL(environment: [String: String]) -> URL {
        if let home = validHomePath(environment["HOME"]) {
            return URL(fileURLWithPath: home, isDirectory: true)
        }
        if let entry = getpwuid(geteuid()),
           let home = validHomePath(String(cString: entry.pointee.pw_dir)) {
            return URL(fileURLWithPath: home, isDirectory: true)
        }
        return URL(fileURLWithPath: "/", isDirectory: true)
    }

    private static func validHomePath(_ value: String?) -> String? {
        guard let value,
              value.hasPrefix("/"),
              !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
        else {
            return nil
        }
        return value
    }
}
