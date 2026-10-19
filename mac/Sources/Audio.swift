import AVFoundation
import AudioToolbox

/// Converts any PCM buffer to 16 kHz mono Int16 — the same capture format Wispr Flow uses.
final class PCMConverter {
    static let outFormat = AVAudioFormat(
        commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: true)!

    private let converter: AVAudioConverter

    init?(from format: AVAudioFormat) {
        guard let c = AVAudioConverter(from: format, to: Self.outFormat) else { return nil }
        c.downmix = true
        converter = c
    }

    /// Returns little-endian Int16 samples. `final` flushes the resampler at end of stream.
    func convert(_ buffer: AVAudioPCMBuffer, final: Bool = false) -> Data {
        let ratio = Self.outFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1024
        guard let out = AVAudioPCMBuffer(pcmFormat: Self.outFormat, frameCapacity: capacity) else { return Data() }
        var fed = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if fed {
                status.pointee = final ? .endOfStream : .noDataNow
                return nil
            }
            fed = true
            status.pointee = .haveData
            return buffer
        }
        guard error == nil, out.frameLength > 0, let ch = out.int16ChannelData else { return Data() }
        return Data(buffer: UnsafeBufferPointer(start: ch[0], count: Int(out.frameLength)))
    }

    static func wav(_ pcm: Data) -> Data {
        var d = Data()
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        d.append(contentsOf: Array("RIFF".utf8)); u32(UInt32(36 + pcm.count)); d.append(contentsOf: Array("WAVE".utf8))
        d.append(contentsOf: Array("fmt ".utf8)); u32(16); u16(1); u16(1); u32(16000); u32(32000); u16(2); u16(16)
        d.append(contentsOf: Array("data".utf8)); u32(UInt32(pcm.count))
        d.append(pcm)
        return d
    }

    /// Compressed upload: AAC in m4a is ~7x smaller than WAV, which cuts ~0.5 s off each request.
    /// Falls back to WAV if the encoder fails.
    static func encode(_ pcm: Data) -> (data: Data, format: String) {
        if let m4a = m4a(pcm) { return (m4a, "m4a") }
        return (wav(pcm), "wav")
    }

    private static func m4a(_ pcm: Data) -> Data? {
        let frames = pcm.count / 2
        guard frames > 0,
              let buf = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: AVAudioFrameCount(frames)) else { return nil }
        buf.frameLength = AVAudioFrameCount(frames)
        pcm.withUnsafeBytes { raw in
            buf.int16ChannelData![0].update(from: raw.bindMemory(to: Int16.self).baseAddress!, count: frames)
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("flowclone-\(UUID().uuidString).m4a")
        defer { try? FileManager.default.removeItem(at: url) }
        guard writeAAC(buf, to: url) else { return nil }
        return try? Data(contentsOf: url)
    }

    /// Separate function so the AVAudioFile is released (and the m4a finalized) before it is read.
    private static func writeAAC(_ buf: AVAudioPCMBuffer, to url: URL) -> Bool {
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 16000,
            AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 32000,
        ]
        do {
            let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatInt16, interleaved: true)
            try file.write(from: buf)
            if #available(macOS 15.0, *) { file.close() }
            return true
        } catch {
            NSLog("FlowClone AAC encode failed: \(error)")
            return false
        }
    }

    /// Used by the `--transcribe <file>` test mode: decode any audio file to 16 kHz mono PCM.
    static func pcmFromFile(_ url: URL) throws -> Data {
        let file = try AVAudioFile(forReading: url)
        guard let buf = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)),
              let conv = PCMConverter(from: file.processingFormat) else {
            throw NSError(domain: "FlowClone", code: 1, userInfo: [NSLocalizedDescriptionKey: "Unsupported audio file"])
        }
        try file.read(into: buf)
        return conv.convert(buf, final: true)
    }
}

/// Microphone capture via AVAudioEngine. A fresh engine is created for every start()
/// (robust to device changes between dictations) and released in stop().
final class Recorder {
    /// Smoothed input level 0...1, delivered on the main thread (drives the overlay meter).
    var onLevel: ((Float) -> Void)?
    /// Fired on the main thread when the audio route/device changes mid-recording
    /// (e.g. AirPods connect or disconnect).
    var onInterrupted: (() -> Void)?

