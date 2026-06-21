//
//  VoiceInputManager.swift
//  Nook
//
//  Global push-to-talk voice control for the OpenHive agent.
//
//  Flow: a global ⌘+⌥ tap opens the Agent Notch in a "Listening" state, speaks a
//  short audible cue, transcribes speech live via the on-device Speech framework,
//  and dispatches the final transcript to the browser agent (EngineBridge).
//

import AppKit
import AVFoundation
import Speech
import SwiftUI

@MainActor
@Observable
final class VoiceInputManager: NSObject {
    static let shared = VoiceInputManager()

    // MARK: Observable UI state (read by AgentNotchView)
    private(set) var isListening: Bool = false
    private(set) var transcript: String = ""
    private(set) var statusText: String = ""

    // MARK: Dependencies (wired from NookApp)
    weak var browserManager: BrowserManager?
    weak var windowRegistry: WindowRegistry?

    // MARK: Speech / audio
    private let speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private let audioEngine = AVAudioEngine()
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private let synthesizer = AVSpeechSynthesizer()

    private var silenceTimer: Timer?
    private var maxDurationTimer: Timer?

    /// Stop after this much silence following speech.
    private let silenceTimeout: TimeInterval = 1.8
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

        flagsMonitorGlobal = NSEvent.addGlobalMonitorForEvents(matching: [.flagsChanged]) { [weak self] event in
            Task { @MainActor in self?.handleFlagsChanged(event) }
        }
        flagsMonitorLocal = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged]) { [weak self] event in
            Task { @MainActor in self?.handleFlagsChanged(event) }
            return event
        }
        keyMonitorGlobal = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            Task { @MainActor in self?.handleKeyDown(event) }
        }
        keyMonitorLocal = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            // Escape cancels an active listening session and consumes the key.
            if let self, self.isListening, event.keyCode == 53 {
                self.stopListening(submit: false)
                return nil
            }
            Task { @MainActor in self?.handleKeyDown(event) }
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
        } else {
            startListening()
        }
    }

    func startListening() {
        guard !isListening else { return }

        ensureAuthorized { [weak self] granted in
            guard let self else { return }
            guard granted else {
                self.presentPermissionError()
                return
            }
            self.beginRecognition()
        }
    }

    private func beginRecognition() {
        guard let recognizer = speechRecognizer, recognizer.isAvailable else {
            statusText = "Speech recognition unavailable"
            WorkflowManager.postToast("Speech recognition unavailable on this Mac", isError: true)
            return
        }

        // Reset any prior session.
        recognitionTask?.cancel()
        recognitionTask = nil
        transcript = ""

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        recognitionRequest = request

        let inputNode = audioEngine.inputNode
        let format = inputNode.outputFormat(forBus: 0)

        // A zero-channel format means no usable input device.
        guard format.channelCount > 0 else {
            statusText = "No microphone available"
            WorkflowManager.postToast("No microphone available", isError: true)
            recognitionRequest = nil
            return
        }

        inputNode.removeTap(onBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            self?.recognitionRequest?.append(buffer)
        }

        audioEngine.prepare()
        do {
            try audioEngine.start()
        } catch {
            statusText = "Couldn't start microphone"
            WorkflowManager.postToast("Couldn't start microphone: \(error.localizedDescription)", isError: true)
            cleanupAudio()
            return
        }

        isListening = true
        statusText = "Listening…"
        showNotch()
        speakCue()
        armMaxDurationTimer()

        recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            Task { @MainActor in
                guard let self else { return }
                if let result {
                    self.transcript = result.bestTranscription.formattedString
                    self.resetSilenceTimer()
                }
                if error != nil || (result?.isFinal ?? false) {
                    // Finalize: submit whatever we have if this wasn't a manual cancel.
                    if self.isListening {
                        self.stopListening(submit: true)
                    }
                }
            }
        }
    }

    func stopListening(submit: Bool) {
        guard isListening else { return }
        isListening = false
        silenceTimer?.invalidate(); silenceTimer = nil
        maxDurationTimer?.invalidate(); maxDurationTimer = nil

        recognitionRequest?.endAudio()
        cleanupAudio()
        recognitionTask?.cancel()
        recognitionTask = nil
        recognitionRequest = nil

        let finalText = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        statusText = ""

        if submit, !finalText.isEmpty {
            dispatchToAgent(prompt: finalText)
        } else {
            // Nothing to run — let the notch settle back.
            if TaskRunState.shared.phase != .running && !EngineBridge.shared.isExecuting {
                AgentNotchViewModel.shared.close()
            }
        }
    }

    private func cleanupAudio() {
        if audioEngine.isRunning {
            audioEngine.stop()
        }
        audioEngine.inputNode.removeTap(onBus: 0)
    }

    // MARK: - Timers

    private func resetSilenceTimer() {
        silenceTimer?.invalidate()
        silenceTimer = Timer.scheduledTimer(withTimeInterval: silenceTimeout, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.stopListening(submit: true) }
        }
    }

    private func armMaxDurationTimer() {
        maxDurationTimer?.invalidate()
        maxDurationTimer = Timer.scheduledTimer(withTimeInterval: maxListeningDuration, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.stopListening(submit: true) }
        }
    }

    // MARK: - Notch + cue

    private func showNotch() {
        AgentNotchPanelController.shared.show()
        AgentNotchViewModel.shared.open()
    }

    private func speakCue() {
        let utterance = AVSpeechUtterance(string: "Listening")
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        utterance.volume = 0.7
        synthesizer.speak(utterance)
    }

    // MARK: - Authorization

    private func ensureAuthorized(_ completion: @escaping (Bool) -> Void) {
        SFSpeechRecognizer.requestAuthorization { speechStatus in
            let speechOK = speechStatus == .authorized
            AVCaptureDevice.requestAccess(for: .audio) { micOK in
                Task { @MainActor in completion(speechOK && micOK) }
            }
        }
    }

    private func presentPermissionError() {
        statusText = ""
        WorkflowManager.postToast(
            "Enable Microphone + Speech Recognition for Nook in System Settings → Privacy",
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
