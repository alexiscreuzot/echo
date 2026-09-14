import AppKit
import CoreAudio
import Observation

@Observable
final class SourceStore {
    private static let defaultsKey = "echo.sources"

    var sources: [AudioSource] = []

    private var processListListener: AudioObjectPropertyListenerBlock?
    private var workspaceObservers: [NSObjectProtocol] = []

    init() {
        load()
        refreshProcessObjects()
        observeWorkspace()
        observeProcessList()
    }

    deinit {
        removeProcessListListener()
        workspaceObservers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
    }

    func add(_ candidate: RunningAppCandidate) {
        guard !sources.contains(where: { $0.bundleID == candidate.bundleID }) else { return }
        sources.append(
            AudioSource(
                bundleID: candidate.bundleID,
                displayName: candidate.displayName,
                enabled: true,
                muted: true,
                processObjectID: candidate.processObjectID ?? ProcessEnumerator.processObjectID(for: candidate.bundleID)
            )
        )
        persist()
    }

    func remove(id: String) {
        sources.removeAll { $0.bundleID == id }
        persist()
    }

    func toggle(_ source: AudioSource) {
        guard let index = sources.firstIndex(where: { $0.bundleID == source.bundleID }) else { return }
        sources[index].enabled.toggle()
        persist()
    }

    func toggleMute(_ source: AudioSource) {
        guard let index = sources.firstIndex(where: { $0.bundleID == source.bundleID }) else { return }
        sources[index].muted.toggle()
        persist()
    }

    func refreshProcessObjects() {
        for index in sources.indices {
            sources[index].processObjectID = ProcessEnumerator.processObjectID(for: sources[index].bundleID)
        }
    }

    func availableCandidates() -> [RunningAppCandidate] {
        ProcessEnumerator.candidates(excluding: Set(sources.map(\.bundleID)))
    }

    private func persist() {
        let payload = sources.map {
            PersistedSource(
                bundleID: $0.bundleID,
                displayName: $0.displayName,
                enabled: $0.enabled,
                muted: $0.muted
            )
        }
        if let data = try? JSONEncoder().encode(payload) {
            UserDefaults.standard.set(data, forKey: Self.defaultsKey)
        }
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: Self.defaultsKey),
              let payload = try? JSONDecoder().decode([PersistedSource].self, from: data)
        else { return }
        sources = payload.map {
            AudioSource(
                bundleID: $0.bundleID,
                displayName: $0.displayName,
                enabled: $0.enabled,
                muted: $0.muted,
                processObjectID: nil
            )
        }
    }

    private func observeWorkspace() {
        let center = NSWorkspace.shared.notificationCenter
        let handler: (Notification) -> Void = { [weak self] _ in
            self?.refreshProcessObjects()
        }
        workspaceObservers = [
            center.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main, using: handler),
            center.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main, using: handler)
        ]
    }

    private func observeProcessList() {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            DispatchQueue.main.async {
                self?.refreshProcessObjects()
            }
        }
        processListListener = listener
        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            DispatchQueue.main,
            listener
        )
    }

    private func removeProcessListListener() {
        guard let listener = processListListener else { return }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectRemovePropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            DispatchQueue.main,
            listener
        )
        processListListener = nil
    }
}
