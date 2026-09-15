import AVFoundation
import Darwin
import Foundation
import Observation

@Observable
final class FilePlayer {
    static let levelKey = "echo.file"
    static let sampleRate: Double = 48_000

    private(set) var fileName: String?
    private(set) var filePath: String?
    private(set) var isPlaying = false
    private(set) var isLoading = false
    private(set) var progress: Double = 0
    private(set) var duration: TimeInterval = 0
    private(set) var muted = true
    private(set) var loadError: String?

    private static let defaultsKey = "echo.playerFile"
    private static let mutedKey = "echo.playerMuted"

    private let lock = NSLock()
    private let decodeQueue = DispatchQueue(label: "echo.file.decode", qos: .userInitiated)
    private var decoded: DecodedAudio?
    private var framePosition = 0
    private var playing = false
    private var mutedLocked = true
    private var suppressProgress = false
    private var loadGeneration = 0
    private var monitorEngine: AVAudioEngine?

    init() {
        muted = UserDefaults.standard.object(forKey: Self.mutedKey) as? Bool ?? true
        mutedLocked = muted
        restore()
    }

    var hasFile: Bool { fileName != nil }

    func load(url: URL) {
        loadError = nil
        isLoading = true
        fileName = url.deletingPathExtension().lastPathComponent
        filePath = url.path
        progress = 0
        duration = 0
        lock.lock()
        decoded = nil
        framePosition = 0
        playing = false
        lock.unlock()
        isPlaying = false
        stopMonitor()
        UserDefaults.standard.set(url.path, forKey: Self.defaultsKey)

        loadGeneration += 1
        let generation = loadGeneration
        decodeQueue.async { [weak self] in
            let result = Result { try DecodedAudio.load(url: url) }
            DispatchQueue.main.async {
                self?.finishLoad(generation: generation, result: result)
            }
        }
    }

    func play() {
        guard hasFile else { return }
        lock.lock()
        playing = true
        lock.unlock()
        isPlaying = true
        startMonitor()
    }

    func pause() {
        lock.lock()
        playing = false
        lock.unlock()
        isPlaying = false
        stopMonitor()
    }

    func toggleMute() {
        muted.toggle()
        UserDefaults.standard.set(muted, forKey: Self.mutedKey)
        lock.lock()
        mutedLocked = muted
        lock.unlock()
    }

    func seek(to progress: Double) {
        let clamped = min(max(progress, 0), 1)
        lock.lock()
        let total = decoded?.frameCount ?? 0
        if total <= 1 {
            framePosition = 0
        } else {
            framePosition = min(Int(clamped * Double(total)), total - 1)
        }
        lock.unlock()
        self.progress = clamped
    }

    func beginScrub() {
        suppressProgress = true
    }

    func endScrub() {
        suppressProgress = false
    }

    func clear() {
        loadGeneration += 1
        lock.lock()
        playing = false
        framePosition = 0
        decoded = nil
        lock.unlock()
        isPlaying = false
        isLoading = false
        progress = 0
        duration = 0
        fileName = nil
        filePath = nil
        loadError = nil
        stopMonitor()
        UserDefaults.standard.removeObject(forKey: Self.defaultsKey)
    }

    func publishProgress() {
        lock.lock()
        let pos = framePosition
        let total = decoded?.frameCount ?? 0
        let nowPlaying = playing
        lock.unlock()
        if isPlaying != nowPlaying {
            isPlaying = nowPlaying
            if !nowPlaying {
                stopMonitor()
            }
        }
        guard !suppressProgress else { return }
        progress = total > 0 ? Double(pos) / Double(total) : 0
    }

