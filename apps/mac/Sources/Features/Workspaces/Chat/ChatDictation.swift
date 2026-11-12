// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

import AVFoundation
import Observation
import Speech
import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Talk a prompt into the composer with the system's own dictation.
///
/// From macOS 26 and iOS 26 this is the system dictation model, run on this
/// device. A language is downloaded once, the first time it is used. Older
/// systems use the earlier recognizer, which sends audio to Apple when the
/// language has no on-device model. Nothing reaches tokenstat or the host:
/// only the finished words land in the draft, and they are sent like
/// anything typed.
///
/// Neither recognizer can tell which language is being spoken, so it listens
/// for one at a time. The default is the first of the person's preferred
/// languages, and the chip in the recording bar or the mic's menu switches to
/// another one, kept per device.
@MainActor
@Observable
final class ChatDictation {
    enum Phase: Equatable { case idle, starting, downloading, listening, finishing }

    /// A reason dictation cannot run, worded for the person.
    struct Problem: Identifiable, Equatable {
        enum Fix: Equatable { case privacy, dictation }
        let id = UUID()
        let message: String
        var fix: Fix?
    }

    static let levelCount = 160

    private(set) var phase: Phase = .idle
    var problem: Problem?
    /// A locale identifier the person picked, or nil to follow their
    /// preferred languages.
    private(set) var chosenLocale: String?
    /// Recent loudness, oldest first, each between 0 and 1.
    private(set) var levels = [Float](repeating: 0, count: ChatDictation.levelCount)
    private(set) var startedAt: Date?
    private(set) var download: Progress?

    private var session: Session?
    private var text: ChatDictationText?
    private var transcript = ChatDictationTranscript()
    private var read: () -> String = { "" }
    private var write: (String) -> Void = { _ in }
    /// Bumped by every start and stop, so a late reading from a finished
    /// session cannot write into the draft.
    private var generation = 0

    private static let localeKey = "chat.dictation.locale"

    init() {
        chosenLocale = UserDefaults.standard.string(forKey: Self.localeKey)
    }

    var isActive: Bool { phase != .idle }

    /// The language dictation will listen for.
    var locale: Locale { Self.resolve(chosenLocale) }

    /// Switching language mid-sentence keeps what was said and listens on in
    /// the new one.
    func choose(_ identifier: String?) {
        chosenLocale = identifier
        if let identifier { UserDefaults.standard.set(identifier, forKey: Self.localeKey) }
        else { UserDefaults.standard.removeObject(forKey: Self.localeKey) }
        guard isActive, phase != .finishing else { return }
        let read = read, write = write
        stop()
        start(read: read, write: write)
    }

    func start(read: @escaping () -> String, write: @escaping (String) -> Void) {
        guard phase == .idle else { return }
        generation += 1
        let mine = generation
        phase = .starting
        problem = nil
        transcript = ChatDictationTranscript()
        levels = [Float](repeating: 0, count: Self.levelCount)
        self.read = read
        self.write = write
        let locale = locale
        Task {
            guard await Self.speechAuthorized() else {
                return fail(mine, Problem(message: L10n.text("apple.chatdictation.speech_denied"), fix: .privacy))
            }
            guard await Self.microphoneAuthorized() else {
                return fail(mine, Problem(message: L10n.text("apple.chatdictation.microphone_denied"), fix: .privacy))
            }
            guard generation == mine else { return }
            do {
                if #available(macOS 26, iOS 26, *),
                   let supported = await DictationTranscriber.supportedLocale(equivalentTo: locale) {
                    try await beginModern(mine, locale: supported)
                } else {
                    try beginClassic(mine, locale: locale)
                }
            } catch {
                fail(mine, Problem(message: phase == .downloading
                    ? L10n.text("apple.chatdictation.download_failed", Self.name(of: locale.identifier), error.localizedDescription)
                    : L10n.text("apple.chatdictation.could_not_start", error.localizedDescription)))
            }
        }
    }

    /// Stop listening and keep the words. Waits briefly for the recognizer
    /// to settle the last of them.
    func finish() {
        guard phase == .listening, let session else { return stop() }
        let mine = generation
        phase = .finishing
        session.stopAudio()
        let settle = session.settle
        Task {
            await withTaskGroup(of: Void.self) { group in
                group.addTask { await settle() }
                group.addTask { try? await Task.sleep(for: .seconds(2)) }
                await group.next()
                group.cancelAll()
            }
            guard generation == mine else { return }
            stop()
        }
    }

