import Foundation

struct SidecarStatusObserver: Sendable {
    let statusSource: BridgeStatusSource

    func handle(_ event: SidecarEvent) async {
        let sidecarID: String
        let componentState: BridgeStatus.ComponentState
        switch event {
        case .stopped(let id, _), .failed(let id, _):
            sidecarID = id
            componentState = .unavailable
        case .started(let id, _), .restarting(let id, _):
            sidecarID = id
            componentState = .connectedUnverified
        case .stderr:
            return
        }

        switch sidecarID {
        case ReaderPolicy.mailSidecarID:
            await statusSource.updateMail(componentState)
        case ReaderPolicy.eventKitSidecarID:
            await statusSource.updateCalendar(componentState)
            await statusSource.updateReminders(componentState)
        default:
            return
        }
    }
}
