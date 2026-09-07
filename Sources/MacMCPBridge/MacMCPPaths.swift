import Foundation

enum MacMCPPaths {
    static let applicationSupportDirectoryName = "macmcp"
    static let legacyApplicationSupportDirectoryName = "mac-agent-bridge"

    static func applicationSupportDirectory(
        homeDirectory: URL = LocalUserPaths.homeDirectoryURL()
    ) -> URL {
        homeDirectory
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent(applicationSupportDirectoryName, isDirectory: true)
    }

    static func legacyApplicationSupportDirectory(
        homeDirectory: URL = LocalUserPaths.homeDirectoryURL()
    ) -> URL {
        homeDirectory
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent(legacyApplicationSupportDirectoryName, isDirectory: true)
    }

    static func applicationSupportFile(
        _ name: String,
        homeDirectory: URL = LocalUserPaths.homeDirectoryURL()
    ) -> URL {
        applicationSupportDirectory(homeDirectory: homeDirectory).appendingPathComponent(name)
    }

    static func runtimeCacheDirectory(
        homeDirectory: URL = LocalUserPaths.homeDirectoryURL()
    ) -> URL {
        homeDirectory
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Caches", isDirectory: true)
            .appendingPathComponent(applicationSupportDirectoryName, isDirectory: true)
    }

    static func legacyApplicationSupportFile(
        _ name: String,
        homeDirectory: URL = LocalUserPaths.homeDirectoryURL()
    ) -> URL {
        legacyApplicationSupportDirectory(homeDirectory: homeDirectory).appendingPathComponent(name)
    }
}
