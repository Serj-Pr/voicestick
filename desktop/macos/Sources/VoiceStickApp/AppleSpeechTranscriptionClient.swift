import AVFoundation
import COpus
import Foundation
import Speech

final class AppleSpeechTranscriptionClient: NSObject, ASRClient, SFSpeechRecognizerDelegate {
    private enum SessionState {
        case idle
        case buffering
        case authorizing
        case transcribing
        case finished
    }

    private let config: AppConfig
    private let queue = DispatchQueue(label: "VoiceStick.AppleSpeechTranscriptionClient")
    private var sessionState: SessionState = .idle
    private var bufferedOggData = Data()
    private var sessionOptions = ASRSessionOptions()
    private var didReceiveFinish = false
    private var authorizationRequested = false
    private var recognitionTask: SFSpeechRecognitionTask?
    private var currentRequestURL: URL?
    private var recognitionDidFinish = false
    private var recognitionFallbackTimer: DispatchSourceTimer?
    private var bestRecognizedText = ""

    var onPartial: ((String) -> Void)?
    var onSegment: ((ASRSegment) -> Void)?
    var onFinal: ((String) -> Void)?
    var onError: ((String) -> Void)?
    var onUpgradeURL: ((URL, String) -> Void)?

    init(config: AppConfig) {
        self.config = config
    }

    deinit {
        recognitionTask?.cancel()
    }

    @discardableResult
    func start(options: ASRSessionOptions) -> Bool {
        var didStart = false
        queue.sync {
            guard sessionState == .idle else { return }
            sessionOptions = options
            didReceiveFinish = false
            bufferedOggData.removeAll(keepingCapacity: true)
            currentRequestURL = nil
            recognitionDidFinish = false
            bestRecognizedText = ""
            sessionState = .buffering
            didStart = true
        }
        guard didStart else { return false }

        let status = SFSpeechRecognizer.authorizationStatus()
        if status == .denied || status == .restricted {
            notifyError("Apple Speech permission is not allowed")
            return false
        }

        if status == .notDetermined {
            requestAuthorizationIfNeeded()
        }

        return true
    }

    func sendOggOpusChunk(_ data: Data, isLast: Bool) {
        queue.async { [weak self] in
            guard let self, self.sessionState != .idle else { return }
            if !data.isEmpty {
                self.bufferedOggData.append(data)
            }
            if isLast {
                self.didReceiveFinish = true
                self.transcribeIfPossible()
            }
        }
    }

    func finish() {
        queue.async { [weak self] in
            guard let self else { return }
            self.didReceiveFinish = true
            self.transcribeIfPossible()
        }
    }

    func cancel() {
        queue.async { [weak self] in
            guard let self else { return }
            self.recognitionTask?.cancel()
            self.recognitionTask = nil
            self.recognitionFallbackTimer?.cancel()
            self.recognitionFallbackTimer = nil
            self.bufferedOggData.removeAll(keepingCapacity: true)
            self.currentRequestURL = nil
            self.recognitionDidFinish = false
            self.bestRecognizedText = ""
            self.didReceiveFinish = false
            self.authorizationRequested = false
            self.sessionState = .idle
        }
    }

    private func requestAuthorizationIfNeeded() {
        guard !authorizationRequested else { return }
        authorizationRequested = true
        sessionState = .authorizing
        SFSpeechRecognizer.requestAuthorization { [weak self] status in
            guard let self else { return }
            self.queue.async {
                self.authorizationRequested = false
                switch status {
                case .authorized:
                    self.sessionState = .buffering
                    self.transcribeIfPossible()
                case .denied, .restricted:
                    self.sessionState = .idle
                    self.failSession("Apple Speech permission is not allowed")
                case .notDetermined:
                    self.sessionState = .buffering
                @unknown default:
                    self.sessionState = .idle
                    self.failSession("Apple Speech permission is unavailable")
                }
            }
        }
    }

