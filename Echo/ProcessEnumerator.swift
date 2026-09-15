import AppKit
import CoreAudio
import Darwin

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
            guard objectID != kAudioObjectUnknown,
                  let bundleID = stringProperty(objectID, kAudioProcessPropertyBundleID),
                  !bundleID.isEmpty
            else {
                return nil
            }
            let pid = pidProperty(objectID) ?? 0
            return (bundleID, objectID, pid)
        }
    }

    static func candidates(excluding excludedBundleIDs: Set<String>) -> [RunningAppCandidate] {
        let regularApps = regularRunningApps()
        let ownBundleID = Bundle.main.bundleIdentifier
        var idsByOwner: [String: [AudioObjectID]] = [:]

        for process in audioProcesses() {
            let owner = owningBundleID(
                pid: process.pid,
                processBundleID: process.bundleID,
                regularApps: regularApps
            )
            guard owner != ownBundleID, !excludedBundleIDs.contains(owner) else { continue }
            idsByOwner[owner, default: []].append(process.processObjectID)
        }

        var byBundle: [String: RunningAppCandidate] = [:]
        for (bundleID, ids) in idsByOwner {
            byBundle[bundleID] = RunningAppCandidate(
                bundleID: bundleID,
                displayName: displayName(for: bundleID, regularApps: regularApps),
                processObjectIDs: uniqueSorted(ids)
            )
        }

        for app in regularApps {
            guard let bundleID = app.bundleIdentifier,
                  bundleID != ownBundleID,
                  !excludedBundleIDs.contains(bundleID),
                  byBundle[bundleID] == nil
            else { continue }
            byBundle[bundleID] = RunningAppCandidate(
                bundleID: bundleID,
                displayName: app.localizedName ?? displayName(for: bundleID),
                processObjectIDs: []
            )
        }

        return byBundle.values.sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }

    static func processObjectIDs(for bundleID: String) -> [AudioObjectID] {
        let regularApps = regularRunningApps()
        var seen = Set<AudioObjectID>()
        var ids: [AudioObjectID] = []

        for process in audioProcesses() {
            guard belongs(process, to: bundleID, regularApps: regularApps) else { continue }
            guard seen.insert(process.processObjectID).inserted else { continue }
            ids.append(process.processObjectID)
        }

        return ids.sorted()
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
            processObjectIDs: []
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

    private static func displayName(for bundleID: String, regularApps: [NSRunningApplication]) -> String {
        if let name = regularApps.first(where: { $0.bundleIdentifier == bundleID })?.localizedName {
            return name
        }
        return displayName(for: bundleID)
    }

    private static func belongs(
        _ process: (bundleID: String, processObjectID: AudioObjectID, pid: pid_t),
        to bundleID: String,
        regularApps: [NSRunningApplication]
    ) -> Bool {
        let owner = owningBundleID(pid: process.pid, processBundleID: process.bundleID, regularApps: regularApps)
        if owner == bundleID || process.bundleID == bundleID {
            return true
        }
        guard process.bundleID.hasPrefix(bundleID + ".") else { return false }
        if let longer = longestPrefixMatch(process.bundleID, among: regularApps),
           longer != bundleID,
           longer.hasPrefix(bundleID + ".") {
            return false
        }
        return true
    }

    private static func owningBundleID(
        pid: pid_t,
        processBundleID: String,
        regularApps: [NSRunningApplication]
    ) -> String {
        if let ancestor = regularAncestorBundleID(of: pid) {
            return ancestor
        }
        if pid > 0, let url = NSRunningApplication(processIdentifier: pid)?.bundleURL,
           let owner = outermostAppBundleID(at: url) {
            return owner
        }
        if let match = longestPrefixMatch(processBundleID, among: regularApps) {
            return match
        }
        return processBundleID
    }

    private static func regularAncestorBundleID(of pid: pid_t) -> String? {
        guard pid > 0 else { return nil }
        var current = pid
        var seen = Set<pid_t>()
        while seen.insert(current).inserted {
            if let app = NSRunningApplication(processIdentifier: current),
               app.activationPolicy == .regular,
               let bundleID = app.bundleIdentifier,
               !bundleID.isEmpty {
                return bundleID
            }
            guard let parent = parentPID(of: current), parent > 1 else { return nil }
            current = parent
        }
        return nil
    }

    private static func parentPID(of pid: pid_t) -> pid_t? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.stride)
        let bytes = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size)
        guard bytes == size else { return nil }
        let ppid = pid_t(info.pbi_ppid)
        return ppid > 0 && ppid != pid ? ppid : nil
    }

    private static func outermostAppBundleID(at url: URL) -> String? {
        var current = url.standardizedFileURL
        var lastApp: URL?
        while current.path != "/" {
            if current.pathExtension == "app" {
                lastApp = current
            }
            current.deleteLastPathComponent()
        }
        guard let lastApp,
              let bundle = Bundle(url: lastApp),
              let bundleID = bundle.bundleIdentifier,
              !bundleID.isEmpty
        else { return nil }
        return bundleID
    }

    private static func longestPrefixMatch(_ processBundleID: String, among apps: [NSRunningApplication]) -> String? {
        var best: String?
        for app in apps {
            guard let appID = app.bundleIdentifier, !appID.isEmpty else { continue }
            let matches = processBundleID == appID || processBundleID.hasPrefix(appID + ".")
            guard matches else { continue }
            if let currentBest = best, appID.count <= currentBest.count { continue }
            best = appID
        }
        return best
    }

    private static func regularRunningApps() -> [NSRunningApplication] {
        NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }
    }

    private static func uniqueSorted(_ ids: [AudioObjectID]) -> [AudioObjectID] {
        Array(Set(ids)).sorted()
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