    func render(into scratch: UnsafeMutablePointer<Float>, frameCount: Int) -> Float {
        guard frameCount > 0 else { return 0 }
        lock.lock()
        defer { lock.unlock() }
        guard playing, let audio = decoded, audio.frameCount > 0 else { return 0 }
        if framePosition >= audio.frameCount {
            playing = false
            framePosition = 0
            return 0
        }

        let mixedFrames = min(frameCount, audio.frameCount - framePosition)
        var peak: Float = 0
        let base = framePosition * 2
        audio.samples.withUnsafeBufferPointer { src in
            for frame in 0..<mixedFrames {
                let left = src[base + frame * 2]
                let right = src[base + frame * 2 + 1]
                scratch[frame * 2] = left
                scratch[frame * 2 + 1] = right
                peak = max(peak, abs(left), abs(right))
            }
        }
        if mixedFrames < frameCount {
            let remaining = (frameCount - mixedFrames) * 2
            memset(scratch.advanced(by: mixedFrames * 2), 0, remaining * MemoryLayout<Float>.stride)
        }

        framePosition += mixedFrames
        if framePosition >= audio.frameCount {
            playing = false
            framePosition = 0
        }
        return min(peak, 1)
    }

    private func finishLoad(generation: Int, result: Result<DecodedAudio, Error>) {
        guard generation == loadGeneration else { return }
        isLoading = false
        switch result {
        case .success(let audio):
            lock.lock()
            decoded = audio
            framePosition = 0
            lock.unlock()
            duration = audio.duration
            progress = 0
            loadError = nil
            lock.lock()
            let shouldMonitor = playing
            lock.unlock()
            if shouldMonitor {
                startMonitor()
            }
        case .failure(let error):
            lock.lock()
            decoded = nil
            playing = false
            lock.unlock()
            isPlaying = false
            duration = 0
            progress = 0
            fileName = nil
            filePath = nil
            loadError = error.localizedDescription
            stopMonitor()
            UserDefaults.standard.removeObject(forKey: Self.defaultsKey)
        }
    }

    private func restore() {
        guard let path = UserDefaults.standard.string(forKey: Self.defaultsKey) else { return }
        guard FileManager.default.isReadableFile(atPath: path) else {
            UserDefaults.standard.removeObject(forKey: Self.defaultsKey)
            return
        }
        load(url: URL(fileURLWithPath: path))
    }

    private func startMonitor() {
        guard monitorEngine == nil else { return }
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Self.sampleRate,
            channels: 2,
            interleaved: false
        ) else { return }
        let engine = AVAudioEngine()
        let node = AVAudioSourceNode(format: format) { [weak self] _, _, frameCount, audioBufferList in
            self?.fillMonitor(audioBufferList, frames: Int(frameCount))
            return noErr
        }
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: format)
        do {
            try engine.start()
            monitorEngine = engine
        } catch {
            return
        }
    }

    private func stopMonitor() {
        guard let engine = monitorEngine else { return }
        engine.stop()
        monitorEngine = nil
    }

    private func fillMonitor(_ outputData: UnsafeMutablePointer<AudioBufferList>, frames: Int) {
        let output = UnsafeMutableAudioBufferListPointer(outputData)
        for buffer in output {
            if let dst = buffer.mData {
                memset(dst, 0, Int(buffer.mDataByteSize))
            }
        }
        lock.lock()
        let pos = framePosition
        let isPlaying = playing
        let isMuted = mutedLocked
        let audio = decoded
        lock.unlock()
        guard isPlaying, !isMuted, let audio, pos < audio.frameCount, frames > 0 else { return }
        let count = min(frames, audio.frameCount - pos)
        let base = pos * 2
        audio.samples.withUnsafeBufferPointer { src in
            if output.count == 1, let dst = output[0].mData {
                let channels = max(1, Int(output[0].mNumberChannels))
                let outSamples = dst.assumingMemoryBound(to: Float.self)
                for frame in 0..<count {
                    for channel in 0..<channels {
                        outSamples[frame * channels + channel] = src[base + frame * 2 + min(channel, 1)]
                    }
                }
            } else {
                for (channel, buffer) in output.enumerated() {
                    guard let dst = buffer.mData else { continue }
                    let outSamples = dst.assumingMemoryBound(to: Float.self)
                    let srcChannel = min(channel, 1)
                    let available = Int(buffer.mDataByteSize) / MemoryLayout<Float>.stride
                    let mixed = min(count, available)
                    for frame in 0..<mixed {
                        outSamples[frame] = src[base + frame * 2 + srcChannel]
                    }
                }
            }
        }
    }
}

