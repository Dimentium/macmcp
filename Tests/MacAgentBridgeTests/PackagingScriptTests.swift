import Foundation
import XCTest

final class PackagingScriptTests: XCTestCase {
    func testLocalAppBuildScriptChecksEmbeddedSidecar() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let script = try String(
            contentsOf: root.appendingPathComponent("scripts/build-local-app.sh"),
            encoding: .utf8
        )

        XCTAssertTrue(script.hasPrefix("#!/bin/bash\n"))
        XCTAssertTrue(script.contains("[[ \"$eventkit_binary\" != /* ]]"))
        XCTAssertTrue(script.contains("plutil -lint \"$info_plist\" \"$entitlements\""))
        XCTAssertTrue(script.contains("--product mac-agent-bridge"))
        XCTAssertTrue(script.contains("\"$app_eventkit\""))
        XCTAssertTrue(script.contains("codesign --verify --strict --verbose=2 \"$app_eventkit\""))
        XCTAssertTrue(script.contains("codesign --verify --deep --strict --verbose=2 \"$app\""))
    }

    func testLocalInstallScriptPinsSidecarsAndDoesNotResetTCC() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let script = try String(
            contentsOf: root.appendingPathComponent("scripts/install-local.sh"),
            encoding: .utf8
        )

        XCTAssertTrue(script.hasPrefix("#!/bin/bash\n"))
        XCTAssertTrue(script.contains("MAIL_REPO=\"https://github.com/Dimentium/mail-mcp\""))
        XCTAssertTrue(script.contains("MAIL_VERSION=\"v1.2.2\""))
        XCTAssertTrue(script.contains("MAIL_ARM64_SHA256=\"617e3322c2d240957767242d36dfd27f78d75f0dffff7c97c1538c597825b8e4\""))
        XCTAssertTrue(script.contains("CHE_COMMIT=\"a8598378b5e280b27005ab8cd21e9b5758312423\""))
        XCTAssertTrue(script.contains("CHE_RESOLUTION_SHA256=\"1bbf18605e61eb13014d140fa86e5aa550327bdf005f5567de40db6e2df4b93d\""))
        XCTAssertTrue(script.contains("-name 'mail-mcp-darwin-*'"))
        XCTAssertTrue(script.contains("--gmail-address"))
        XCTAssertTrue(script.contains("--reuse-existing-configuration"))
        XCTAssertTrue(script.contains("--chatgpt-tunnel-id ID"))
        XCTAssertTrue(script.contains("brew install openai/tools/tunnel-client"))
        XCTAssertTrue(script.contains("--store-chatgpt-tunnel-key"))
        XCTAssertTrue(script.contains("\"chatGPTTunnel\""))
        XCTAssertTrue(script.contains("existing ChatGPT tunnel profile is unreadable"))
        XCTAssertTrue(script.contains("tunnel-client run --profile $chatgpt_tunnel_profile"))
        XCTAssertTrue(script.contains("platform.openai.com/settings/organization/tunnels"))
        XCTAssertTrue(script.contains("platform.openai.com/api-keys"))
        XCTAssertTrue(script.contains("Reusing existing mail configuration and preserving Keychain passwords"))
        XCTAssertTrue(script.contains("Re-run the same command to upgrade"))
        XCTAssertTrue(script.contains("`--skip-password` during upgrades"))
        XCTAssertTrue(script.contains("stop_existing_runtime"))
        XCTAssertTrue(script.contains("wait_for_existing_runtime_exit 3"))
        XCTAssertTrue(script.contains("wait_for_existing_runtime_exit 2 ||"))
        XCTAssertTrue(script.contains("terminate_matching_command \"$libexec_dir/CheICalMCP\" TERM"))
        XCTAssertTrue(script.contains("cp \"$che_resolution\" \"$che_src/Package.resolved\""))
        XCTAssertTrue(script.contains("swift build --disable-automatic-resolution -c release --product CheICalMCP --package-path \"$che_src\""))
        XCTAssertTrue(script.contains("\"$stage_cli_path\" --store-mail-password \"$account\""))
        XCTAssertTrue(script.contains("app_config=\"$config_dir/launch.json\""))
        XCTAssertTrue(script.contains("ipc_socket=\"$config_dir/mcp.sock\""))
        XCTAssertTrue(script.contains("config_dir=\"$HOME/Library/Application Support/mac-agent-bridge\""))
        XCTAssertFalse(script.contains("--config-dir PATH"))
        XCTAssertFalse(script.contains("setup-chatgpt-tunnel.sh"))
        XCTAssertFalse(script.contains("mac-agent-bridge-tunnel-setup.new"))
        XCTAssertTrue(script.contains("\"--stdio-proxy\""))
        XCTAssertTrue(script.contains("\"schemaVersion\": 1"))
        XCTAssertTrue(script.contains("\"launchAtLogin\": True"))
        XCTAssertTrue(script.contains("codesign --verify --strict --verbose=2 \"$stage_cli_path\""))
        XCTAssertTrue(script.contains("stage_install_root=\"$(mktemp -d \"$install_root.staging.XXXXXX\")\""))
        XCTAssertTrue(script.contains("activate_staged_install()"))
        XCTAssertTrue(script.contains("rollback_activation()"))
        XCTAssertTrue(script.contains("echo \"Activating staged local install\""))
        XCTAssertTrue(script.contains("mv \"$stage_install_root\" \"$install_root\""))
        XCTAssertTrue(script.contains("mv \"$stage_app\" \"$target_app\""))
        let download = try XCTUnwrap(script.range(of: "Downloading pinned mail-mcp"))
        let activation = try XCTUnwrap(script.range(of: "Activating staged local install"))
        XCTAssertLessThan(download.lowerBound, activation.lowerBound)
        XCTAssertTrue(script.contains("\"mcpServers\""))
        XCTAssertFalse(script.contains("tccutil reset"))
    }

    func testLocalArchiveScriptExcludesWorkspaceArtifacts() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let script = try String(
            contentsOf: root.appendingPathComponent("scripts/package-local-archive.sh"),
            encoding: .utf8
        )

        XCTAssertTrue(script.hasPrefix("#!/bin/bash\n"))
        XCTAssertTrue(script.contains("--exclude '.git/'"))
        XCTAssertTrue(script.contains("--exclude '.github/'"))
        XCTAssertTrue(script.contains("--exclude '.build/'"))
        XCTAssertTrue(script.contains("--exclude '.claude/'"))
        XCTAssertTrue(script.contains("--exclude '__pycache__/'"))
        XCTAssertTrue(script.contains("--exclude '*.pyc'"))
        XCTAssertTrue(script.contains("--exclude 'dist/'"))
        XCTAssertTrue(script.contains("--exclude 'runtime/'"))
        XCTAssertTrue(script.contains("--exclude 'HANDOFF.md'"))
        XCTAssertTrue(script.contains("--exclude 'backlog.md'"))
        XCTAssertTrue(script.contains("shasum -a 256 \"$archive\" > \"$checksum\""))
        XCTAssertTrue(script.contains("scripts/install-local.sh --gmail-address you@gmail.com"))
    }

    func testDeploymentAcceptanceScriptIsIsolated() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let script = try String(
            contentsOf: root.appendingPathComponent("scripts/verify-local-deployment.sh"),
            encoding: .utf8
        )

        XCTAssertTrue(script.hasPrefix("#!/bin/bash\n"))
        XCTAssertTrue(script.contains("test_home=\"$test_root/home\""))
        XCTAssertTrue(script.contains("--no-open"))
        XCTAssertTrue(script.contains("--skip-password"))
        XCTAssertTrue(script.contains("--reuse-existing-configuration"))
        XCTAssertTrue(script.contains("--diagnose-json"))
        XCTAssertTrue(script.contains("MacMCP deployment acceptance failed during phase"))
        XCTAssertTrue(script.contains("GITHUB_ACTIONS"))
        XCTAssertTrue(script.contains("uninstall-local.sh"))
    }

    func testLocalUninstallScriptPreservesKeychainByDefault() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let script = try String(
            contentsOf: root.appendingPathComponent("scripts/uninstall-local.sh"),
            encoding: .utf8
        )

        XCTAssertTrue(script.hasPrefix("#!/bin/bash\n"))
        XCTAssertTrue(script.contains("Keychain mail passwords and the ChatGPT tunnel runtime API key are preserved"))
        XCTAssertTrue(script.contains("--delete-mail-password ADDRESS"))
        XCTAssertTrue(script.contains("--delete-chatgpt-tunnel-key"))
        XCTAssertTrue(script.contains("--unregister-login-item"))
        XCTAssertTrue(script.contains("terminate_matching_command \"$libexec_dir/CheICalMCP\" TERM"))
        XCTAssertTrue(script.contains("managed_tunnel_profile()"))
        XCTAssertTrue(script.contains("tunnel-client run --profile $tunnel_profile"))
        XCTAssertTrue(script.contains("wait_for_existing_runtime_exit 3"))
        XCTAssertTrue(script.contains("wait_for_existing_runtime_exit 2 ||"))
        XCTAssertTrue(script.contains("\"$cli_path\" --delete-mail-password \"$account\""))
        XCTAssertTrue(script.contains("\"$cli_path\" --delete-chatgpt-tunnel-key"))
        XCTAssertTrue(script.contains("[[ -L \"$bin_link\" ]]"))
        XCTAssertTrue(script.contains("legacy_tunnel_setup_link"))
        XCTAssertTrue(script.contains("rm -rf \"$target_app\""))
        XCTAssertTrue(script.contains("rm -rf \"$install_root\""))
        XCTAssertTrue(script.contains("rm -rf \"$config_dir\""))
        XCTAssertFalse(script.contains("--config-dir PATH"))
        XCTAssertFalse(script.contains("macmcp-local"))
        XCTAssertFalse(script.contains("tccutil reset"))
    }

    func testLoginItemPersistenceValidationIsPrivacySafe() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let script = try String(
            contentsOf: root.appendingPathComponent("scripts/validate-login-item-persistence.sh"),
            encoding: .utf8
        )

        XCTAssertTrue(script.hasPrefix("#!/bin/bash\n"))
        XCTAssertTrue(script.contains("macmcp-login-item-validation"))
        XCTAssertTrue(script.contains("--phase NAME"))
        XCTAssertTrue(script.contains("--skip-mail-validation"))
        XCTAssertTrue(script.contains("--login-item-status"))
        XCTAssertTrue(script.contains("--status-json"))
        XCTAssertTrue(script.contains("--client-approvals-json"))
        XCTAssertTrue(script.contains("validate-local-mail-readonly.py"))
        XCTAssertTrue(script.contains("accounts_configured=$count"))
        XCTAssertTrue(script.contains("process_stdio_proxy"))
        XCTAssertTrue(script.contains("process_chatgpt_tunnel"))
        XCTAssertTrue(script.contains("process_chatgpt_tunnel_proxy"))
        XCTAssertTrue(script.contains("chatGPTTunnel"))
        XCTAssertFalse(script.contains("pgrep -fl"))
        XCTAssertFalse(script.contains("tccutil reset"))
    }

}
