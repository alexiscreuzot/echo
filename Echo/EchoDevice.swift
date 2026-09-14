import CoreAudio

enum EchoDevice {
    static let uid = "EchoDevice_UID"
    static let name = "Echo"

    static func objectID() -> AudioObjectID? {
        var uid = Self.uid as CFString
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslateUIDToDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID = AudioObjectID()
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = withUnsafeMutablePointer(to: &uid) { qualifier in
            AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject),
                &address,
                UInt32(MemoryLayout<CFString>.size),
                qualifier,
                &size,
                &deviceID
            )
        }
        guard status == noErr, deviceID != kAudioObjectUnknown else { return nil }
        return deviceID
    }
}

enum EchoError: LocalizedError {
    case deviceMissing
    case driverInstallCancelled
    case driverInstallFailed(String)
    case noActiveSources
    case tapFailed(OSStatus)
    case aggregateFailed(OSStatus)
    case engineStartFailed(String)

    var errorDescription: String? {
        switch self {
        case .deviceMissing:
            return "Echo device not found. The driver may be missing or not signed with a Developer ID certificate."
        case .driverInstallCancelled:
            return "Administrator access is required to install the Echo audio device."
        case .driverInstallFailed(let message):
            return "Could not install the Echo audio device. \(message)"
        case .noActiveSources:
            return "None of the enabled apps are currently producing audio."
        case .tapFailed(let status):
            return "Could not tap app audio (\(status)). Grant System Audio Recording in Privacy settings."
        case .aggregateFailed(let status):
            return "Could not create the tap mix device (\(status))."
        case .engineStartFailed(let message):
            return message
        }
    }
}
