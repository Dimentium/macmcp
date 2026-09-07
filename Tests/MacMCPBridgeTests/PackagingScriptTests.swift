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
        XCTAssertTrue(script.contains("Sources/MacMCPBridge/Entitlements.plist"))
        XCTAssertTrue(script.contains("--product macmcp-bridge"))
        XCTAssertTrue(script.contains("--signing-identity ID"))
        XCTAssertTrue(script.contains("--mail-sidecar PATH"))
        XCTAssertTrue(script.contains("--output PATH"))
        XCTAssertTrue(script.contains("MACMCP_SIGNING_IDENTITY"))
        XCTAssertTrue(script.contains("arguments+=(--timestamp)"))
        XCTAssertTrue(script.contains("verify_secure_timestamp"))
        XCTAssertTrue(script.contains("Developer ID signature is missing a secure timestamp"))
        XCTAssertTrue(script.contains("\"$app_eventkit\""))
        XCTAssertTrue(script.contains("\"$app_mail\""))
        XCTAssertTrue(script.contains("codesign --verify --strict --verbose=2 \"$app_mail\""))
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
        XCTAssertTrue(script.contains("build-pinned-mail-sidecar.sh"))
        XCTAssertTrue(script.contains("build-pinned-eventkit-sidecar.sh"))
        XCTAssertTrue(script.contains("--gmail-address"))
        XCTAssertTrue(script.contains("--reuse-existing-configuration"))
        XCTAssertTrue(script.contains("legacy_install_root"))
        XCTAssertTrue(script.contains("mail-action-access.json"))
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
        XCTAssertFalse(script.contains("terminate_matching_command \"$libexec_dir/CheICalMCP\" TERM"))
        XCTAssertTrue(script.contains("\"$stage_cli_path\" --store-mail-password \"$account\""))
        XCTAssertTrue(script.contains("app_config=\"$config_dir/launch.json\""))
        XCTAssertTrue(script.contains("ipc_socket=\"$config_dir/mcp.sock\""))
        XCTAssertTrue(script.contains("config_dir=\"$HOME/Library/Application Support/macmcp\""))
        XCTAssertFalse(script.contains("--config-dir PATH"))
        XCTAssertFalse(script.contains("setup-chatgpt-tunnel.sh"))
        XCTAssertFalse(script.contains("mac-agent-bridge-tunnel-setup.new"))
        XCTAssertTrue(script.contains("legacy_bin_link_backup"))
        XCTAssertTrue(script.contains("copy_legacy_state()"))
        XCTAssertTrue(script.contains("$target_app/Contents/Resources/CheICalMCP"))
        XCTAssertTrue(script.contains("$target_app/Contents/Resources/mail-mcp"))
        XCTAssertFalse(script.contains("cp \"$mail_candidate\" \"$stage_libexec_dir/mail-mcp\""))
        XCTAssertFalse(script.contains("cp \"$che_binary\" \"$stage_libexec_dir/CheICalMCP\""))
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
        let mailBuild = try XCTUnwrap(script.range(of: "build-pinned-mail-sidecar.sh"))
        let activation = try XCTUnwrap(script.range(of: "Activating staged local install"))
        XCTAssertLessThan(mailBuild.lowerBound, activation.lowerBound)
        XCTAssertTrue(script.contains("\"mcpServers\""))
        XCTAssertFalse(script.contains("tccutil reset"))
    }

    func testPinnedEventKitBuildScriptVerifiesTheSourceAndDependencyGraph() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let script = try String(
            contentsOf: root.appendingPathComponent("scripts/build-pinned-eventkit-sidecar.sh"),
            encoding: .utf8
        )

        XCTAssertTrue(script.hasPrefix("#!/bin/bash\n"))
        XCTAssertTrue(script.contains("CHE_REPO=\"https://github.com/PsychQuant/che-ical-mcp.git\""))
        XCTAssertTrue(script.contains("CHE_COMMIT=\"a8598378b5e280b27005ab8cd21e9b5758312423\""))
        XCTAssertTrue(script.contains("CHE_RESOLUTION_SHA256=\"1bbf18605e61eb13014d140fa86e5aa550327bdf005f5567de40db6e2df4b93d\""))
        XCTAssertTrue(script.contains("remote get-url origin"))
        XCTAssertTrue(script.contains("cp \"$che_resolution\" \"$che_src/Package.resolved\""))
        XCTAssertTrue(script.contains("swift build --disable-automatic-resolution -c release --product CheICalMCP --package-path \"$che_src\""))
        XCTAssertTrue(script.contains("printf '%s\\n' \"$che_binary\""))
    }

    func testPinnedMailBuildScriptVerifiesTheSourceAndGoDependencyGraph() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let script = try String(
            contentsOf: root.appendingPathComponent("scripts/build-pinned-mail-sidecar.sh"),
            encoding: .utf8
        )

        XCTAssertTrue(script.hasPrefix("#!/bin/bash\n"))
        XCTAssertTrue(script.contains("MAIL_REPO=\"https://github.com/Dimentium/mail-mcp.git\""))
        XCTAssertTrue(script.contains("MAIL_VERSION=\"v1.2.2\""))
        XCTAssertTrue(script.contains("MAIL_COMMIT=\"a62cf5f34f999193393b7591450de887a98224f1\""))
        XCTAssertTrue(script.contains("MAIL_GO_MOD_SHA256=\"41c501de585b0948adc7aadf0c80f493d79a29779f1648b99124a20388d643b4\""))
        XCTAssertTrue(script.contains("MAIL_GO_SUM_SHA256=\"65acf0c5d1563f6749f1fb495f8b1a03edf7882a0e2febb73ed659604062d5e6\""))
        XCTAssertTrue(script.contains("MAIL_MINIMUM_GO_VERSION=\"1.25.4\""))
        XCTAssertTrue(script.contains("mail-mcp requires Go $MAIL_MINIMUM_GO_VERSION or later"))
        XCTAssertTrue(script.contains("remote get-url origin"))
        XCTAssertTrue(script.contains("GOWORK=off GOFLAGS= go -C \"$mail_src\" build -trimpath -mod=readonly -buildvcs=false"))
        XCTAssertTrue(script.contains("\"go.mod:$MAIL_GO_MOD_SHA256\""))
        XCTAssertTrue(script.contains("\"go.sum:$MAIL_GO_SUM_SHA256\""))
        XCTAssertTrue(script.contains("mail-mcp $filename checksum mismatch"))
        XCTAssertTrue(script.contains("printf '%s\\n' \"$mail_binary\""))
    }

    func testNotarizationScriptUsesAKeychainProfileAndValidatesTheResult() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let script = try String(
            contentsOf: root.appendingPathComponent("scripts/notarize-local-app.sh"),
            encoding: .utf8
        )

        XCTAssertTrue(script.hasPrefix("#!/bin/bash\n"))
        XCTAssertTrue(script.contains("Developer ID Application:"))
        XCTAssertTrue(script.contains("build-pinned-eventkit-sidecar.sh"))
        XCTAssertTrue(script.contains("build-pinned-mail-sidecar.sh"))
        XCTAssertTrue(script.contains("--keychain-profile \"$notary_profile\""))
        XCTAssertTrue(script.contains("xcrun notarytool submit \"$archive\""))
        XCTAssertTrue(script.contains("xcrun stapler staple \"$app\""))
        XCTAssertTrue(script.contains("xcrun stapler validate \"$app\""))
        XCTAssertTrue(script.contains("spctl --assess --type execute --verbose=4 \"$app\""))
        XCTAssertTrue(script.contains("ditto -c -k --sequesterRsrc --keepParent \"$app\" \"$archive\""))
        XCTAssertTrue(script.contains("shasum -a 256 \"$archive\" > \"$checksum\""))
        XCTAssertFalse(script.contains("AuthKey_"))
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

    func testSourceFormulaDeclaresRuntimeBuildDependencies() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let formula = try String(
            contentsOf: root.appendingPathComponent("Formula/macmcp.rb"),
            encoding: .utf8
        )

        XCTAssertTrue(formula.contains("depends_on \"go\""))
        XCTAssertTrue(formula.contains("depends_on \"python@3.14\""))
    }

    func testCIInstallsThePinnedGoToolchain() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let workflow = try String(
            contentsOf: root.appendingPathComponent(".github/workflows/ci.yml"),
            encoding: .utf8
        )

        XCTAssertTrue(workflow.contains("uses: actions/setup-go@v5"))
        XCTAssertTrue(workflow.contains("go-version: \"1.25.4\""))
        XCTAssertTrue(workflow.contains("scripts/verify-local-deployment.sh"))
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
        XCTAssertTrue(script.contains("remove_test_root()"))
        XCTAssertTrue(script.contains("HOME=\"$test_home\" go clean -modcache"))
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
        XCTAssertTrue(script.contains("terminate_matching_command \"$legacy_install_root/libexec/CheICalMCP\" TERM"))
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
