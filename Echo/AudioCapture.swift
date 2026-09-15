import CoreAudio
import Foundation

final class AudioCapture {

    private var aggregateID: AudioObjectID = 0
    private var ioDeviceID: AudioObjectID = 0
    private var usesEchoDirect = false
    private var mutedTapID: AudioObjectID = 0
    private var unmutedTapID: AudioObjectID = 0
    private var ioProcID: AudioDeviceIOProcID?
    private let meter = MeterState()
    private let fileMeter = MeterState()
    private var bundleIDs: [String] = []
    private var filePlayer: FilePlayer?
    private var onLevels: (([String: Float]) -> Void)?
    private var fileScratch: UnsafeMutablePointer<Float>?
    private let fileScratchFrameCapacity = 8192

    deinit {
        stop()
    }

    func start(
        mutedProcessIDs: [AudioObjectID],
        unmutedProcessIDs: [AudioObjectID],
        bundleIDs: [String],
        filePlayer: FilePlayer,
        onLevels: @escaping ([String: Float]) -> Void
    ) throws {
        stop()

        let muted = Array(Set(mutedProcessIDs.filter { $0 != kAudioObjectUnknown }))
        let unmuted = Array(Set(unmutedProcessIDs.filter { $0 != kAudioObjectUnknown }))
        guard !muted.isEmpty || !unmuted.isEmpty || filePlayer.hasFile else {
            throw EchoError.noActiveSources
        }

        self.bundleIDs = bundleIDs
        self.filePlayer = filePlayer
        self.onLevels = onLevels
        meter.reset()
        fileMeter.reset()

        let hasTaps = !muted.isEmpty || !unmuted.isEmpty
        if hasTaps {
            try createTapAggregate(mutedProcessIDs: muted, unmutedProcessIDs: unmuted)
            try activate(aggregateID)
            ioDeviceID = aggregateID
            usesEchoDirect = false
        } else {
            guard let echoID = EchoDevice.objectID() else { throw EchoError.deviceMissing }
            ioDeviceID = echoID
            usesEchoDirect = true
            try activate(echoID)
        }
        allocateScratch()
        try startIO()
    }

    func stop() {
        if let ioProcID, ioDeviceID != 0 {
            AudioDeviceStop(ioDeviceID, ioProcID)
            AudioDeviceDestroyIOProcID(ioDeviceID, ioProcID)
        }
        ioProcID = nil
        ioDeviceID = 0
        usesEchoDirect = false

        if aggregateID != 0 {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = 0
        }
        if mutedTapID != 0 {
            AudioHardwareDestroyProcessTap(mutedTapID)
            mutedTapID = 0
        }
        if unmutedTapID != 0 {
            AudioHardwareDestroyProcessTap(unmutedTapID)
            unmutedTapID = 0
        }
        deallocateScratch()
        bundleIDs = []
        filePlayer = nil
        onLevels = nil
        meter.reset()
        fileMeter.reset()
    }

    private func createTapAggregate(mutedProcessIDs: [AudioObjectID], unmutedProcessIDs: [AudioObjectID]) throws {
        var tapEntries: [[String: Any]] = []

        if !mutedProcessIDs.isEmpty {
            let (description, tapID) = try makeTap(
                processIDs: mutedProcessIDs,
                speakersMuted: true,
                name: "Echo Mix Muted"
            )
            mutedTapID = tapID
            tapEntries.append([
                kAudioSubTapUIDKey: description.uuid.uuidString,
                kAudioSubTapDriftCompensationKey: true
            ])
        }

        if !unmutedProcessIDs.isEmpty {
            do {
                let (description, tapID) = try makeTap(
                    processIDs: unmutedProcessIDs,
                    speakersMuted: false,
                    name: "Echo Mix Unmuted"
                )
                unmutedTapID = tapID
                tapEntries.append([
                    kAudioSubTapUIDKey: description.uuid.uuidString,
                    kAudioSubTapDriftCompensationKey: true
                ])
            } catch {
                if mutedTapID != 0 {
                    AudioHardwareDestroyProcessTap(mutedTapID)
                    mutedTapID = 0
                }
                throw error
            }
        }

        var aggregateDescription: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Echo Mix",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceTapAutoStartKey: 0,
            kAudioAggregateDeviceMainSubDeviceKey: EchoDevice.uid,
            kAudioAggregateDeviceClockDeviceKey: EchoDevice.uid,
            kAudioAggregateDeviceSubDeviceListKey: [[
                kAudioSubDeviceUIDKey: EchoDevice.uid,
                kAudioSubDeviceInputChannelsKey: 0,
                kAudioSubDeviceOutputChannelsKey: 2,
                kAudioSubDeviceDriftCompensationKey: true
            ]]
        ]
        if !tapEntries.isEmpty {
            aggregateDescription[kAudioAggregateDeviceTapListKey] = tapEntries
        }

