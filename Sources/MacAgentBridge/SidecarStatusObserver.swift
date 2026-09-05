import Foundation

struct SidecarStatusObserver: Sendable {
    let statusSource: BridgeStatusSource

    func handle(_ event: SidecarEvent) async {
        let sidecarID: String
        switch event {
        case .stopped(let id, _), .failed(let id, _):
            sidecarID = id
        case .started, .restarting, .stderr:
            return
        }

        switch sidecarID {
        case ReaderPolicy.mailSidecarID:
            await statusSource.updateMail(.unavailable)
        case ReaderPolicy.eventKitSidecarID:
            await statusSource.updateCalendar(.unavailable)
            await statusSource.updateReminders(.unavailable)
        default:
            return
        }
    }
}