    private var engine: AVAudioEngine?
    private var configObserver: NSObjectProtocol?
    private var pcm = Data()
    private var peak: Float = 0
    private let lock = NSLock()

    var isRecording: Bool { engine != nil }

    /// `deviceUID` "" selects the system default input. An unknown or unplugged UID silently falls back to the default.
    func start(deviceUID: String) throws {
        if engine != nil { _ = stop() }
        lock.lock(); pcm = Data(); peak = 0; lock.unlock()

        let eng = AVAudioEngine()
        let input = eng.inputNode
        // Select the device before reading the input format or installing the tap.
        if let device = AudioDevices.id(forUID: deviceUID), let unit = input.audioUnit {
            var dev = device
            let status = AudioUnitSetProperty(
                unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                &dev, UInt32(MemoryLayout<AudioDeviceID>.size))
            if status != noErr { NSLog("FlowClone: could not select input \(deviceUID) (\(status)), using default") }
        }

        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, let conv = PCMConverter(from: format) else {
            throw NSError(domain: "FlowClone", code: 2, userInfo: [NSLocalizedDescriptionKey: "No microphone input"])
        }
        input.installTap(onBus: 0, bufferSize: 2048, format: format) { [weak self] buffer, _ in
            self?.process(buffer, with: conv)
        }
        eng.prepare()
        do {
            try eng.start()
        } catch {
            input.removeTap(onBus: 0)
            throw error
        }
        engine = eng
        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: eng, queue: .main
        ) { [weak self] _ in
            self?.handleConfigurationChange()
        }
    }

    /// AVAudioEngine posts a configuration change right after starting (it builds its default-device
    /// aggregate), and again when the route changes (AirPods connect/disconnect). Either way the engine
    /// has stopped: reinstall the tap for the current input format and restart, keeping what was
    /// recorded so far. Only if that fails does the recording end.
    private func handleConfigurationChange() {
        guard let eng = engine else { return }
        Log.d("audio configuration changed; restarting input")
        let input = eng.inputNode
        input.removeTap(onBus: 0)
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, let conv = PCMConverter(from: format) else {
            onInterrupted?()
            return
        }
        input.installTap(onBus: 0, bufferSize: 2048, format: format) { [weak self] buffer, _ in
            self?.process(buffer, with: conv)
        }
        do {
            if !eng.isRunning {
                eng.prepare()
                try eng.start()
            }
        } catch {
            Log.d("restart after configuration change failed: \(error)")
            onInterrupted?()
        }
    }

    private func process(_ buffer: AVAudioPCMBuffer, with converter: PCMConverter) {
        let chunk = converter.convert(buffer)
        guard !chunk.isEmpty else { return }
        var sum: Float = 0
        chunk.withUnsafeBytes { raw in
            for s in raw.bindMemory(to: Int16.self) { let f = Float(s) / 32768; sum += f * f }
        }
        let rms = sqrt(sum / Float(chunk.count / 2))
        lock.lock(); pcm.append(chunk); peak = max(peak, rms); lock.unlock()
        let level = min(1, sqrt(rms) * 2.2)
        DispatchQueue.main.async { [weak self] in self?.onLevel?(level) }
    }

    /// Stops capture and returns raw 16 kHz mono Int16 PCM. `peak` is the loudest chunk's RMS,
    /// used to skip silent recordings. Returns empty when not recording.
    func stop() -> (pcm: Data, seconds: Double, peak: Float) {
        guard let eng = engine else { return (Data(), 0, 0) }
        if let observer = configObserver {
            NotificationCenter.default.removeObserver(observer)
            configObserver = nil
        }
        eng.inputNode.removeTap(onBus: 0)
        eng.stop()
        engine = nil
        lock.lock(); let data = pcm; let p = peak; lock.unlock()
        return (data, Double(data.count) / 32000, p)
    }
}
