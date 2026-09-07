import Foundation
import ServiceManagement

enum LoginItemStatus: Equatable, Sendable {
    case enabled
    case notRegistered
    case requiresApproval
    case notFound
    case unavailable

    var label: String {
        switch self {
        case .enabled:
            return "enabled"
        case .notRegistered:
            return "not_registered"
        case .requiresApproval:
            return "requires_approval"
        case .notFound:
            return "not_found"
        case .unavailable:
            return "unavailable"
        }
    }
}

protocol LoginItemControlling: AnyObject {
    var status: LoginItemStatus { get }
    func register() throws
    func unregister() throws
}

final class SMAppLoginItemController: LoginItemControlling {
    var status: LoginItemStatus {
        switch SMAppService.mainApp.status {
        case .enabled:
            return .enabled
        case .notRegistered:
            return .notRegistered
        case .requiresApproval:
            return .requiresApproval
        case .notFound:
            return .notFound
        @unknown default:
            return .unavailable
        }
    }

    func register() throws {
        try SMAppService.mainApp.register()
    }

    func unregister() throws {
        try SMAppService.mainApp.unregister()
    }
}
