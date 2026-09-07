import Foundation

private func writeStderr(_ message: String) {
    FileHandle.standardError.write(Data((message + "\n").utf8))
}

if CommandLine.arguments.contains("--version") {
    print("\(AppVersion.name) \(AppVersion.version)")
    exit(0)
}

if CommandLine.arguments.contains("--store-chatgpt-tunnel-key") {
    do {
        var key = try CommandLineInterface.readNewChatGPTTunnelKey()
        defer { key.resetBytes(in: 0..<key.count) }
        try KeychainCredentialStore(service: KeychainCredentialStore.chatGPTTunnelService)
            .storeSecret(key, account: KeychainCredentialStore.chatGPTTunnelAccount)
        print("Stored ChatGPT tunnel runtime API key in macOS Keychain")
        exit(0)
    } catch {
        writeStderr(error.localizedDescription)
        exit(1)
    }
}

if CommandLine.arguments.contains("--delete-chatgpt-tunnel-key") {
    do {
        try MigratingCredentialStore.chatGPTTunnel()
            .deleteSecret(account: KeychainCredentialStore.chatGPTTunnelAccount)
        print("Removed ChatGPT tunnel runtime API key from macOS Keychain")
        exit(0)
    } catch {
        writeStderr(error.localizedDescription)
        exit(1)
    }
}

if CommandLine.arguments.contains("--help") || CommandLine.arguments.contains("-h") {
    print(CommandLineInterface.help)
    exit(0)
}

if CommandLine.arguments.contains("--status-json") {
    do {
        print(try LocalBridgeIPC.requestBridgeStatus())
        exit(0)
    } catch {
        writeStderr(error.localizedDescription)
        exit(1)
    }
}

if CommandLine.arguments.contains("--diagnose-json") {
    do {
        print(try await MacMCPDiagnosticCollector().collect().encodedJSON())
        exit(0)
    } catch {
        writeStderr("Unable to collect MacMCP diagnostics")
        exit(1)
    }
}

if CommandLine.arguments.contains("--client-approvals-json") {
    do {
        let snapshot = try await ClientApprovalStore().snapshot()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        print(String(decoding: try encoder.encode(snapshot), as: UTF8.self))
        exit(0)
    } catch {
        writeStderr("Unable to read client approvals: \(error.localizedDescription)")
        exit(1)
    }
}

if CommandLine.arguments.contains("--approve-pending-client") {
    do {
        if let client = try await ClientApprovalStore().approvePending() {
            print("Approved MCP client: \(client.displayName)")
        } else {
            print("No pending MCP client")
        }
        exit(0)
    } catch {
        writeStderr("Unable to approve MCP client: \(error.localizedDescription)")
        exit(1)
    }
}

if let index = CommandLine.arguments.firstIndex(of: "--revoke-client") {
    guard index + 1 < CommandLine.arguments.count else {
        writeStderr("Missing fingerprint after --revoke-client")
        exit(2)
    }
    do {
        try await ClientApprovalStore().revoke(fingerprint: CommandLine.arguments[index + 1])
        print("Revoked MCP client")
        exit(0)
    } catch {
        writeStderr("Unable to revoke MCP client: \(error.localizedDescription)")
        exit(1)
    }
}

if CommandLine.arguments.contains("--login-item-status") {
    print(SMAppLoginItemController().status.label)
    exit(0)
}

if CommandLine.arguments.contains("--verify-configured-mail-keychain") {
    do {
        writeStderr("Configured mail Keychain check: resolving launch configuration path")
        writeStderr("Configured mail Keychain check: reading launch configuration")
        let storedArguments = try AppLaunchConfigurationStore().readArguments() ?? []
        writeStderr("Configured mail Keychain check: validating launch configuration")
        let configuration = try CommandLineInterface.launchConfiguration(arguments: storedArguments)
        var secrets: [Data] = []
        defer {
            for index in secrets.indices {
                secrets[index].resetBytes(in: 0..<secrets[index].count)
            }
        }
        writeStderr("Configured mail Keychain check: reading Keychain")
        for account in configuration.mailAccounts {
            secrets.append(try MigratingCredentialStore.mail().readSecret(account: account.username))
        }
        print("Configured mail Keychain credentials are available")
        exit(0)
    } catch {
        writeStderr("Configured mail Keychain credentials are unavailable")
        exit(1)
    }
}

if CommandLine.arguments.contains("--register-login-item") {
    do {
        try SMAppLoginItemController().register()
        print(SMAppLoginItemController().status.label)
        exit(0)
    } catch {
        writeStderr("Unable to register Login Item: \(error.localizedDescription)")
        exit(1)
    }
}

if CommandLine.arguments.contains("--unregister-login-item") {
    do {
        try SMAppLoginItemController().unregister()
        print(SMAppLoginItemController().status.label)
        exit(0)
    } catch {
        writeStderr("Unable to unregister Login Item: \(error.localizedDescription)")
        exit(1)
    }
}

var userArguments = Array(CommandLine.arguments.dropFirst())

if userArguments.isEmpty, Bundle.main.bundleURL.pathExtension == "app" {
    do {
        if let storedArguments = try AppLaunchConfigurationStore().readArguments() {
            userArguments = storedArguments
        }
    } catch {
        writeStderr("Unable to read app launch configuration: \(error.localizedDescription)")
        exit(1)
    }
}

let storePasswordOptions = ["--store-mail-password", "--store-icloud-password"]
if let index = userArguments.firstIndex(where: { storePasswordOptions.contains($0) }) {
    guard index + 1 < userArguments.count else {
        writeStderr("Missing account after \(userArguments[index])")
        exit(2)
    }
    do {
        var password = try CommandLineInterface.readNewPassword()
        defer { password.resetBytes(in: 0..<password.count) }
        try MigratingCredentialStore.mail().storeSecret(password, account: userArguments[index + 1])
        print("Stored mail password in macOS Keychain")
        exit(0)
    } catch {
        writeStderr(error.localizedDescription)
        exit(1)
    }
}

if let index = userArguments.firstIndex(of: "--stdio-proxy") {
    guard index + 1 < userArguments.count else {
        writeStderr("Missing socket path after --stdio-proxy")
        exit(2)
    }
    exit(LocalBridgeStdioProxy.run(socketPath: userArguments[index + 1]))
}

let deletePasswordOptions = ["--delete-mail-password", "--delete-icloud-password"]
if let index = userArguments.firstIndex(where: { deletePasswordOptions.contains($0) }) {
    guard index + 1 < userArguments.count else {
        writeStderr("Missing account after \(userArguments[index])")
        exit(2)
    }
    do {
        try MigratingCredentialStore.mail().deleteSecret(account: userArguments[index + 1])
        print("Removed mail password from macOS Keychain")
        exit(0)
    } catch {
        writeStderr(error.localizedDescription)
        exit(1)
    }
}

do {
    let configuration = try CommandLineInterface.launchConfiguration(arguments: userArguments)
    if configuration.requiresAppOwnedRuntime {
        writeStderr("Reader sidecars must be started by the MacMCP menu-bar app")
        exit(2)
    }
    if configuration.menuBar {
        await MenuBarHost.run(configuration: configuration)
        exit(0)
    }
    if configuration.hasSidecars {
        let runtime = try await BridgeRuntime.start(configuration: configuration)
        let bridge = await runtime.makeServer()
        do {
            try await bridge.run()
        } catch {
            await runtime.stop()
            throw error
        }
        await runtime.stop()
        exit(0)
    }

    let bridge = await BridgeServer()
    try await bridge.run()
} catch {
    writeStderr("MacMCP failed: \(error.localizedDescription)")
    exit(1)
}
