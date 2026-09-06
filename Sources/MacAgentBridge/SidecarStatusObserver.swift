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
        case .started(let id, _):
            sidecarID = id
            componentState = .connectedUnverified
        case .restarting(let id, let attempt):
            sidecarID = id
            componentState = .connectedUnverified
            switch id {
            case ReaderPolicy.mailSidecarID:
                await statusSource.updateMailRestartCount(attempt)
            case ReaderPolicy.eventKitSidecarID:
                await statusSource.updateEventKitRestartCount(attempt)
            default:
                return
            }
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
