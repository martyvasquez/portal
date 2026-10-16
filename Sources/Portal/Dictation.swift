import AppKit
import AVFoundation
import Carbon.HIToolbox
import Speech
import SwiftUI

/// Dictation: talk, watch the words appear, then ↩ inserts them into the app you were in.
/// Speech is recognized on this Mac with SpeechAnalyzer; the dictionary nudges it toward your
/// words and fixes what it still gets wrong.
@MainActor
final class DictationModel: ObservableObject {
    enum Phase: Equatable { case idle, starting, downloading, listening, paused, finishing, failed(DictationError) }
    enum Delivery { case insert, copy }

    @Published private(set) var phase: Phase = .idle
    /// Text the recognizer has settled on.
    @Published private(set) var committed = ""
    /// Its current guess at what you're saying now, replaced as it hears more.
    @Published private(set) var volatile = ""
    @Published private(set) var levels = [Float](repeating: 0, count: DictationModel.barCount)

    var onDismiss: () -> Void = {}

    static let barCount = 32
    private let settings: SettingsStore
    /// Bumped by every start and cancel, so work from an earlier session can't touch this one.
    private var session = 0
    private var mic: MicCapture?
    private var analyzer: SpeechAnalyzer?
    private var input: AsyncStream<AnalyzerInput>.Continuation?
    private var results: Task<Void, Never>?

    init(settings: SettingsStore) { self.settings = settings }

    var isActive: Bool { phase != .idle }
    var text: String { Self.tidy(committed + volatile) }

    func start() {
        teardown()
        session += 1
        committed = ""
        volatile = ""
        levels = [Float](repeating: 0, count: Self.barCount)
        phase = .starting
        let id = session
        Task { await begin(id) }
    }

    private func begin(_ id: Int) async {
        do {
            guard await Self.microphoneAllowed() else { throw DictationError.microphoneDenied }
            let wanted = settings.values.dictationLocale.map(Locale.init(identifier:)) ?? .current
            guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: wanted) else {
                throw DictationError.unsupportedLanguage(wanted.localizedString(forIdentifier: wanted.identifier) ?? wanted.identifier)
            }
            let transcriber = SpeechTranscriber(locale: locale, transcriptionOptions: [],
                                                reportingOptions: [.volatileResults], attributeOptions: [])
            // The first time a language is used, macOS downloads its speech model.
            if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
                if id == session { phase = .downloading }
                try await request.downloadAndInstall()
            }
            guard id == session else { return }

