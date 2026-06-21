//
//  VoiceConfig.swift
//  Nook
//
//  Configuration for voice control / Whisper transcription.
//

import Foundation

enum VoiceConfig {
    /// Paste your OpenAI API key here for local voice transcription.
    /// Leave empty to fall back to OPENAI_API_KEY from the environment.
    static let openAIAPIKey = ""

    /// Whisper transcription model. "whisper-1" is the classic Whisper endpoint;
    /// "gpt-4o-transcribe" / "gpt-4o-mini-transcribe" are the newer, faster models.
    static let transcriptionModel = "whisper-1"

    /// Endpoint for OpenAI audio transcription.
    static let transcriptionEndpoint = "https://api.openai.com/v1/audio/transcriptions"

    /// Resolved key: prefers the local paste-in value, then the environment.
    static var resolvedAPIKey: String? {
        let trimmed = openAIAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        if let env = ProcessInfo.processInfo.environment["OPENAI_API_KEY"],
           !env.isEmpty {
            return env
        }
        return nil
    }
}
