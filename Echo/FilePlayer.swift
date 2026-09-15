import AVFoundation
import Foundation
import Observation

@Observable
final class FilePlayer {
    static let levelKey = "echo.file"
    static let sampleRate: Double = 48_000

    private(set) var fileName: String?
    private(set) var filePath: String?
    private(set) var isPlaying = false
    private(set) var progress: Double = 0
    private(set) var duration: TimeInterval = 0
    private(set) var muted = true
    private(set) var loadError: String?

    private static let defaultsKey = "echo.playerFile"
    private static let mutedKey = "echo.playerMuted"

    private let lock = NSLock()
    private var decoded: DecodedAudio?
    private var framePosition = 0
    private var playing = false
    private var suppressProgress = false
    private var monitor: AVAudioPlayer?

    init() {
        muted = UserDefaults.standard.object(forKey: Self.mutedKey) as? Bool ?? true
        restore()
    }

    var hasFile: Bool { fileName != nil }

    func load(url: URL) {
        loadError = nil
        do {
            let audio = try DecodedAudio.load(url: url)
            lock.lock()
            decoded = audio
            framePosition = 0
            playing = false
            lock.unlock()
            isPlaying = false
            progress = 0
            duration = audio.duration
            fileName = url.deletingPathExtension().lastPathComponent
            filePath = url.path
            UserDefaults.standard.set(url.path, forKey: Self.defaultsKey)
            attachMonitor(url: url)
        } catch {
            loadError = error.localizedDescription
        }
    }

    func play() {
        lock.lock()
        guard decoded != nil else {
            lock.unlock()
            return
        }
        playing = true
        lock.unlock()
        isPlaying = true
        syncMonitor()
    }

    func pause() {
        lock.lock()
        playing = false
        lock.unlock()
        isPlaying = false
        syncMonitor()
    }

    func toggleMute() {
        muted.toggle()
        UserDefaults.standard.set(muted, forKey: Self.mutedKey)
        syncMonitor()
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
        syncMonitor(seek: true)
    }

    func beginScrub() {
        suppressProgress = true
    }

    func endScrub() {
        suppressProgress = false
    }