            let analyzer = SpeechAnalyzer(modules: [transcriber])
            let hints = DictionaryCorrector.hints(from: settings.values.dictionary)
            if !hints.isEmpty {
                let context = AnalysisContext()
                context.contextualStrings[.general] = hints
                try? await analyzer.setContext(context)   // before any audio, or it has no effect
            }
            guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
                throw DictationError.noAudioFormat
            }
            guard id == session else { return }

            let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
            self.analyzer = analyzer
            input = continuation
            results = Task { [weak self] in
                do {
                    for try await result in transcriber.results { self?.absorb(result, session: id) }
                } catch {}
            }
            try await analyzer.start(inputSequence: stream)
            guard id == session else { return }

            let mic = MicCapture()
            mic.onBuffer = { continuation.yield(AnalyzerInput(buffer: $0)) }
            mic.onLevel = { [weak self] level in
                Task { @MainActor in self?.push(level, session: id) }
            }
            try mic.start(format: format)
            self.mic = mic
            phase = .listening
        } catch {
            guard id == session else { return }
            NSLog("Portal: dictation failed: \(error)")
            teardown()
            phase = .failed(error as? DictationError ?? .other(error.localizedDescription))
        }
    }

    private func absorb(_ result: SpeechTranscriber.Result, session id: Int) {
        guard id == session else { return }
        let text = String(result.text.characters)
        if result.isFinal {
            committed += text
            volatile = ""
        } else {
            volatile = text
        }
    }

    private func push(_ level: Float, session id: Int) {
        guard id == session, phase == .listening || phase == .paused else { return }
        levels.removeFirst()
        levels.append(phase == .paused ? 0 : level)
    }

    func pause() {
        guard phase == .listening else { return }
        mic?.paused = true
        phase = .paused
    }

    func resume() {
        guard phase == .paused else { return }
        mic?.paused = false
        phase = .listening
    }

    /// Waits for the recognizer to settle the last words, then inserts or copies the text.
    func finish(_ delivery: Delivery) {
        guard phase == .listening || phase == .paused else {
            if phase != .finishing { cancel() }
            return
        }
        let id = session
        phase = .finishing
        mic?.stop()
        mic = nil
        input?.finish()
        input = nil
        Task {
            try? await analyzer?.finalizeAndFinishThroughEndOfInput()
            await results?.value
            guard id == session else { return }
            analyzer = nil
            results = nil
            let text = DictionaryCorrector(settings.values.dictionary).apply(to: self.text)
            phase = .idle
            onDismiss()
            guard !text.isEmpty else { return }
            // Always left on the clipboard (and so in history), even after inserting, so a
            // long dictation is never lost to an app that had no text field.
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.setString(text, forType: .string)
            pb.setData(Data(), forType: .dictation)
            guard delivery == .insert else { return }
            guard Permissions.accessibilityGranted else { Permissions.requestAccessibility(); return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { Paster.sendPaste() }
        }
    }

    /// Throws the dictation away.
    func cancel() {
        session += 1
        teardown()
        phase = .idle
        onDismiss()
    }

    /// The panel closed some other way (its hotkey, the launcher opening).
    func didHide() {
        if phase != .idle && phase != .finishing { cancel() }
    }

    private func teardown() {
        mic?.stop()
        mic = nil
        input?.finish()
        input = nil
        results?.cancel()
        results = nil
        if let analyzer { Task { await analyzer.cancelAndFinishNow() } }
        analyzer = nil
    }

    func handleKey(_ e: NSEvent) -> Bool {
        let flags = e.modifierFlags.intersection([.command, .option, .control, .shift])
        switch Int(e.keyCode) {
        case kVK_Escape:
            cancel()
        case kVK_Return, kVK_ANSI_KeypadEnter:
            if !e.isARepeat { finish(flags.contains(.command) ? .copy : .insert) }
        case kVK_Space:
            if !e.isARepeat { pause() }
        default:
            return false
        }
        return true
    }

    func handleKeyUp(_ e: NSEvent) -> Bool {
        guard Int(e.keyCode) == kVK_Space else { return false }
        resume()
        return true
    }

    /// Joins the recognizer's pieces: one space between words, none before punctuation.
    nonisolated static func tidy(_ s: String) -> String {
        s.replacingOccurrences(of: "[ \\t]+", with: " ", options: .regularExpression)
            .replacingOccurrences(of: " ([.,!?;:])", with: "$1", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func microphoneAllowed() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: true
        case .notDetermined: await AVCaptureDevice.requestAccess(for: .audio)
        default: false
        }
    }

    static func openMicrophoneSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
            NSWorkspace.shared.open(url)
        }
    }
}

enum DictationError: Error, Equatable {
    case microphoneDenied, noMicrophone, noAudioFormat
    case unsupportedLanguage(String)
    case other(String)

    var message: String {
        switch self {
        case .microphoneDenied: "Portal isn't allowed to use the microphone."
        case .noMicrophone: "No microphone is connected."
        case .noAudioFormat: "The speech recognizer couldn't use this microphone."
        case .unsupportedLanguage(let name): "Dictation doesn't support \(name) yet. Pick another language in Settings."
        case .other(let text): text
        }
    }
}

// MARK: - Microphone

/// Captures the microphone in the format the recognizer wants. The tap runs on a real-time
/// audio thread; only `paused` is shared with the main thread, behind a lock.
final class MicCapture: @unchecked Sendable {
    var onBuffer: (AVAudioPCMBuffer) -> Void = { _ in }
    var onLevel: (Float) -> Void = { _ in }

    private let engine = AVAudioEngine()
    private var converter: AVAudioConverter?
    private var format: AVAudioFormat?
    private let lock = NSLock()
    private var _paused = false

    /// While paused the microphone stays on, so resuming is instant, but no audio reaches the recognizer.
    var paused: Bool {
        get { lock.withLock { _paused } }
        set { lock.withLock { _paused = newValue } }
    }

    func start(format: AVAudioFormat) throws {
        let node = engine.inputNode
        let native = node.outputFormat(forBus: 0)
        guard native.sampleRate > 0, native.channelCount > 0 else { throw DictationError.noMicrophone }
        self.format = format
        converter = native == format ? nil : AVAudioConverter(from: native, to: format)
        node.installTap(onBus: 0, bufferSize: 2048, format: native) { [weak self] buffer, _ in self?.handle(buffer) }
        engine.prepare()
        try engine.start()
    }