    /// Stop at once. The words already in the draft stay there.
    func stop() {
        generation += 1
        tearDown()
    }

    /// Stop and put the draft back the way it was before dictation started.
    func cancel() {
        if let text, read() == text.expected { write(text.original) }
        stop()
    }

    // MARK: Sessions

    /// What one listening session needs to stop: the microphone, the
    /// recognizer, and a way to wait for its last words.
    private final class Session {
        let engine: AVAudioEngine
        let endInput: () -> Void
        let settle: @Sendable () async -> Void
        let cancel: () -> Void
        private var audioStopped = false

        init(engine: AVAudioEngine, endInput: @escaping () -> Void,
             settle: @escaping @Sendable () async -> Void, cancel: @escaping () -> Void) {
            self.engine = engine
            self.endInput = endInput
            self.settle = settle
            self.cancel = cancel
        }

        func stopAudio() {
            guard !audioStopped else { return }
            audioStopped = true
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
            endInput()
        }
    }

    @available(macOS 26, iOS 26, *)
    private func beginModern(_ mine: Int, locale: Locale) async throws {
        let transcriber = DictationTranscriber(
            locale: locale,
            contentHints: [],
            transcriptionOptions: [.punctuation],
            reportingOptions: [.volatileResults, .frequentFinalization],
            attributeOptions: []
        )
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            guard generation == mine else { return }
            phase = .downloading
            download = request.progress
            try await request.downloadAndInstall()
            download = nil
        }
        guard generation == mine else { return }
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            throw CocoaError(.featureUnsupported)
        }
        guard generation == mine else { return }

        try Self.activateAudioSession()
        let (stream, input) = AsyncStream.makeStream(of: AnalyzerInput.self)
        let engine = AVAudioEngine()
        let natural = engine.inputNode.outputFormat(forBus: 0)
        guard natural.sampleRate > 0, natural.channelCount > 0 else { throw CocoaError(.featureUnsupported) }
        engine.inputNode.installTap(onBus: 0, bufferSize: 1024, format: natural,
                                    block: Self.convert(from: natural, to: format, into: input, meter: meter(mine)))
        engine.prepare()
        try engine.start()

        let analyzer = SpeechAnalyzer(modules: [transcriber])
        do {
            try await analyzer.start(inputSequence: stream)
        } catch {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
            input.finish()
            throw error
        }
        let results = Task { [weak self] in
            do {
                for try await result in transcriber.results {
                    self?.heard(mine, String(result.text.characters), final: result.isFinal)
                }
            } catch {
                self?.failed(mine, error)
            }
        }
        let session = Session(
            engine: engine,
            endInput: { input.finish() },
            settle: {
                try? await analyzer.finalizeAndFinishThroughEndOfInput()
                await results.value
            },
            cancel: {
                results.cancel()
                Task { await analyzer.cancelAndFinishNow() }
            }
        )
        guard generation == mine else {
            session.stopAudio()
            session.cancel()
            return
        }
        listen(session)
    }

    private func beginClassic(_ mine: Int, locale: Locale) throws {
        guard let recognizer = SFSpeechRecognizer(locale: locale) else {
            return fail(mine, Problem(message: L10n.text("apple.chatdictation.language_unsupported", Self.name(of: locale.identifier))))
        }
        guard recognizer.isAvailable else {
            return fail(mine, Problem(message: L10n.text("apple.chatdictation.unavailable"), fix: .dictation))
        }
        try Self.activateAudioSession()
        let feed = RequestFeed()
        let engine = AVAudioEngine()
        let natural = engine.inputNode.outputFormat(forBus: 0)
        guard natural.sampleRate > 0, natural.channelCount > 0 else { throw CocoaError(.featureUnsupported) }
        engine.inputNode.installTap(onBus: 0, bufferSize: 1024, format: natural,
                                    block: Self.feed(feed, meter: meter(mine)))
        engine.prepare()
        try engine.start()
        listen(Session(engine: engine, endInput: { feed.end() }, settle: {}, cancel: { feed.cancel() }))
        recognize(mine, with: recognizer, into: feed)
    }

    /// The earlier recognizer ends a task at a long pause or after about a
    /// minute. While the person is still talking, a fresh one carries on.
    private func recognize(_ mine: Int, with recognizer: SFSpeechRecognizer, into feed: RequestFeed) {
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.taskHint = .dictation
        request.addsPunctuation = true
        if recognizer.supportsOnDeviceRecognition { request.requiresOnDeviceRecognition = true }
        let task = recognizer.recognitionTask(with: request, resultHandler: Self.deliver { [weak self] words, final, error in
            guard let self, self.generation == mine else { return }
            if let words {
                self.transcript.hearRunning(words)
                if final { self.transcript.finish(self.transcript.volatile) }
                self.publish()
            }
            if let error, !Self.isQuietEnd(error) { return self.failed(mine, error) }
            if final || error != nil {
                if self.phase == .listening { self.recognize(mine, with: recognizer, into: feed) }
            }
        })
        feed.use(request, task)
    }

    private func listen(_ session: Session) {
        self.session = session
        download = nil
        text = ChatDictationText(draft: read())
        startedAt = .now
        phase = .listening
    }

    private func heard(_ mine: Int, _ words: String, final: Bool) {
        guard generation == mine else { return }
        if final { transcript.finish(words) } else { transcript.hear(words) }
        publish()
    }

    private func publish() {
        guard var text else { return }
        guard let next = text.apply(transcript.text, to: read()) else { return stop() }
        self.text = text
        write(next)
    }

    private func failed(_ mine: Int, _ error: Error) {
        guard generation == mine, !Self.isQuietEnd(error), !(error is CancellationError) else { return }
        let nsError = error as NSError
        // 1700 from the assistant domain: Siri and Dictation are both off.
        let off = nsError.domain == "kAFAssistantErrorDomain" && nsError.code == 1700
        fail(mine, Problem(
            message: off ? L10n.text("apple.chatdictation.unavailable") : L10n.text("apple.chatdictation.could_not_start", error.localizedDescription),
            fix: off ? .dictation : nil
        ))
    }

    private func fail(_ mine: Int, _ problem: Problem) {
        guard generation == mine else { return }
        generation += 1
        tearDown()
        self.problem = problem
    }

    private func push(_ level: Float, _ mine: Int) {
        guard generation == mine, phase == .listening else { return }
        levels.removeFirst()
        levels.append(level)
    }

    private func meter(_ mine: Int) -> @Sendable (Float) -> Void {
        { [weak self] level in
            Task { @MainActor in self?.push(level, mine) }
        }
    }

    private func tearDown() {
        let wasActive = phase != .idle
        if let session {
            session.stopAudio()
            session.cancel()
        }
        session = nil
        text = nil
        download = nil
        startedAt = nil
        read = { "" }
        write = { _ in }
        #if os(iOS)
        if wasActive {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
        #endif
        _ = wasActive
        phase = .idle
    }

    // MARK: Off the main actor

    /// The request the earlier recognizer is listening with right now. The
    /// audio thread appends to it while the main actor swaps it for a fresh
    /// one, so it sits behind a lock.
    private final class RequestFeed: @unchecked Sendable {
        private let lock = NSLock()
        private var request: SFSpeechAudioBufferRecognitionRequest?
        private var task: SFSpeechRecognitionTask?

        func append(_ buffer: AVAudioPCMBuffer) {
            lock.lock(); let request = request; lock.unlock()
            request?.append(buffer)
        }

        func use(_ request: SFSpeechAudioBufferRecognitionRequest, _ task: SFSpeechRecognitionTask) {
            lock.lock()
            let old = self.request
            self.request = request
            self.task = task
            lock.unlock()
            old?.endAudio()
        }

        func end() {
            lock.lock(); let request = request; lock.unlock()
            request?.endAudio()
        }

        func cancel() {
            lock.lock()
            let request = request, task = task
            self.request = nil
            self.task = nil
            lock.unlock()
            request?.endAudio()
            task?.cancel()
        }
    }

    /// Taps run on the audio thread. Built outside the main actor so the
    /// closures do not inherit an isolation they cannot satisfy there.
    nonisolated private static func feed(_ feed: RequestFeed, meter: @escaping @Sendable (Float) -> Void) -> AVAudioNodeTapBlock {
        { buffer, _ in
            feed.append(buffer)
            meter(level(of: buffer))
        }
    }

    @available(macOS 26, iOS 26, *)
    nonisolated private static func convert(
        from natural: AVAudioFormat, to target: AVAudioFormat,
        into input: AsyncStream<AnalyzerInput>.Continuation,
        meter: @escaping @Sendable (Float) -> Void
    ) -> AVAudioNodeTapBlock {
        let converter = natural == target ? nil : AVAudioConverter(from: natural, to: target)
        return { buffer, _ in
            meter(level(of: buffer))
            guard let converter else {
                input.yield(AnalyzerInput(buffer: buffer))
                return
            }
            let capacity = AVAudioFrameCount(Double(buffer.frameLength) * target.sampleRate / natural.sampleRate) + 1
            guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return }
            var supplied = false
            var error: NSError?
            converter.convert(to: output, error: &error) { _, status in
                if supplied {
                    status.pointee = .noDataNow
                    return nil
                }
                supplied = true
                status.pointee = .haveData
                return buffer
            }
            if error == nil, output.frameLength > 0 { input.yield(AnalyzerInput(buffer: output)) }
        }
    }

    /// Loudness on a scale a person reads as loudness: decibels from -50
    /// (a quiet room) up to 0, mapped onto 0 to 1.
    nonisolated private static func level(of buffer: AVAudioPCMBuffer) -> Float {
        guard let samples = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return 0 }
        let count = Int(buffer.frameLength)
        var sum: Float = 0
        for index in 0..<count { sum += samples[index] * samples[index] }
        let decibels = 20 * log10(max(sqrt(sum / Float(count)), 0.000_01))
        return min(1, max(0, (decibels + 50) / 50))
    }

    nonisolated private static func deliver(
        _ receive: @escaping @MainActor (String?, Bool, Error?) -> Void
    ) -> (SFSpeechRecognitionResult?, Error?) -> Void {
        { result, error in
            let words = result?.bestTranscription.formattedString
            let final = result?.isFinal ?? false
            Task { @MainActor in receive(words, final, error) }
        }
    }

    /// Cancelling a task, or a stretch with nothing said, ends it with an
    /// error that is not worth showing anybody.
    nonisolated private static func isQuietEnd(_ error: Error) -> Bool {
        let nsError = error as NSError
        if nsError.domain == "kAFAssistantErrorDomain", [203, 216, 301, 1110].contains(nsError.code) { return true }
        if nsError.domain == "kLSRErrorDomain", nsError.code == 301 { return true }
        return false
    }

    private static func activateAudioSession() throws {
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.record, mode: .measurement, options: .duckOthers)
        try session.setActive(true, options: .notifyOthersOnDeactivation)
        #endif
    }

    private static func speechAuthorized() async -> Bool {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized: return true
        case .notDetermined:
            return await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0 == .authorized) }
            }
        default: return false
        }
    }

    private static func microphoneAuthorized() async -> Bool {
        #if os(macOS)
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .audio)
        default: return false
        }
        #else
        switch AVAudioApplication.shared.recordPermission {
        case .granted: return true
        case .undetermined: return await AVAudioApplication.requestRecordPermission()
        default: return false
        }
        #endif
    }

    // MARK: Languages

    /// The person's own languages that the recognizer supports, in their
    /// order of preference.
    static var preferredChoices: [String] {
        var seen = Set<String>()
        return Locale.preferredLanguages.compactMap(match).filter { seen.insert($0).inserted }
    }

    /// Every language the recognizer supports, by its name in the person's
    /// language, without the ones already offered first.
    static var otherChoices: [String] {
        let first = Set(preferredChoices)
        return SFSpeechRecognizer.supportedLocales()
            .map(\.identifier)
            .filter { !first.contains($0) }
            .sorted { name(of: $0).localizedStandardCompare(name(of: $1)) == .orderedAscending }
    }

    static func name(of identifier: String) -> String {
        Locale.current.localizedString(forIdentifier: identifier) ?? identifier
    }

    /// Two letters for the chip: EN, HU.
    static func code(of locale: Locale) -> String {
        (locale.language.languageCode?.identifier ?? locale.identifier).uppercased()
    }

    static func resolve(_ chosen: String?) -> Locale {
        if let chosen { return Locale(identifier: chosen) }
        if let first = preferredChoices.first { return Locale(identifier: first) }
        return Locale.current
    }

    /// A supported locale for one preferred language: the same identifier if
    /// there is one, otherwise the same language in the region the person
    /// lives in, otherwise the first region the recognizer has for it.
    private static func match(_ preferred: String) -> String? {
        let supported = SFSpeechRecognizer.supportedLocales().map(\.identifier)
        let wanted = Locale(identifier: preferred)
        if let exact = supported.first(where: { Locale(identifier: $0).identifier(.bcp47) == wanted.identifier(.bcp47) }) {
            return exact
        }
        guard let language = wanted.language.languageCode else { return nil }
        let candidates = supported.filter { Locale(identifier: $0).language.languageCode == language }
        let region = wanted.region ?? Locale.current.region
        if let region, let regional = candidates.first(where: { Locale(identifier: $0).region == region }) {
            return regional
        }
        return candidates.sorted().first
    }

    static func openSettings(for fix: Problem.Fix) {
        #if os(macOS)
        let address = fix == .dictation
            ? "x-apple.systempreferences:com.apple.Keyboard-Settings.extension"
            : "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"
        if let url = URL(string: address) { NSWorkspace.shared.open(url) }
        #else
        if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
        #endif
    }
}

