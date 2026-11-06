import Foundation

enum TunnelClientVersionReader {
    static func version(atPath path: String) -> String {
        guard !path.isEmpty,
              FileManager.default.isExecutableFile(atPath: path) else {
            return "Unavailable"
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = ["--version"]
        process.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            return "Unavailable"
        }

        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0,
              let value = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else {
            return "Unavailable"
        }
        return String(value.prefix(200))
    }
}