        var newAggregateID = AudioObjectID()
        let status = AudioHardwareCreateAggregateDevice(aggregateDescription as CFDictionary, &newAggregateID)
        guard status == noErr, newAggregateID != kAudioObjectUnknown else {
            if mutedTapID != 0 {
                AudioHardwareDestroyProcessTap(mutedTapID)
                mutedTapID = 0
            }
            if unmutedTapID != 0 {
                AudioHardwareDestroyProcessTap(unmutedTapID)
                unmutedTapID = 0
            }
            throw EchoError.aggregateFailed(status)
        }
        aggregateID = newAggregateID
    }

    private func makeTap(
        processIDs: [AudioObjectID],
        speakersMuted: Bool,
        name: String
    ) throws -> (CATapDescription, AudioObjectID) {
        let description = CATapDescription(stereoMixdownOfProcesses: processIDs)
        description.isPrivate = true
        description.muteBehavior = speakersMuted ? .muted : .unmuted
        description.name = name
        description.isProcessRestoreEnabled = true

        var tapID = AudioObjectID()
        let status = AudioHardwareCreateProcessTap(description, &tapID)
        guard status == noErr, tapID != kAudioObjectUnknown else {
            throw EchoError.tapFailed(status)
        }
        return (description, tapID)
    }

    private func startIO() throws {
        var newProcID: AudioDeviceIOProcID?
        var status = AudioDeviceCreateIOProcIDWithBlock(&newProcID, ioDeviceID, nil) { [weak self] _, inputData, _, outputData, _ in
            self?.handleIO(input: inputData, output: outputData)
        }
        if status != noErr || newProcID == nil {
            Thread.sleep(forTimeInterval: 0.05)
            try activate(ioDeviceID)
            status = AudioDeviceCreateIOProcIDWithBlock(&newProcID, ioDeviceID, nil) { [weak self] _, inputData, _, outputData, _ in
                self?.handleIO(input: inputData, output: outputData)
            }
        }
        guard status == noErr, let newProcID else {
            throw EchoError.engineStartFailed("Could not start the Echo audio path (\(status)).")
        }
        let startStatus = AudioDeviceStart(ioDeviceID, newProcID)
        guard startStatus == noErr else {
            AudioDeviceDestroyIOProcID(ioDeviceID, newProcID)
            throw EchoError.engineStartFailed("Could not start the Echo audio path (\(startStatus)).")
        }
        ioProcID = newProcID
    }

    private func handleIO(
        input inputData: UnsafePointer<AudioBufferList>,
        output outputData: UnsafeMutablePointer<AudioBufferList>
    ) {
        let tapPeak: Float
        if usesEchoDirect {
            // Echo’s input is the loopback of this output — never feed it back.
            Self.zeroOutput(outputData)
            tapPeak = 0
        } else if Self.hasTapInput(inputData) {
            tapPeak = Self.relayTap(from: inputData, to: outputData)
        } else {
            Self.zeroOutput(outputData)
            tapPeak = 0
        }

        var filePeak: Float = 0
        if let filePlayer, let scratch = fileScratch {
            let frames = min(Self.frameCount(of: outputData), fileScratchFrameCapacity)
            if frames > 0 {
                memset(scratch, 0, frames * 2 * MemoryLayout<Float>.stride)
                filePeak = filePlayer.render(into: scratch, frameCount: frames)
                Self.mixFile(scratch: scratch, frames: frames, into: outputData)
            }
        }

        let mixValue = meter.publish(peak: max(tapPeak, filePeak))
        let fileValue = fileMeter.publish(peak: filePeak)
        guard mixValue != nil || fileValue != nil else { return }
        let ids = bundleIDs
        let mixLevel = mixValue ?? meter.lastValue
        let fileLevel = fileValue ?? fileMeter.lastValue
        let callback = onLevels
        DispatchQueue.main.async { [weak self] in
            guard self != nil else { return }
            var entries = ids.map { ($0, mixLevel) }
            entries.append((FilePlayer.levelKey, fileLevel))
            callback?(Dictionary(uniqueKeysWithValues: entries))
        }
    }

    private static func hasTapInput(_ inputData: UnsafePointer<AudioBufferList>) -> Bool {
        let input = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inputData))
        return input.contains { $0.mData != nil && $0.mDataByteSize > 0 }
    }

    private static func zeroOutput(_ outputData: UnsafeMutablePointer<AudioBufferList>) {
        let output = UnsafeMutableAudioBufferListPointer(outputData)
        for buffer in output {
            if let dst = buffer.mData {
                memset(dst, 0, Int(buffer.mDataByteSize))
            }
        }
    }

    private static func frameCount(of outputData: UnsafeMutablePointer<AudioBufferList>) -> Int {
        let output = UnsafeMutableAudioBufferListPointer(outputData)
        guard let first = output.first, first.mData != nil else { return 0 }
        let channels = max(1, Int(first.mNumberChannels == 0 ? 2 : first.mNumberChannels))
        return Int(first.mDataByteSize) / (MemoryLayout<Float>.stride * channels)
    }

    private func activate(_ deviceID: AudioObjectID) throws {
        var alive: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsAlive,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        for _ in 0..<40 {
            size = UInt32(MemoryLayout<UInt32>.size)
            let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &alive)
            if status == noErr, alive != 0, Self.hasStreams(deviceID) {
                return
            }
            Thread.sleep(forTimeInterval: 0.025)
        }
        throw EchoError.engineStartFailed("Echo audio path is not ready.")
    }

    private static func hasStreams(_ deviceID: AudioObjectID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        let status = AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &size)
        return status == noErr && size > 0
    }

    /// Copies the tap’s trailing stereo channels into Echo and returns a linear peak.
    @discardableResult
    private static func relayTap(
        from inputData: UnsafePointer<AudioBufferList>,
        to outputData: UnsafeMutablePointer<AudioBufferList>
    ) -> Float {
        let input = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inputData))
        let output = UnsafeMutableAudioBufferListPointer(outputData)
        var peak: Float = 0

        if input.count == 1, output.count == 1,
           let inData = input[0].mData, let outData = output[0].mData {
            let inChannels = max(1, Int(input[0].mNumberChannels))
            let outChannels = max(1, Int(output[0].mNumberChannels == 0 ? 2 : output[0].mNumberChannels))
            let inFrames = Int(input[0].mDataByteSize) / (MemoryLayout<Float>.stride * inChannels)
            let outFrames = Int(output[0].mDataByteSize) / (MemoryLayout<Float>.stride * outChannels)
            let frames = min(inFrames, outFrames)
            let inSamples = inData.assumingMemoryBound(to: Float.self)
            let outSamples = outData.assumingMemoryBound(to: Float.self)
            let channelOffset = max(0, inChannels - outChannels)
            for frame in 0..<frames {
                for channel in 0..<outChannels {
                    let sample = inSamples[frame * inChannels + min(channelOffset + channel, inChannels - 1)]
                    peak = max(peak, abs(sample))
                    outSamples[frame * outChannels + channel] = sample
                }
            }
            return min(peak, 1)
        }

        let offset = max(0, input.count - output.count)
        for index in 0..<output.count {
            let inIndex = min(offset + index, max(input.count, 1) - 1)
            guard inIndex < input.count,
                  let src = input[inIndex].mData,
                  let dst = output[index].mData
            else { continue }
            let count = min(
                Int(input[inIndex].mDataByteSize),
                Int(output[index].mDataByteSize)
            ) / MemoryLayout<Float>.stride
            let inSamples = src.assumingMemoryBound(to: Float.self)
            let outSamples = dst.assumingMemoryBound(to: Float.self)
            for sample in 0..<count {
                peak = max(peak, abs(inSamples[sample]))
                outSamples[sample] = inSamples[sample]
            }
            let outBytes = Int(output[index].mDataByteSize)
            let copiedBytes = count * MemoryLayout<Float>.stride
            if copiedBytes < outBytes {
                memset(dst.advanced(by: copiedBytes), 0, outBytes - copiedBytes)
            }
        }
        return min(peak, 1)
    }

    private static func mixFile(
        scratch: UnsafePointer<Float>,
        frames: Int,
        into outputData: UnsafeMutablePointer<AudioBufferList>
    ) {
        let output = UnsafeMutableAudioBufferListPointer(outputData)
        if output.count == 1, let outData = output[0].mData {
            let channels = max(1, Int(output[0].mNumberChannels == 0 ? 2 : output[0].mNumberChannels))
            let outFrames = Int(output[0].mDataByteSize) / (MemoryLayout<Float>.stride * channels)
            let count = min(frames, outFrames)
            let outSamples = outData.assumingMemoryBound(to: Float.self)
            for frame in 0..<count {
                for channel in 0..<channels {
                    outSamples[frame * channels + channel] += scratch[frame * 2 + min(channel, 1)]
                }
            }
            return
        }
        for (channel, buffer) in output.enumerated() {
            guard let dst = buffer.mData else { continue }
            let count = min(frames, Int(buffer.mDataByteSize) / MemoryLayout<Float>.stride)
            let outSamples = dst.assumingMemoryBound(to: Float.self)
            let srcChannel = min(channel, 1)
            for frame in 0..<count {
                outSamples[frame] += scratch[frame * 2 + srcChannel]
            }
        }
    }

    private func allocateScratch() {
        deallocateScratch()
        let count = fileScratchFrameCapacity * 2
        let pointer = UnsafeMutablePointer<Float>.allocate(capacity: count)
        pointer.initialize(repeating: 0, count: count)
        fileScratch = pointer
    }

    private func deallocateScratch() {
        guard let scratch = fileScratch else { return }
        scratch.deinitialize(count: fileScratchFrameCapacity * 2)
        scratch.deallocate()
        fileScratch = nil
    }
}

private final class MeterState {
    private let lock = NSLock()
    private var peak: Float = 0
    private var lastPublish: CFAbsoluteTime = 0
    private var lastPublished: Float = 0

    var lastValue: Float {
        lock.lock()
        defer { lock.unlock() }
        return lastPublished
    }

    func reset() {
        lock.lock()
        peak = 0
        lastPublish = 0
        lastPublished = 0
        lock.unlock()
    }

    func publish(peak incoming: Float) -> Float? {
        lock.lock()
        defer { lock.unlock() }
        peak = max(peak * 0.88, incoming)
        let now = CFAbsoluteTimeGetCurrent()
        guard now - lastPublish >= 0.05 else { return nil }
        lastPublish = now
        let value = Self.meterLevel(from: peak)
        lastPublished = value
        peak *= 0.7
        return value
    }

    private static func meterLevel(from peak: Float) -> Float {
        guard peak.isFinite, peak > 0.000_001 else { return 0 }
        let minDb: Float = -48
        let db = 20 * log10(peak)
        return max(0, min(1, (db - minDb) / -minDb))
    }
}