    func clear() {
        lock.lock()
        playing = false
        framePosition = 0
        decoded = nil
        lock.unlock()
        isPlaying = false
        progress = 0
        duration = 0
        fileName = nil
        filePath = nil
        loadError = nil
        monitor?.stop()
        monitor = nil
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
            syncMonitor()
        }
        guard !suppressProgress else { return }
        progress = total > 0 ? Double(pos) / Double(total) : 0
    }

    func render(into outputData: UnsafeMutablePointer<AudioBufferList>) -> Float {
        let output = UnsafeMutableAudioBufferListPointer(outputData)
        guard !output.isEmpty else { return 0 }

        lock.lock()
        defer { lock.unlock() }
        guard playing, let audio = decoded, audio.frameCount > 0 else { return 0 }
        if framePosition >= audio.frameCount {
            playing = false
            framePosition = 0
            return 0
        }

        let remaining = audio.frameCount - framePosition
        var peak: Float = 0
        let mixedFrames: Int

        if output.count == 1, let outData = output[0].mData {
            let channels = max(1, Int(output[0].mNumberChannels == 0 ? 2 : output[0].mNumberChannels))
            let outFrames = Int(output[0].mDataByteSize) / (MemoryLayout<Float>.stride * channels)
            mixedFrames = min(outFrames, remaining)
            let outSamples = outData.assumingMemoryBound(to: Float.self)
            let base = framePosition * 2
            audio.samples.withUnsafeBufferPointer { src in
                for frame in 0..<mixedFrames {
                    for channel in 0..<channels {
                        let sample = src[base + frame * 2 + min(channel, 1)]
                        outSamples[frame * channels + channel] += sample
                        peak = max(peak, abs(sample))
                    }
                }
            }
        } else {
            let outFrames = output[0].mData == nil
                ? 0
                : Int(output[0].mDataByteSize) / MemoryLayout<Float>.stride
            mixedFrames = min(outFrames, remaining)
            let base = framePosition * 2
            audio.samples.withUnsafeBufferPointer { src in
                for channel in 0..<output.count {
                    guard let dst = output[channel].mData else { continue }
                    let count = min(mixedFrames, Int(output[channel].mDataByteSize) / MemoryLayout<Float>.stride)
                    let outSamples = dst.assumingMemoryBound(to: Float.self)
                    let srcChannel = min(channel, 1)
                    for frame in 0..<count {
                        let sample = src[base + frame * 2 + srcChannel]
                        outSamples[frame] += sample
                        peak = max(peak, abs(sample))
                    }
                }
            }
        }

        framePosition += mixedFrames
        if framePosition >= audio.frameCount {
            playing = false
            framePosition = 0
        }
        return min(peak, 1)
    }

    private func restore() {
        guard let path = UserDefaults.standard.string(forKey: Self.defaultsKey) else { return }
        guard FileManager.default.isReadableFile(atPath: path) else {
            UserDefaults.standard.removeObject(forKey: Self.defaultsKey)
            return
        }
        load(url: URL(fileURLWithPath: path))
        if loadError != nil {
            UserDefaults.standard.removeObject(forKey: Self.defaultsKey)
            loadError = nil
            fileName = nil
            filePath = nil
        }
    }

    private func attachMonitor(url: URL) {
        monitor?.stop()
        monitor = try? AVAudioPlayer(contentsOf: url)
        monitor?.prepareToPlay()
        syncMonitor(seek: true)
    }

    private func syncMonitor(seek: Bool = false) {
        guard let monitor else { return }
        if seek {
            let duration = monitor.duration
            monitor.currentTime = duration > 0 ? progress * duration : 0
        }
        if playing && !muted {
            if !monitor.isPlaying {
                monitor.play()
            }
        } else if monitor.isPlaying {
            monitor.pause()
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
        let sourceFrames = AVAudioFrameCount(file.length)
        guard sourceFrames > 0 else { throw FilePlayerError.empty }
        guard let destFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: FilePlayer.sampleRate,
            channels: 2,
            interleaved: true
        ) else {
            throw FilePlayerError.unsupported
        }

        guard let sourceBuffer = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: sourceFrames) else {
            throw FilePlayerError.unsupported
        }
        try file.read(into: sourceBuffer)

        let destFrames = AVAudioFrameCount(
            ceil(Double(sourceBuffer.frameLength) * destFormat.sampleRate / sourceFormat.sampleRate) + 32
        )
        guard let destBuffer = AVAudioPCMBuffer(pcmFormat: destFormat, frameCapacity: max(destFrames, 1)) else {
            throw FilePlayerError.unsupported
        }

        if sourceFormat.commonFormat == destFormat.commonFormat,
           sourceFormat.sampleRate == destFormat.sampleRate,
           sourceFormat.channelCount == destFormat.channelCount,
           sourceFormat.isInterleaved == destFormat.isInterleaved {
            destBuffer.frameLength = sourceBuffer.frameLength
            let bytes = Int(sourceBuffer.frameLength) * Int(destFormat.channelCount) * MemoryLayout<Float>.stride
            if let src = sourceBuffer.audioBufferList.pointee.mBuffers.mData,
               let dst = destBuffer.mutableAudioBufferList.pointee.mBuffers.mData {
                memcpy(dst, src, bytes)
            }
        } else {
            guard let converter = AVAudioConverter(from: sourceFormat, to: destFormat) else {
                throw FilePlayerError.unsupported
            }
            var conversionError: NSError?
            var provided = false
            let status = converter.convert(to: destBuffer, error: &conversionError) { _, outStatus in
                if provided {
                    outStatus.pointee = .endOfStream
                    return nil
                }
                provided = true
                outStatus.pointee = .haveData
                return sourceBuffer
            }
            if status == .error {
                if let conversionError {
                    throw conversionError
                }
                throw FilePlayerError.unsupported
            }
        }

        let frames = Int(destBuffer.frameLength)
        guard frames > 0 else { throw FilePlayerError.empty }
        guard let data = destBuffer.audioBufferList.pointee.mBuffers.mData else {
            throw FilePlayerError.unsupported
        }
        let pointer = data.assumingMemoryBound(to: Float.self)
        let samples = Array(UnsafeBufferPointer(start: pointer, count: frames * 2))
        return DecodedAudio(samples: samples, frameCount: frames)
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
