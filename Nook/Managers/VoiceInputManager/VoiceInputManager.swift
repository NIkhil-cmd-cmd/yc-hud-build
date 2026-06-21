//
//  VoiceInputManager.swift
//  Nook
//
//  Global push-to-talk voice control for the OpenHive agent.
//
//  Flow: a global ⌘+⌥ tap opens the Agent Notch in a "Listening" state, speaks a
//  short audible cue, records the mic, transcribes via OpenAI Whisper, and
//  dispatches the transcript to the browser agent (EngineBridge).
//

import AppKit
import AVFoundation
import SwiftUI

@MainActor
@Observable
final class VoiceInputManager: NSObject {
    static let shared = VoiceInputManager()

    // MARK: Observable UI state (read by AgentNotchView)
    private(set) var isListening: Bool = false
    private(set) var isTranscribing: Bool = false
    private(set) var transcript: String = ""
    private(set) var statusText: String = ""
    /// Smoothed mic level 0...1 for the notch waveform.
    private(set) var audioLevel: CGFloat = 0

    // MARK: Dependencies (wired from NookApp)
    weak var browserManager: BrowserManager?
    weak var windowRegistry: WindowRegistry?

    // MARK: Audio
    private var recorder: AVAudioRecorder?
    private var recordingURL: URL?
    private let synthesizer = AVSpeechSynthesizer()

    private var meterTimer: Timer?
    private var maxDurationTimer: Timer?
    private var hasHeardSpeech = false
    private var silentTicks = 0

    /// Mic level (dBFS) above which we consider the user to be speaking.
    private let speechThresholdDB: Float = -30
    /// Meter polling interval.
    private let meterInterval: TimeInterval = 0.08
    /// Consecutive silent ticks (after speech) before auto-stopping (~1.6s).
    private let silenceTicksToStop = 20
    /// Hard cap on a single listening session.
    private let maxListeningDuration: TimeInterval = 30

    // MARK: Global hotkey state (⌘+⌥ clean tap)
    private var flagsMonitorGlobal: Any?
    private var flagsMonitorLocal: Any?
    private var keyMonitorGlobal: Any?
    private var keyMonitorLocal: Any?

    private var comboEngaged = false
    private var otherKeyDuringCombo = false
    private var comboStartedAt: Date?
    /// A clean tap must be released within this window to count.
    private let comboTapWindow: TimeInterval = 1.2

    private override init() {
        super.init()
    }

    // MARK: - Setup

    func configure(browserManager: BrowserManager, windowRegistry: WindowRegistry) {
        self.browserManager = browserManager
        self.windowRegistry = windowRegistry
        installHotkeyMonitors()
    }

    // MARK: - Global hotkey

