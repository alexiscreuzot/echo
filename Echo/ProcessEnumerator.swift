import AppKit
import CoreAudio

enum ProcessEnumerator {
    static func audioProcesses() -> [(bundleID: String, processObjectID: AudioObjectID, pid: pid_t)] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &dataSize
        ) == noErr, dataSize > 0 else {
            return []
        }

        let count = Int(dataSize) / MemoryLayout<AudioObjectID>.size
        var processIDs = [AudioObjectID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &dataSize,
            &processIDs
        ) == noErr else {
            return []
        }

        return processIDs.compactMap { objectID in
            guard let bundleID = stringProperty(objectID, kAudioProcessPropertyBundleID), !bundleID.isEmpty else {
                return nil
            }
            let pid = pidProperty(objectID) ?? 0
            return (bundleID, objectID, pid)
        }
    }

    static func candidates(excluding excludedBundleIDs: Set<String>) -> [RunningAppCandidate] {
        var byBundle: [String: RunningAppCandidate] = [:]

        for process in audioProcesses() {
            guard !excludedBundleIDs.contains(process.bundleID) else { continue }
            let name = NSRunningApplication(processIdentifier: process.pid)?.localizedName
                ?? displayName(for: process.bundleID)
            byBundle[process.bundleID] = RunningAppCandidate(
                bundleID: process.bundleID,
                displayName: name,
                processObjectID: process.processObjectID
            )
        }

        let ownBundleID = Bundle.main.bundleIdentifier
        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
            guard let bundleID = app.bundleIdentifier,
                  bundleID != ownBundleID,
                  !excludedBundleIDs.contains(bundleID),
                  byBundle[bundleID] == nil
            else { continue }
            byBundle[bundleID] = RunningAppCandidate(
                bundleID: bundleID,
                displayName: app.localizedName ?? displayName(for: bundleID),
                processObjectID: nil
            )
        }

        return byBundle.values.sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }

    static func processObjectID(for bundleID: String) -> AudioObjectID? {
        audioProcesses().first(where: { $0.bundleID == bundleID })?.processObjectID
    }

    static func installedApplications(excluding excludedBundleIDs: Set<String>) -> [RunningAppCandidate] {
        loadInstalledApplications().filter { !excludedBundleIDs.contains($0.bundleID) }
    }

    private static var cachedInstalledApplications: [RunningAppCandidate]?

    private static func loadInstalledApplications() -> [RunningAppCandidate] {
        if let cachedInstalledApplications { return cachedInstalledApplications }

        let ownBundleID = Bundle.main.bundleIdentifier
        var byBundle: [String: RunningAppCandidate] = [:]
        let fileManager = FileManager.default
        let roots = [
            URL(fileURLWithPath: "/Applications", isDirectory: true),
            URL(fileURLWithPath: "/System/Applications", isDirectory: true),
            fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Applications", isDirectory: true)
        ]

        for root in roots {
            collectApps(in: root, fileManager: fileManager, into: &byBundle, excluding: ownBundleID, recurse: true)
        }

        let result = byBundle.values.sorted {
            $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
        }
        cachedInstalledApplications = result
        return result
    }

    private static func collectApps(
        in directory: URL,
        fileManager: FileManager,
        into byBundle: inout [String: RunningAppCandidate],
        excluding ownBundleID: String?,
        recurse: Bool
    ) {
        guard let contents = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        for url in contents {
            if url.pathExtension == "app" {
                addInstalledApp(url, into: &byBundle, excluding: ownBundleID)
                continue
            }
            guard recurse else { continue }
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey])
            if values?.isDirectory == true {
                collectApps(in: url, fileManager: fileManager, into: &byBundle, excluding: ownBundleID, recurse: false)
            }
        }
    }

    private static func addInstalledApp(
        _ url: URL,
        into byBundle: inout [String: RunningAppCandidate],
        excluding ownBundleID: String?
    ) {
        guard let bundle = Bundle(url: url),
              let bundleID = bundle.bundleIdentifier,
              !bundleID.isEmpty,
              bundleID != ownBundleID,
              byBundle[bundleID] == nil
        else { return }

        let name = (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String)
            ?? url.deletingPathExtension().lastPathComponent
        byBundle[bundleID] = RunningAppCandidate(
            bundleID: bundleID,
            displayName: name,
            processObjectID: nil
        )
    }

    static func displayName(for bundleID: String) -> String {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID),
           let bundle = Bundle(url: url),
           let name = bundle.object(forInfoDictionaryKey: "CFBundleName") as? String {
            return name
        }
        return bundleID
    }

    private static func stringProperty(_ objectID: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size = UInt32(MemoryLayout<CFString>.size)
        var value: Unmanaged<CFString>?
        let status = withUnsafeMutablePointer(to: &value) { pointer in
            AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, pointer)
        }
        guard status == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }

    private static func pidProperty(_ objectID: AudioObjectID) -> pid_t? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyPID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var pid: pid_t = 0
        var size = UInt32(MemoryLayout<pid_t>.size)
        let status = AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, &pid)
        return status == noErr ? pid : nil
    }
}
