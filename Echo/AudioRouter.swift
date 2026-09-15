import Observation

@Observable
final class AudioRouter {
    let filePlayer: FilePlayer
    private(set) var isRunning = false
    private(set) var status = "Idle"
    private(set) var levels: [String: Float] = [:]

    private let capture = AudioCapture()
    private var routeDescription = ""
    private var lastSources: [AudioSource] = []

    init(filePlayer: FilePlayer) {
        self.filePlayer = filePlayer
    }

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
            filePlayer.play()
        } catch {
            stop()
            status = error.localizedDescription
        }
    }

    func stop() {
        filePlayer.pause()
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

    func report(_ message: String) {
        status = message
    }

    func refreshFileStatus() {
        guard isRunning else { return }
        updateRouteDescription()
    }

    private func startRouting(sources: [AudioSource]) throws {
        guard EchoDevice.objectID() != nil else { throw EchoError.deviceMissing }

        let routed = sources.filter { $0.enabled && $0.isActive }
        let muted = routed.filter(\.muted).flatMap(\.processObjectIDs)
        let unmuted = routed.filter { !$0.muted }.flatMap(\.processObjectIDs)

        try capture.start(
            mutedProcessIDs: muted,
            unmutedProcessIDs: unmuted,
            bundleIDs: routed.map(\.bundleID),
            filePlayer: filePlayer
        ) { [weak self] levels in
            guard let self, self.isRunning else { return }
            self.levels = levels
            self.filePlayer.publishProgress()
        }

        isRunning = true
        lastSources = sources
        updateRouteDescription()
    }

    private func updateRouteDescription() {
        var names = lastSources.filter(\.enabled).map(\.displayName)
        if let fileName = filePlayer.fileName {
            names.append(fileName)
        }
        routeDescription = names.isEmpty
            ? "Routing to Echo"
            : "Routing \(names.joined(separator: ", "))"
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
