import AppKit
import CoreAudio
import UniformTypeIdentifiers

struct AudioSource: Identifiable, Hashable {
    var bundleID: String
    var displayName: String
    var enabled: Bool
    var muted: Bool = true
    var processObjectIDs: [AudioObjectID] = []

    var id: String { bundleID }
    var isActive: Bool {
        !processObjectIDs.isEmpty
    }

    var icon: NSImage {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            return NSWorkspace.shared.icon(forFile: url.path)
        }
        return NSWorkspace.shared.icon(for: .application)
    }
}

struct PersistedSource: Codable, Equatable {
    var bundleID: String
    var displayName: String
    var enabled: Bool
    var muted: Bool

    init(bundleID: String, displayName: String, enabled: Bool, muted: Bool) {
        self.bundleID = bundleID
        self.displayName = displayName
        self.enabled = enabled
        self.muted = muted
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        bundleID = try container.decode(String.self, forKey: .bundleID)
        displayName = try container.decode(String.self, forKey: .displayName)
        enabled = try container.decode(Bool.self, forKey: .enabled)
        muted = try container.decodeIfPresent(Bool.self, forKey: .muted) ?? true
    }
}

struct RunningAppCandidate: Identifiable, Hashable {
    var bundleID: String
    var displayName: String
    var processObjectIDs: [AudioObjectID] = []

    var id: String { bundleID }

    var icon: NSImage {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            return NSWorkspace.shared.icon(forFile: url.path)
        }
        return NSWorkspace.shared.icon(for: .application)
    }
}