/// The mic at the trailing end of the composer. Tap to talk. Its menu picks
/// the language to listen for. While dictation runs the recording bar takes
/// over, so the mic itself steps aside.
struct ChatDictationButton: View {
    @Bindable var dictation: ChatDictation
    @Binding var draft: String
    var size: CGFloat
    var disabled = false

    var body: some View {
        Button {
            dictation.start(read: { draft }, write: { draft = $0 })
        } label: {
            ActionIcon.dictate.label(L10n.text("apple.chatdictation.dictate"))
                .environment(\.compactActions, true)
                .foregroundStyle(.secondary)
                .frame(width: size, height: size)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .help(L10n.text("apple.chatdictation.help", ChatDictation.name(of: dictation.locale.identifier)))
        .accessibilityLabel(L10n.text("apple.chatdictation.dictate"))
        .accessibilityValue(ChatDictation.name(of: dictation.locale.identifier))
        .contextMenu { ChatDictationLanguages(dictation: dictation) }
    }
}

/// What replaces the composer's controls while dictation runs: the language,
/// a live waveform, the time, and Cancel and Done.
struct ChatDictationBar: View {
    @Bindable var dictation: ChatDictation
    /// The size of the Cancel and Done targets.
    var control: CGFloat

    var body: some View {
        HStack(spacing: Theme.Space.s) {
            languageChip
            Group {
                if dictation.phase == .downloading {
                    HStack(spacing: Theme.Space.s) {
                        if let download = dictation.download {
                            ProgressView(download).progressViewStyle(.linear).labelsHidden().frame(maxWidth: 160)
                        } else {
                            ProgressView().controlSize(.small)
                        }
                        Text(L10n.text("apple.chatdictation.downloading", ChatDictation.name(of: dictation.locale.identifier)))
                            .font(Theme.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    ChatDictationWaveform(levels: dictation.levels, live: dictation.phase == .listening)
                        .frame(maxWidth: .infinity)
                        .frame(height: 28)
                        .accessibilityHidden(true)
                }
            }
            if let startedAt = dictation.startedAt {
                Text(startedAt, style: .timer)
                    .font(Theme.mono(12))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .fixedSize()
            }
            Button(L10n.text("apple.chatdictation.cancel"), .dismiss) { dictation.cancel() }
                .environment(\.compactActions, true)
                .buttonStyle(.plain)
                .font(Theme.font(15, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: control, height: control)
                .contentShape(.rect)
                .help(L10n.text("apple.chatdictation.cancel"))
            Button(L10n.text("apple.chatdictation.done"), .done) { dictation.finish() }
                .environment(\.compactActions, true)
                .buttonStyle(AccentButtonStyle(small: true))
                .disabled(dictation.phase != .listening)
                .help(L10n.text("apple.chatdictation.done"))
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L10n.text("apple.chatdictation.title"))
    }

    private var languageChip: some View {
        Menu {
            ChatDictationLanguages(dictation: dictation)
        } label: {
            Text(ChatDictation.code(of: dictation.locale))
                .font(Theme.mono(11, weight: .semibold))
                .foregroundStyle(Theme.accent)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Theme.accentSoft, in: Capsule())
                .contentShape(Capsule())
        }
        #if os(macOS)
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        #endif
        .fixedSize()
        .help(L10n.text("apple.chatdictation.language", ChatDictation.name(of: dictation.locale.identifier)))
        .accessibilityLabel(L10n.text("apple.chatdictation.language", ChatDictation.name(of: dictation.locale.identifier)))
    }
}

/// Bars scrolling in from the right, one per slice of audio. Quiet reads as
/// a row of dots, speech as a band that rises and falls with the voice.
struct ChatDictationWaveform: View {
    var levels: [Float]
    var live: Bool

    var body: some View {
        Canvas { context, size in
            let bar: CGFloat = 3
            let gap: CGFloat = 2.5
            let fit = max(1, Int((size.width + gap) / (bar + gap)))
            let shown = levels.suffix(fit)
            var x = size.width - CGFloat(shown.count) * (bar + gap) + gap
            for (index, level) in shown.enumerated() {
                // A little gain so ordinary speech fills the band.
                let lifted = CGFloat(min(1, pow(level, 1.4) * 1.6))
                let height = max(bar, lifted * size.height)
                let rect = CGRect(x: x, y: (size.height - height) / 2, width: bar, height: height)
                let age = Double(index) / Double(max(shown.count - 1, 1))
                context.fill(Path(roundedRect: rect, cornerRadius: bar / 2),
                             with: .color(Theme.accent.opacity(live ? 0.35 + 0.65 * age : 0.3)))
                x += bar + gap
            }
        }
    }
}

/// Automatic, the person's own languages, then every other one.
struct ChatDictationLanguages: View {
    @Bindable var dictation: ChatDictation

    var body: some View {
        Section {
            choice(nil, title: L10n.text("apple.chatdictation.automatic",
                                         ChatDictation.name(of: ChatDictation.resolve(nil).identifier)))
        }
        Section {
            ForEach(ChatDictation.preferredChoices, id: \.self) { choice($0, title: ChatDictation.name(of: $0)) }
            Menu(L10n.text("apple.chatdictation.more_languages")) {
                ForEach(ChatDictation.otherChoices, id: \.self) { choice($0, title: ChatDictation.name(of: $0)) }
            }
        }
    }

    private func choice(_ identifier: String?, title: String) -> some View {
        Button {
            dictation.choose(identifier)
        } label: {
            if dictation.chosenLocale == identifier { Label(title, systemImage: "checkmark") } else { Text(title) }
        }
    }
}

/// Applied by the composer that owns the dictation, so the explanation
/// outlives whichever control was on screen when it failed. It also stops
/// dictation when the composer goes away or starts sending.
struct ChatDictationLifetime: ViewModifier {
    @Bindable var dictation: ChatDictation
    var blocked: Bool

    func body(content: Content) -> some View {
        content
            .modifier(ChatDictationProblemAlert(dictation: dictation))
            .onChange(of: blocked) { _, now in if now { dictation.stop() } }
            .onDisappear { dictation.stop() }
    }
}

private struct ChatDictationProblemAlert: ViewModifier {
    @Bindable var dictation: ChatDictation

    func body(content: Content) -> some View {
        content.alert(
            L10n.text("apple.chatdictation.title"),
            isPresented: Binding(get: { dictation.problem != nil }, set: { if !$0 { dictation.problem = nil } }),
            presenting: dictation.problem
        ) { problem in
            if let fix = problem.fix {
                Button(L10n.text("apple.chatdictation.open_settings")) { ChatDictation.openSettings(for: fix) }
            }
            Button(L10n.text("apple.chatdictation.ok"), role: .cancel) {}
        } message: { problem in
            Text(problem.message)
        }
    }
}