private final class DecodedAudio {
    let samples: [Float]
    let frameCount: Int

    init(samples: [Float], frameCount: Int) {
        self.samples = samples
        self.frameCount = frameCount
    }

    var duration: TimeInterval {
        Double(frameCount) / FilePlayer.sampleRate
    }

    static func load(url: URL) throws -> DecodedAudio {
        let file = try AVAudioFile(forReading: url)
        let sourceFormat = file.processingFormat
        guard file.length > 0 else { throw FilePlayerError.empty }
        guard let destFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: FilePlayer.sampleRate,
            channels: 2,
            interleaved: true
        ) else {
            throw FilePlayerError.unsupported
        }

        let ratio = destFormat.sampleRate / sourceFormat.sampleRate
        var samples: [Float] = []
        samples.reserveCapacity((Int(ceil(Double(file.length) * ratio)) + 32) * 2)

        let sourceChunk: AVAudioFrameCount = 256_000
        guard let sourceBuffer = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: sourceChunk) else {
            throw FilePlayerError.unsupported
        }
        let destChunk = AVAudioFrameCount(ceil(Double(sourceChunk) * ratio) + 32)
        guard let destBuffer = AVAudioPCMBuffer(pcmFormat: destFormat, frameCapacity: max(destChunk, 1)) else {
            throw FilePlayerError.unsupported
        }

        let formatsMatch = sourceFormat.commonFormat == destFormat.commonFormat
            && sourceFormat.sampleRate == destFormat.sampleRate
            && sourceFormat.channelCount == destFormat.channelCount
            && sourceFormat.isInterleaved == destFormat.isInterleaved

        if formatsMatch {
            while file.framePosition < file.length {
                let remaining = AVAudioFrameCount(file.length - file.framePosition)
                try file.read(into: sourceBuffer, frameCount: min(sourceChunk, remaining))
                append(sourceBuffer, into: &samples)
            }
        } else {
            guard let converter = AVAudioConverter(from: sourceFormat, to: destFormat) else {
                throw FilePlayerError.unsupported
            }
            var reachedEnd = false
            while !reachedEnd {
                destBuffer.frameLength = destBuffer.frameCapacity
                var conversionError: NSError?
                let status = converter.convert(to: destBuffer, error: &conversionError) { inNumPackets, outStatus in
                    if file.framePosition >= file.length {
                        outStatus.pointee = .endOfStream
                        return nil
                    }
                    let remaining = AVAudioFrameCount(file.length - file.framePosition)
                    let frames = min(AVAudioFrameCount(inNumPackets), remaining, sourceChunk)
                    do {
                        try file.read(into: sourceBuffer, frameCount: frames)
                    } catch {
                        outStatus.pointee = .endOfStream
                        return nil
                    }
                    outStatus.pointee = .haveData
                    return sourceBuffer
                }
                if status == .error {
                    if let conversionError {
                        throw conversionError
                    }
                    throw FilePlayerError.unsupported
                }
                if destBuffer.frameLength > 0 {
                    append(destBuffer, into: &samples)
                }
                if status == .endOfStream {
                    reachedEnd = true
                }
            }
        }

        let frames = samples.count / 2
        guard frames > 0 else { throw FilePlayerError.empty }
        return DecodedAudio(samples: samples, frameCount: frames)
    }

    private static func append(_ buffer: AVAudioPCMBuffer, into samples: inout [Float]) {
        let frames = Int(buffer.frameLength)
        guard frames > 0, let data = buffer.audioBufferList.pointee.mBuffers.mData else { return }
        let pointer = data.assumingMemoryBound(to: Float.self)
        samples.append(contentsOf: UnsafeBufferPointer(start: pointer, count: frames * 2))
    }
}

private enum FilePlayerError: LocalizedError {
    case unsupported
    case empty

    var errorDescription: String? {
        switch self {
        case .unsupported:
            return "Could not read this audio file."
        case .empty:
            return "This audio file is empty."
        }
    }
}
