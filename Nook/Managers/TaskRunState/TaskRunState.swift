//
//  TaskRunState.swift
//  OpenHive — observable run state for agent-first UX
//

import Foundation

enum TaskRunPhase: String, Equatable {
    case idle
    case matching
    case confirming
    case running
    case planning
    case complete
    case failed
}

struct TaskStepLogEntry: Identifiable, Equatable {
    let id = UUID()
    let index: Int
    let message: String
    let stateId: String?
    let timestamp: Date
}

struct SkillMatch: Equatable {
    let skillId: String
    let name: String
    let confidence: Double
    let mdpId: String
}

struct PlanSubtask: Identifiable, Equatable {
    let id: String
    let index: Int
    let type: String
    let description: String
    var status: String
}

@MainActor
@Observable
final class TaskRunState {
    static let shared = TaskRunState()

    var phase: TaskRunPhase = .idle
    var prompt: String = ""
    var skillId: String?
    var skillName: String?
    var planId: String?
    var currentSubtaskIndex: Int = 0
    var subtasks: [PlanSubtask] = []
    var mdpStateId: String?
    var liveStateId: String?
    var stepLog: [TaskStepLogEntry] = []
    var notchExpanded: Bool = false
    var agentModeEnabled: Bool = true
    var planningModeEnabled: Bool = false
    var isRecording: Bool = false
    var pendingMatch: SkillMatch?
    var showSkillConfirm: Bool = false
    var showBenchmark: Bool = false
    var lastBenchmarkRunId: String?
    var shouldRunAgentAfterMiss: Bool = false
    var errorMessage: String?
    var agentModel: String = "gpt-4o"
    var runStartedAt: Date?
    var flightDemoMode: FlightDemoMode = .none

    private init() {}

    func reset() {
        phase = .idle
        skillId = nil
        skillName = nil
        planId = nil
        currentSubtaskIndex = 0
        subtasks = []
        mdpStateId = nil
        liveStateId = nil
        stepLog = []
        pendingMatch = nil
        showSkillConfirm = false
        errorMessage = nil
        flightDemoMode = .none
    }

    func beginMatching(prompt: String) {
        self.prompt = prompt
        phase = .matching
        errorMessage = nil
    }

    func presentConfirmation(_ match: SkillMatch) {
        pendingMatch = match
        skillId = match.skillId
        skillName = match.name
        showSkillConfirm = true
        phase = .confirming
    }

    func beginRun(skillName: String?, skillId: String?) {
        self.skillName = skillName
        self.skillId = skillId
        phase = .running
        stepLog = []
        showSkillConfirm = false
        runStartedAt = Date()
        notchExpanded = true
        AgentNotchViewModel.shared.open()
    }

    func appendStep(_ message: String, stateId: String? = nil) {
        stepLog.append(
            TaskStepLogEntry(
                index: stepLog.count + 1,
                message: message,
                stateId: stateId,
                timestamp: Date()
            )
        )
    }

    func handleMDPStep(stateId: String, nextStateId: String, action: String) {
        liveStateId = nextStateId
        mdpStateId = nextStateId
        appendStep("MDP \(stateId)→\(nextStateId): \(action)", stateId: nextStateId)
    }

    func completeRun(success: Bool) {
        phase = success ? .complete : .failed
    }
}