    private func transcribeIfPossible() {
        guard didReceiveFinish else { return }
        guard sessionState == .buffering || sessionState == .authorizing else { return }
        guard SFSpeechRecognizer.authorizationStatus() == .authorized else {
            if SFSpeechRecognizer.authorizationStatus() == .notDetermined {
                requestAuthorizationIfNeeded()
            } else {
                failSession("Apple Speech permission is not allowed")
            }
            return
        }

        sessionState = .transcribing
        let audioData = bufferedOggData
        bufferedOggData.removeAll(keepingCapacity: true)
        AppLog.debug("Apple Speech received ogg_bytes=\(audioData.count)")

        queue.async { [weak self] in
            guard let self else { return }
            do {
                let audioURL = try self.writePCMFile(from: audioData)
                self.currentRequestURL = audioURL
                self.performSpeechRecognition(audioURL: audioURL)
            } catch {
                self.saveFailedAudioForDiagnostics(audioData)
                self.failSession(Self.userFacingConversionError(from: error))
            }
        }
    }

    private func performSpeechRecognition(audioURL: URL) {
        guard let recognizer = makeRecognizer() else {
            failSession("Apple Speech recognizer is unavailable for this locale")
            return
        }
        recognizer.delegate = self

        let request = SFSpeechURLRecognitionRequest(url: audioURL)
        request.shouldReportPartialResults = sessionOptions.resultType == .single || sessionOptions.showUtterances
        let contextualStrings = sessionOptions.hotwords
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        if !contextualStrings.isEmpty {
            request.contextualStrings = contextualStrings
        }
        if recognizer.supportsOnDeviceRecognition {
            request.requiresOnDeviceRecognition = true
        }
        AppLog.debug("Apple Speech start locale=\(recognizer.locale.identifier) on_device=\(request.requiresOnDeviceRecognition)")

        recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            guard let self else { return }
            if let error {
                self.queue.async {
                    guard !self.recognitionDidFinish else { return }
                    self.failSession(Self.userFacingRecognitionError(from: error))
                }
                return
            }

            guard let result else { return }
            let text = result.bestTranscription.formattedString.trimmingCharacters(in: .whitespacesAndNewlines)
            self.queue.async {
                guard !self.recognitionDidFinish else { return }
                if !text.isEmpty {
                    self.bestRecognizedText = text
                }
                AppLog.debug("Apple Speech result final=\(result.isFinal) text_len=\(text.count)")
                if !result.isFinal, request.shouldReportPartialResults, !text.isEmpty {
                    DispatchQueue.main.async {
                        self.onPartial?(text)
                    }
                }
                if result.isFinal {
                    self.finishRecognition(text: text)
                }
            }
        }
        scheduleRecognitionFallback()
    }

    private func makeRecognizer() -> SFSpeechRecognizer? {
        let localeIdentifier = config.appleSpeechLocale.replacingOccurrences(of: "_", with: "-")
        if let recognizer = SFSpeechRecognizer(locale: Locale(identifier: localeIdentifier)) {
            return recognizer
        }
        return SFSpeechRecognizer()
    }

    private static func userFacingConversionError(from error: Error) -> String {
        return "Apple Speech audio conversion failed: \(error.localizedDescription)"
    }

    private static func userFacingRecognitionError(from error: Error) -> String {
        let nsError = error as NSError
        if nsError.domain == "kAFAssistantErrorDomain" && nsError.code == 1101 {
            return """
            Apple Speech is disabled in macOS because Siri and Dictation are turned off. Enable Dictation in System Settings, then try Apple Speech again.
            """
        }

        let lowercasedDescription = error.localizedDescription.lowercased()
        if lowercasedDescription.contains("siri") && lowercasedDescription.contains("dictation") {
            return """
            Apple Speech is disabled in macOS because Siri and Dictation are turned off. Enable Dictation in System Settings, then try Apple Speech again.
            """
        }

        return error.localizedDescription
    }

    private func saveFailedAudioForDiagnostics(_ audioData: Data) {
        guard !audioData.isEmpty else { return }

        do {
            let directory = config.debugAudioDirectory
                .appendingPathComponent("apple-speech-failures", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let fileURL = directory.appendingPathComponent("VoiceStick-AppleSpeech-\(UUID().uuidString).ogg")
            try audioData.write(to: fileURL, options: .atomic)
            AppLog.error("Apple Speech failed audio saved: \(fileURL.path)")
        } catch {
            AppLog.error("Apple Speech failed audio save failed: \(error.localizedDescription)")
        }
    }

    private func writePCMFile(from oggData: Data) throws -> URL {
        let packets = extractOpusPackets(from: oggData)
        AppLog.debug("Apple Speech extracted opus_packets=\(packets.count)")
        guard !packets.isEmpty else {
            throw NSError(domain: "AppleSpeechTranscriptionClient", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "No speech audio was captured"
            ])
        }

        let pcmData = try decodeOpusPacketsToPCM(packets)
        AppLog.debug("Apple Speech decoded pcm_bytes=\(pcmData.count)")
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("VoiceStick-\(UUID().uuidString).wav")
        try makeWAVData(pcmData: pcmData, sampleRate: 16_000, channels: 1).write(to: outputURL, options: .atomic)
        return outputURL
    }

    private func decodeOpusPacketsToPCM(_ packets: [Data]) throws -> Data {
        var decoderError: Int32 = 0
        guard let decoder = opus_decoder_create(16_000, 1, &decoderError) else {
            throw NSError(domain: "AppleSpeechTranscriptionClient", code: Int(decoderError), userInfo: [
                NSLocalizedDescriptionKey: "Opus decoder create failed: \(decoderError)"
            ])
        }
        defer { opus_decoder_destroy(decoder) }

        var pcmData = Data()
        var decodedSamples = [opus_int16](repeating: 0, count: 16_000 / 1000 * 120)
        for packet in packets {
            let frameCount = packet.withUnsafeBytes { rawBuffer -> Int32 in
                guard let baseAddress = rawBuffer.bindMemory(to: UInt8.self).baseAddress else {
                    return OPUS_INVALID_PACKET
                }
                return opus_decode(
                    decoder,
                    baseAddress,
                    Int32(packet.count),
                    &decodedSamples,
                    Int32(decodedSamples.count),
                    0
                )
            }
            guard frameCount > 0 else {
                throw NSError(domain: "AppleSpeechTranscriptionClient", code: Int(frameCount), userInfo: [
                    NSLocalizedDescriptionKey: "Opus decode failed: \(frameCount)"
                ])
            }

            let byteCount = Int(frameCount) * MemoryLayout<opus_int16>.size
            decodedSamples.withUnsafeBytes { sampleBytes in
                pcmData.append(contentsOf: sampleBytes.bindMemory(to: UInt8.self).prefix(byteCount))
            }
        }

        return pcmData
    }

    private func makeWAVData(pcmData: Data, sampleRate: UInt32, channels: UInt16) -> Data {
        let bitsPerSample: UInt16 = 16
        let bytesPerSample = UInt16(bitsPerSample / 8)
        let blockAlign = channels * bytesPerSample
        let byteRate = sampleRate * UInt32(blockAlign)
        let dataSize = UInt32(pcmData.count)
        let riffSize = UInt32(36) + dataSize

        var out = Data()
        out.append(Data("RIFF".utf8))
        out.append(contentsOf: riffSize.littleEndianBytes)
        out.append(Data("WAVE".utf8))
        out.append(Data("fmt ".utf8))
        out.append(contentsOf: UInt32(16).littleEndianBytes)
        out.append(contentsOf: UInt16(1).littleEndianBytes)
        out.append(contentsOf: channels.littleEndianBytes)
        out.append(contentsOf: sampleRate.littleEndianBytes)
        out.append(contentsOf: byteRate.littleEndianBytes)
        out.append(contentsOf: blockAlign.littleEndianBytes)
        out.append(contentsOf: bitsPerSample.littleEndianBytes)
        out.append(Data("data".utf8))
        out.append(contentsOf: dataSize.littleEndianBytes)
        out.append(pcmData)
        return out
    }

    private func extractOpusPackets(from data: Data) -> [Data] {
        var packets: [Data] = []
        var pendingPacket = Data()
        var offset = 0

        while offset + 27 <= data.count {
            guard data[offset] == 0x4F,
                  data[offset + 1] == 0x67,
                  data[offset + 2] == 0x67,
                  data[offset + 3] == 0x53 else { break }
            let pageSegments = Int(data[offset + 26])
            let headerLength = 27 + pageSegments
            guard offset + headerLength <= data.count else { break }

            var bodyLength = 0
            for index in 0..<pageSegments {
                bodyLength += Int(data[offset + 27 + index])
            }

            let bodyStart = offset + headerLength
            let bodyEnd = bodyStart + bodyLength
            guard bodyEnd <= data.count else { break }
            guard bodyLength > 0 else {
                offset = bodyEnd
                continue
            }

            var cursor = bodyStart
            for index in 0..<pageSegments {
                let segmentSize = Int(data[offset + 27 + index])
                guard cursor + segmentSize <= bodyEnd else { break }
                pendingPacket.append(data.subdata(in: cursor..<(cursor + segmentSize)))
                cursor += segmentSize

                if segmentSize < 255 {
                    if !pendingPacket.starts(with: Data("OpusHead".utf8)) &&
                        !pendingPacket.starts(with: Data("OpusTags".utf8)) &&
                        !pendingPacket.isEmpty {
                        packets.append(pendingPacket)
                    }
                    pendingPacket.removeAll(keepingCapacity: true)
                }
            }

            offset = bodyEnd
        }

        return packets
    }

    private func scheduleRecognitionFallback() {
        recognitionFallbackTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 12)
        timer.setEventHandler { [weak self] in
            guard let self, self.sessionState == .transcribing, !self.recognitionDidFinish else { return }
            if !self.bestRecognizedText.isEmpty {
                AppLog.debug("Apple Speech fallback final text_len=\(self.bestRecognizedText.count)")
                self.finishRecognition(text: self.bestRecognizedText)
            } else {
                self.failSession("Apple Speech did not recognize any text. Check the dictation language and try speaking again.")
            }
        }
        recognitionFallbackTimer = timer
        timer.resume()
    }

    private func finishRecognition(text: String) {
        guard !recognitionDidFinish else { return }
        recognitionDidFinish = true
        recognitionFallbackTimer?.cancel()
        recognitionFallbackTimer = nil
        sessionState = .finished
        AppLog.debug("Apple Speech final text_len=\(text.count)")
        DispatchQueue.main.async { [weak self] in
            self?.onFinal?(text)
        }
        cleanupTemporaryAudio()
    }

    private func failSession(_ message: String) {
        recognitionTask?.cancel()
        recognitionFallbackTimer?.cancel()
        recognitionFallbackTimer = nil
        cleanupTemporaryAudio()
        sessionState = .idle
        bufferedOggData.removeAll(keepingCapacity: true)
        recognitionDidFinish = false
        bestRecognizedText = ""
        didReceiveFinish = false
        authorizationRequested = false
        DispatchQueue.main.async { [weak self] in
            self?.onError?(message)
        }
    }

    private func notifyError(_ message: String) {
        DispatchQueue.main.async { [weak self] in
            self?.onError?(message)
        }
    }

    private func cleanupTemporaryAudio() {
        if let currentRequestURL {
            try? FileManager.default.removeItem(at: currentRequestURL)
            self.currentRequestURL = nil
        }
        recognitionTask = nil
    }

    func speechRecognizer(_ speechRecognizer: SFSpeechRecognizer, availabilityDidChange available: Bool) {
        if !available {
            queue.async { [weak self] in
                self?.failSession("Apple Speech recognition is temporarily unavailable")
            }
        }
    }
}

private extension FixedWidthInteger {
    var littleEndianBytes: [UInt8] {
        withUnsafeBytes(of: self.littleEndian) { Array($0) }
    }
}
