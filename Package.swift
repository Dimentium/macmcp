// swift-tools-version: 6.1
import PackageDescription

let package = Package(
    name: "MacMCP",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "macmcp-bridge", targets: ["MacMCPBridge"])
    ],
    dependencies: [
        .package(
            url: "https://github.com/modelcontextprotocol/swift-sdk.git",
            exact: "0.12.0"
        ),
        .package(
            url: "https://github.com/apple/swift-system.git",
            exact: "1.4.0"
        )
    ],
    targets: [
        .executableTarget(
            name: "MacMCPBridge",
            dependencies: [
                .product(name: "MCP", package: "swift-sdk"),
                .product(name: "SystemPackage", package: "swift-system")
            ],
            path: "Sources/MacMCPBridge",
            exclude: ["Info.plist", "Entitlements.plist"],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("PDFKit"),
                .linkedFramework("Security"),
                .linkedFramework("ServiceManagement"),
                .unsafeFlags([
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist",
                    "-Xlinker", "Sources/MacMCPBridge/Info.plist"
                ])
            ]
        ),
        .testTarget(
            name: "MacMCPBridgeTests",
            dependencies: ["MacMCPBridge"],
            path: "Tests/MacMCPBridgeTests"
        )
    ],
    swiftLanguageModes: [.v5]
)
