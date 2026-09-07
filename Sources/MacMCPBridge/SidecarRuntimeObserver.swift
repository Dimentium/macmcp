import Foundation

actor SidecarRuntimeObserver {
    private let statusObserver: SidecarStatusObserver
    private var supervisor: SidecarSupervisor?
    private var router: GatewayRouter?
    private var policy: ReaderPolicy?

    init(statusObserver: SidecarStatusObserver) {
        self.statusObserver = statusObserver
    }

    func bind(supervisor: SidecarSupervisor, router: GatewayRouter, policy: ReaderPolicy) {
        self.supervisor = supervisor
        self.router = router
        self.policy = policy
    }

    func handle(_ event: SidecarEvent) async {
        await statusObserver.handle(event)

        guard case .started(let id, _) = event,
              let supervisor,
              let router,
              let policy,
              let snapshot = await supervisor.snapshot(id: id),
              snapshot.restartCount > 0
        else {
            return
        }

        do {
            let io = try await supervisor.connection(for: id)
            await router.detach(sidecarID: id)
            try await router.attach(
                sidecarID: id,
                client: SidecarMCPClient(id: id, io: io),
                policy: policy
            )
        } catch {
            await markUnavailable(sidecarID: id)
        }
    }

    private func markUnavailable(sidecarID: String) async {
        switch sidecarID {
        case ReaderPolicy.mailSidecarID:
            await statusObserver.statusSource.updateMail(.unavailable)
        case ReaderPolicy.eventKitSidecarID:
            await statusObserver.statusSource.updateCalendar(.unavailable)
            await statusObserver.statusSource.updateReminders(.unavailable)
        default:
            return
        }
    }
}