    func stop() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
    }

    private func handle(_ buffer: AVAudioPCMBuffer) {
        if paused { onLevel(0); return }
        onLevel(Self.level(of: buffer))
        guard let format else { return }
        // AVAudioEngine reuses the tap's buffer once this returns, so the recognizer gets its own.
        guard let converter else {
            if let copy = Self.copy(buffer) { onBuffer(copy) }
            return
        }
        let ratio = format.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 64
        guard let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return }
        var fed = false
        var error: NSError?
        let status = converter.convert(to: out, error: &error) { _, inputStatus in
            if fed { inputStatus.pointee = .noDataNow; return nil }
            fed = true
            inputStatus.pointee = .haveData
            return buffer
        }
        if status != .error, error == nil, out.frameLength > 0 { onBuffer(out) }
    }

    private static func copy(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard buffer.frameLength > 0,
              let copy = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameLength) else { return nil }
        copy.frameLength = buffer.frameLength
        let source = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: buffer.audioBufferList))
        let target = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
        for i in 0..<min(source.count, target.count) {
            guard let from = source[i].mData, let to = target[i].mData else { continue }
            memcpy(to, from, Int(source[i].mDataByteSize))
            target[i].mDataByteSize = source[i].mDataByteSize
        }
        return copy
    }

    /// Loudness from 0 (silence, under -50 dB) to 1, for the waveform.
    private static func level(of buffer: AVAudioPCMBuffer) -> Float {
        guard let samples = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return 0 }
        let n = Int(buffer.frameLength)
        var sum: Float = 0
        for i in 0..<n { sum += samples[i] * samples[i] }
        let rms = (sum / Float(n)).squareRoot()
        let db = 20 * log10(max(rms, 1e-6))
        return min(max((db + 50) / 50, 0), 1)
    }
}

// MARK: - Window

struct DictationView: View {
    @ObservedObject var model: DictationModel

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
            Divider()
            HStack(spacing: 14) {
                Spacer()
                KeyHint(keys: "Hold Space", label: "Pause")
                KeyHint(keys: "↩", label: "Insert")
                KeyHint(keys: "⌘↩", label: "Copy")
                KeyHint(keys: "esc", label: "Cancel")
            }
            .padding(.horizontal, 14)
            .frame(height: 34)
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: model.phase == .paused ? "pause.circle.fill" : "mic.fill")
                .font(.title3)
                .foregroundStyle(model.phase == .listening ? Theme.accent : .secondary)
                .frame(width: 22)
                .contentTransition(.symbolEffect(.replace))
            Text(status)
                .font(.system(size: 17))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer()
            Waveform(levels: model.levels, active: model.phase == .listening)
                .frame(width: 150, height: 22)
                .opacity(model.phase == .listening || model.phase == .paused ? 1 : 0.35)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }

    private var status: String {
        switch model.phase {
        case .idle, .starting: "Starting…"
        case .downloading: "Downloading the speech model…"
        case .listening: "Listening"
        case .paused: "Paused"
        case .finishing: "Finishing…"
        case .failed: "Dictation stopped"
        }
    }

    @ViewBuilder private var content: some View {
        if case .failed(let error) = model.phase {
            VStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill").font(.title2).foregroundStyle(.orange)
                Text(error.message).multilineTextAlignment(.center)
                if error == .microphoneDenied {
                    Button("Open Microphone Settings…") { DictationModel.openMicrophoneSettings() }
                        .buttonStyle(.link)
                }
            }
            .font(.callout)
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                transcript
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 14)
            }
            // Short text starts at the top; longer text follows the words as they arrive.
            .defaultScrollAnchor(.top, for: .alignment)
            .defaultScrollAnchor(.bottom, for: .sizeChanges)
        }
    }

    @ViewBuilder private var transcript: some View {
        let committed = DictationModel.tidy(model.committed)
        let volatile = DictationModel.tidy(model.volatile)
        if committed.isEmpty && volatile.isEmpty {
            Text(model.phase == .listening ? "Start talking…" : " ")
                .font(.system(size: 17))
                .foregroundStyle(.tertiary)
        } else {
            let gap = committed.isEmpty || volatile.isEmpty ? "" : " "
            Text("\(committed)\(Text(gap + volatile).foregroundStyle(.secondary))")
                .font(.system(size: 17))
                .lineSpacing(3)
                .textSelection(.enabled)
        }
    }
}

/// Bars for the last couple of seconds of loudness, newest on the right.
private struct Waveform: View {
    let levels: [Float]
    let active: Bool

    var body: some View {
        HStack(alignment: .center, spacing: 2) {
            ForEach(levels.indices, id: \.self) { i in
                Capsule()
                    .fill(active ? Theme.accent : Color.secondary.opacity(0.5))
                    .frame(width: 2.5, height: max(3, CGFloat(levels[i]) * 22))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
        .animation(.linear(duration: 0.08), value: levels)
    }
}
