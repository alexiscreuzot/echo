import CoreAudio
import Observation

@Observable
final class AudioRouter {
    private(set) var isRunning = false
    private(set) var status = "Idle"
    private(set) var levels: [String: Float] = [:]

    private let capture = AudioCapture()
    private var routeDescription = ""

    func checkDevice() {
        if !isRunning {
            refreshIdleStatus()
        }
    }

    func prepareDevice() async {
        guard DriverInstaller.needsInstall() else {
            checkDevice()
            return
        }
        status = "Installing Echo device…"
        do {
            try await DriverInstaller.ensureInstalled()
            refreshIdleStatus()
        } catch {
            status = error.localizedDescription
        }
    }

    func start(sources: [AudioSource]) {
        do {
            try startRouting(sources: sources)
        } catch {
            stop()
            status = error.localizedDescription
        }
    }

    func stop() {
        capture.stop()
        levels = [:]
        isRunning = false
        refreshIdleStatus()
    }

    func sync(sources: [AudioSource]) {
        guard isRunning else { return }
        do {
            try startRouting(sources: sources)
        } catch {
            stop()
            status = error.localizedDescription
        }
    }

    private func startRouting(sources: [AudioSource]) throws {
        guard EchoDevice.objectID() != nil else { throw EchoError.deviceMissing }

        let routed = sources.filter { $0.enabled && $0.isActive }.compactMap { source -> (AudioSource, AudioObjectID)? in
            guard let processID = source.processObjectID else { return nil }
            return (source, processID)
        }
        let muted = routed.filter(\.0.muted)
        let unmuted = routed.filter { !$0.0.muted }

        try capture.start(
            mutedProcessIDs: muted.map(\.1),
            unmutedProcessIDs: unmuted.map(\.1),
            bundleIDs: routed.map(\.0.bundleID)
        ) { [weak self] levels in
            guard let self, self.isRunning else { return }
            self.levels = levels
        }

        isRunning = true
        let names = sources.filter(\.enabled).map(\.displayName)
        routeDescription = "Routing \(names.joined(separator: ", ")) → Echo"
        refreshRunningStatus()
    }

    private func refreshRunningStatus() {
        status = routeDescription
    }

    private func refreshIdleStatus() {
        if EchoDevice.objectID() == nil {
            status = EchoError.deviceMissing.errorDescription ?? "Echo device not found."
        } else {
            status = "Idle"
        }
    }
}