    private func installHotkeyMonitors() {
        guard flagsMonitorLocal == nil else { return }

        // NSEvent monitor closures run on the main thread; this manager is @MainActor,
        // so the (non-Sendable) closures inherit main-actor isolation and may call
        // main-actor methods directly — same pattern as KeyboardShortcutManager.
        flagsMonitorGlobal = NSEvent.addGlobalMonitorForEvents(matching: [.flagsChanged]) { [weak self] event in
            self?.handleFlagsChanged(event)
        }
        flagsMonitorLocal = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged]) { [weak self] event in
            self?.handleFlagsChanged(event)
            return event
        }
        keyMonitorGlobal = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            self?.handleKeyDown(event)
        }
        keyMonitorLocal = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            // Escape cancels an active listening session and consumes the key.
            if let self, self.isListening, event.keyCode == 53 {
                self.stopListening(submit: false)
                return nil
            }
            self?.handleKeyDown(event)
            return event
        }
    }

    private func handleFlagsChanged(_ event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let cmdOpt = flags.contains(.command) && flags.contains(.option)
        let noOtherModifiers = !flags.contains(.control) && !flags.contains(.shift)
        let cleanCombo = cmdOpt && noOtherModifiers

        if cleanCombo {
            if !comboEngaged {
                comboEngaged = true
                otherKeyDuringCombo = false
                comboStartedAt = Date()
            }
        } else if comboEngaged {
            // Combo broken (released, or another modifier added).
            let heldFor = comboStartedAt.map { Date().timeIntervalSince($0) } ?? .infinity
            let wasCleanTap = !otherKeyDuringCombo && heldFor <= comboTapWindow
            comboEngaged = false
            comboStartedAt = nil
            if wasCleanTap {
                toggle()
            }
        }
    }

    private func handleKeyDown(_ event: NSEvent) {
        // Any key pressed while ⌘+⌥ is held disqualifies the tap (it's a real shortcut).
        if comboEngaged { otherKeyDuringCombo = true }
    }

    // MARK: - Listening lifecycle

    func toggle() {
        if isListening {
            stopListening(submit: true)
        } else if !isTranscribing {
            startListening()
        }
    }

    func startListening() {
        guard !isListening, !isTranscribing else { return }
        guard VoiceConfig.resolvedAPIKey != nil else {
            WorkflowManager.postToast("Add your OpenAI API key in VoiceConfig.swift to use voice", isError: true)
            return
        }
        statusText = "Preparing…"

        AVCaptureDevice.requestAccess(for: .audio) { granted in
            // Only a Sendable Bool crosses the actor boundary here.
            Task { @MainActor in
                if granted {
                    VoiceInputManager.shared.beginRecording()
                } else {
                    VoiceInputManager.shared.presentPermissionError()
                }
            }
        }
    }

    private func beginRecording() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("nook-voice-\(UUID().uuidString).m4a")
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 16_000,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.medium.rawValue,
        ]

        do {
            let rec = try AVAudioRecorder(url: url, settings: settings)
            rec.isMeteringEnabled = true
            guard rec.record() else {
                throw NSError(domain: "VoiceInput", code: -1,
                              userInfo: [NSLocalizedDescriptionKey: "Recorder failed to start"])
            }
            recorder = rec
            recordingURL = url
        } catch {
            statusText = ""
            WorkflowManager.postToast("Couldn't start microphone: \(error.localizedDescription)", isError: true)
            return
        }

        isListening = true
        transcript = ""
        hasHeardSpeech = false
        silentTicks = 0
        audioLevel = 0
        statusText = "Listening…"
        showNotch()
        speakCue()
        armTimers()
    }

    func stopListening(submit: Bool) {
        guard isListening else { return }
        isListening = false
        meterTimer?.invalidate(); meterTimer = nil
        maxDurationTimer?.invalidate(); maxDurationTimer = nil
        audioLevel = 0

        recorder?.stop()
        let url = recordingURL
        recorder = nil
        recordingURL = nil

        guard submit, let url else {
            statusText = ""
            if let url { try? FileManager.default.removeItem(at: url) }
            settleNotchIfIdle()
            return
        }

        transcribeAndDispatch(url: url)
    }

    // MARK: - Metering / silence detection

    private func armTimers() {
        meterTimer = Timer.scheduledTimer(withTimeInterval: meterInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.pollMeter() }
        }
        maxDurationTimer = Timer.scheduledTimer(withTimeInterval: maxListeningDuration, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.stopListening(submit: true) }
        }
    }

    private func pollMeter() {
        guard let recorder, isListening else { return }
        recorder.updateMeters()
        let power = recorder.averagePower(forChannel: 0)

        // Map dBFS (-60...0) to 0...1 for the waveform.
        let normalized = max(0, min(1, CGFloat((power + 60) / 60)))
        audioLevel = audioLevel * 0.6 + normalized * 0.4

        if power > speechThresholdDB {
            hasHeardSpeech = true
            silentTicks = 0
        } else if hasHeardSpeech {
            silentTicks += 1
            if silentTicks >= silenceTicksToStop {
                stopListening(submit: true)
            }
        }
    }

    // MARK: - Transcription (OpenAI Whisper)

    private func transcribeAndDispatch(url: URL) {
        guard let apiKey = VoiceConfig.resolvedAPIKey else {
            WorkflowManager.postToast("Missing OpenAI API key", isError: true)
            settleNotchIfIdle()
            return
        }

        isTranscribing = true
        statusText = "Transcribing…"

        Task { @MainActor in
            defer {
                isTranscribing = false
                try? FileManager.default.removeItem(at: url)
            }
            do {
                let text = try await Self.transcribe(fileURL: url, apiKey: apiKey)
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                transcript = trimmed
                statusText = ""
                if trimmed.isEmpty {
                    WorkflowManager.postToast("Didn't catch that — try again", isError: true)
                    settleNotchIfIdle()
                } else {
                    dispatchToAgent(prompt: trimmed)
                }
            } catch {
                statusText = ""
                WorkflowManager.postToast("Transcription failed: \(error.localizedDescription)", isError: true)
                settleNotchIfIdle()
            }
        }
    }

    /// Performs a multipart POST to OpenAI's transcription endpoint. Runs off the main actor.
    nonisolated private static func transcribe(fileURL: URL, apiKey: String) async throws -> String {
        let audioData = try Data(contentsOf: fileURL)
        let boundary = "Boundary-\(UUID().uuidString)"

        var request = URLRequest(url: URL(string: VoiceConfig.transcriptionEndpoint)!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 30

        var body = Data()
        func appendField(_ name: String, _ value: String) {
            body.append("--\(boundary)\r\n".data(using: .utf8)!)
            body.append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".data(using: .utf8)!)
            body.append("\(value)\r\n".data(using: .utf8)!)
        }
        appendField("model", VoiceConfig.transcriptionModel)
        appendField("response_format", "json")

        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"audio.m4a\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: audio/m4a\r\n\r\n".data(using: .utf8)!)
        body.append(audioData)
        body.append("\r\n".data(using: .utf8)!)
        body.append("--\(boundary)--\r\n".data(using: .utf8)!)

        request.httpBody = body

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw NSError(domain: "VoiceInput", code: -2,
                          userInfo: [NSLocalizedDescriptionKey: "No HTTP response"])
        }
        guard http.statusCode == 200 else {
            let detail = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])
                .flatMap { ($0?["error"] as? [String: Any])?["message"] as? String }
                ?? "HTTP \(http.statusCode)"
            throw NSError(domain: "VoiceInput", code: http.statusCode,
                          userInfo: [NSLocalizedDescriptionKey: detail])
        }
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        return (json?["text"] as? String) ?? ""
    }

    // MARK: - Notch + cue

    private func showNotch() {
        AgentNotchPanelController.shared.show()
        AgentNotchViewModel.shared.open()
    }

    private func settleNotchIfIdle() {
        if TaskRunState.shared.phase != .running && !EngineBridge.shared.isExecuting {
            AgentNotchViewModel.shared.close()
        }
    }

    private func speakCue() {
        let utterance = AVSpeechUtterance(string: "Listening")
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        utterance.volume = 0.7
        synthesizer.speak(utterance)
    }

    private func presentPermissionError() {
        statusText = ""
        WorkflowManager.postToast(
            "Enable Microphone access for Nook in System Settings → Privacy",
            isError: true
        )
    }

    // MARK: - Dispatch to agent

    private func dispatchToAgent(prompt: String) {
        guard let browserManager, let windowState = windowRegistry?.activeWindow else {
            WorkflowManager.postToast("No browser window available", isError: true)
            return
        }
        guard let tab = browserManager.currentTab(for: windowState) else {
            WorkflowManager.postToast("No tab available", isError: true)
            return
        }
        guard EngineBridge.shared.engineReady else {
            WorkflowManager.postToast("Engine offline — run ./scripts/start_engine.sh", isError: true)
            return
        }
        guard let webView = browserManager.ensureWebView(for: tab.id, in: windowState.id) else {
            WorkflowManager.postToast("Could not prepare browser tab", isError: true)
            return
        }

        // Bring the browser forward so the user can watch the agent work.
        NSApp.activate(ignoringOtherApps: true)

        tab.isOpenHiveNewTab = false
        browserManager.refreshCompositor(for: windowState)

        TaskRunState.shared.prompt = prompt
        TaskRunState.shared.beginRun(skillName: nil, skillId: nil, tabId: tab.id)
        showNotch()

        EngineBridge.shared.startAgentTask(
            goal: prompt,
            webView: webView,
            tabId: tab.id,
            windowId: windowState.id,
            browserManager: browserManager
        )
    }
}
