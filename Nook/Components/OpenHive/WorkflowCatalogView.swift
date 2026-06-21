//
//  WorkflowCatalogView.swift
//  OpenHive — Cmd+G hierarchical workflow browser (category → task → detail)
//

import SwiftUI
import WebKit

struct WorkflowCatalogView: View {
    @Bindable private var engine = EngineBridge.shared
    @Bindable private var workflows = WorkflowManager.shared
    @EnvironmentObject private var browserManager: BrowserManager
    @Environment(BrowserWindowState.self) private var windowState

    @State private var selectedCategory: WorkflowCategory = .all
    @State private var selectedWorkflowId: String?
    @State private var searchText = ""
    @State private var graphWorkflowId: String?

    private var grouped: [WorkflowCategory: [EngineBridge.WorkflowSummary]] {
        Dictionary(grouping: engine.workflows.filter { !$0.id.hasSuffix("_policy") }) { wf in
            WorkflowCategory.from(raw: wf.category)
        }
    }

    private var filteredWorkflows: [EngineBridge.WorkflowSummary] {
        let base: [EngineBridge.WorkflowSummary]
        if selectedCategory == .all {
            base = engine.workflows.filter { !$0.id.hasSuffix("_policy") }
        } else {
            base = grouped[selectedCategory] ?? []
        }
        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return base.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending } }
        return base
            .filter { wf in
                wf.name.lowercased().contains(q)
                    || wf.id.lowercased().contains(q)
                    || wf.category.lowercased().contains(q)
                    || wf.tags.contains(where: { $0.lowercased().contains(q) })
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private var selectedWorkflow: EngineBridge.WorkflowSummary? {
        guard let selectedWorkflowId else { return nil }
        return engine.workflows.first(where: { $0.id == selectedWorkflowId })
    }

    var body: some View {
        Group {
            if let graphWorkflowId {
                WorkflowGraphView(workflowId: graphWorkflowId, onBack: { self.graphWorkflowId = nil })
            } else {
                catalogShell
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear {
            engine.refreshWorkflows()
        }
        .onChange(of: filteredWorkflows.map(\.id)) { _, ids in
            if let selected = selectedWorkflowId, !ids.contains(selected) {
                selectedWorkflowId = ids.first
            } else if selectedWorkflowId == nil {
                selectedWorkflowId = ids.first
            }
        }
    }

    private var catalogShell: some View {
        NavigationSplitView {
            categorySidebar
                .navigationSplitViewColumnWidth(min: 168, ideal: 188, max: 220)
        } content: {
            workflowList
                .navigationSplitViewColumnWidth(min: 240, ideal: 300, max: 380)
        } detail: {
            detailPane
                .frame(minWidth: 320)
        }
    }

    // MARK: - Sidebar (categories)

    private var categorySidebar: some View {
        List(selection: $selectedCategory) {
            Section {
                ForEach(WorkflowCategory.sidebarOrder) { category in
                    if category == .all || !(grouped[category] ?? []).isEmpty {
                        Label {
                            HStack {
                                Text(category.title)
                                Spacer()
                                Text("\(count(for: category))")
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.tertiary)
                            }
                        } icon: {
                            Image(systemName: category.icon)
                                .foregroundStyle(category.tint)
                        }
                        .tag(category)
                    }
                }
            } header: {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Workflows")
                        .font(.headline)
                    Text("\(engine.workflows.count) total")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .textCase(nil)
                .padding(.bottom, 4)
            }
        }
        .listStyle(.sidebar)
        .navigationTitle("Browse")
    }

    // MARK: - Workflow list (tasks)

    private var workflowList: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Filter tasks…", text: $searchText)
                    .textFieldStyle(.plain)
                if !searchText.isEmpty {
                    Button { searchText = "" } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(.ultraThinMaterial)

            if filteredWorkflows.isEmpty {
                ContentUnavailableView(
                    "No workflows",
                    systemImage: "tray",
                    description: Text(engine.isConnected
                        ? "Run ./scripts/seed_workflows.sh to install the catalog."
                        : "Start the engine with ./scripts/start_engine.sh")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(filteredWorkflows, selection: $selectedWorkflowId) { wf in
                    workflowRow(wf)
                        .tag(wf.id)
                }
                .listStyle(.inset(alternatesRowBackgrounds: true))
            }
        }
        .navigationTitle(selectedCategory == .all ? "All tasks" : selectedCategory.title)
    }

    private func workflowRow(_ wf: EngineBridge.WorkflowSummary) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(wf.name)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(2)
                if wf.seeded {
                    Image(systemName: "sparkles")
                        .font(.caption2)
                        .foregroundStyle(.yellow)
                        .help("Curated workflow")
                }
            }
            HStack(spacing: 8) {
                Label("\(wf.steps) step\(wf.steps == 1 ? "" : "s")", systemImage: "list.number")
                if wf.category != selectedCategory.rawValue, selectedCategory == .all {
                    Text(WorkflowCategory.from(raw: wf.category).title)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(.quaternary, in: Capsule())
                }
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }

    // MARK: - Detail

    @ViewBuilder
    private var detailPane: some View {
        if let wf = selectedWorkflow {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    detailHeader(wf)
                    detailActions(wf)
                    detailMeta(wf)
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            ContentUnavailableView(
                "Select a task",
                systemImage: "hand.tap",
                description: Text("Pick a workflow from the list to run it or inspect its MDP graph.")
            )
        }
    }

    private func detailHeader(_ wf: EngineBridge.WorkflowSummary) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: WorkflowCategory.from(raw: wf.category).icon)
                    .font(.title2)
                    .foregroundStyle(WorkflowCategory.from(raw: wf.category).tint)
                    .frame(width: 40, height: 40)
                    .background(WorkflowCategory.from(raw: wf.category).tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text(wf.name)
                        .font(.title3.weight(.semibold))
                    Text(WorkflowCategory.from(raw: wf.category).title)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            Text(wf.id)
                .font(.caption.monospaced())
                .foregroundStyle(.tertiary)
                .textSelection(.enabled)
        }
    }

    private func detailActions(_ wf: EngineBridge.WorkflowSummary) -> some View {
        HStack(spacing: 10) {
            Button {
                runWorkflow(wf)
            } label: {
                Label("Run in tab", systemImage: "play.fill")
            }
            .buttonStyle(.borderedProminent)
            .disabled(workflows.isExecuting || !engine.isConnected)

            Button {
                graphWorkflowId = wf.id
            } label: {
                Label("View graph", systemImage: "point.3.connected.trianglepath.dotted")
            }
            .buttonStyle(.bordered)
        }
    }

    private func detailMeta(_ wf: EngineBridge.WorkflowSummary) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            LabeledContent("Steps") {
                Text("\(wf.steps)")
                    .font(.body.monospaced())
            }
            if !wf.tags.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Tags")
                        .font(.subheadline.weight(.semibold))
                    FlowLayoutTags(tags: wf.tags)
                }
            }
            Text(wf.seeded ? "Curated replay workflow — zero-token when state matches." : "Recorded from a browsing session.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func count(for category: WorkflowCategory) -> Int {
        if category == .all {
            return engine.workflows.filter { !$0.id.hasSuffix("_policy") }.count
        }
        return grouped[category]?.count ?? 0
    }

    private func runWorkflow(_ wf: EngineBridge.WorkflowSummary) {
        guard let tab = browserManager.currentTab(for: windowState) else {
            workflows.lastError = "Select a tab first"
            WorkflowManager.postToast(workflows.lastError ?? "", isError: true)
            return
        }
        guard let webView = browserManager.ensureWebView(for: tab.id, in: windowState.id) else {
            workflows.lastError = "Could not prepare browser tab"
            WorkflowManager.postToast(workflows.lastError ?? "", isError: true)
            return
        }
        tab.isOpenHiveNewTab = false
        tab.openHiveWorkflowCatalog = false
        tab.openHiveGraphWorkflowId = nil
        // Mark active so the webview (not the landing) stays visible for the whole
        // run, including the flight page-prepare wait before the trajectory starts.
        TaskRunState.shared.activeTabId = tab.id
        browserManager.selectTab(tab, in: windowState)
        browserManager.refreshCompositor(for: windowState)

        if wf.category == "travel", wf.id.hasPrefix("flight_") || wf.id == FlightDemoRouter.demoSkillId {
            let route = parseFlightRoute(from: wf)
            AgentExecutionState.shared.begin(label: "Running \(wf.name)", tier: 1)
            Task { @MainActor in
                await prepareFlightPage(webView: webView)
                engine.startFlightDemoReplay(
                    route: route,
                    webView: webView,
                    tabId: tab.id,
                    windowId: windowState.id,
                    browserManager: browserManager
                )
            }
            return
        }

        AgentExecutionState.shared.begin(label: "Running \(wf.name)", tier: 1)
        workflows.execute(
            workflowId: wf.id,
            webView: webView,
            tabId: tab.id,
            windowId: windowState.id,
            browserManager: browserManager
        )
    }

    private func parseFlightRoute(from wf: EngineBridge.WorkflowSummary) -> FlightRoute {
        if wf.id == FlightDemoRouter.demoSkillId {
            return FlightDemoRouter.defaultRoute
        }
        let parts = wf.id.split(separator: "_")
        if parts.count >= 3, parts[0] == "flight" {
            let origin = String(parts[1]).uppercased()
            let dest = String(parts[2]).uppercased()
            return FlightRoute(origin: origin, destination: dest, departDate: FlightDemoRouter.departDate)
        }
        return FlightDemoRouter.parseRoute(from: wf.name)
    }

    private func prepareFlightPage(webView: WKWebView) async {
        let flightsURL = URL(string: FlightDemoRouter.startURL)!
        if webView.url?.absoluteString.contains("travel/flights") != true {
            webView.load(URLRequest(url: flightsURL))
        }
        var formReady = false
        for _ in 0..<60 {
            let url = webView.url?.absoluteString ?? ""
            if url.contains("travel/flights") {
                let hasForm = try? await webView.evaluateJavaScript(
                    "document.body && document.body.innerText.toLowerCase().includes('where from')"
                ) as? Bool
                if hasForm == true { formReady = true; break }
            }
            try? await Task.sleep(nanoseconds: 120_000_000)
        }
        try? await Task.sleep(nanoseconds: (formReady ? 300 : 1_200) * 1_000_000)
        OpenHiveObservation.inject(into: webView)
        await OpenHiveObservation.installAgentAutomation(on: webView)
    }
}

// MARK: - Category model

enum WorkflowCategory: String, CaseIterable, Identifiable, Hashable {
    case all
    case search
    case dev
    case travel
    case local
    case video
    case shopping
    case reference
    case news
    case research
    case jobs
    case entertainment
    case recorded
    case other

    var id: String { rawValue }

    static var sidebarOrder: [WorkflowCategory] {
        [.all, .search, .dev, .travel, .local, .video, .shopping, .reference, .news, .research, .jobs, .entertainment, .recorded, .other]
    }

    static func from(raw: String) -> WorkflowCategory {
        WorkflowCategory(rawValue: raw.lowercased()) ?? .other
    }

    var title: String {
        switch self {
        case .all: return "All"
        case .search: return "Search"
        case .dev: return "Developer"
        case .travel: return "Travel"
        case .local: return "Local"
        case .video: return "Video"
        case .shopping: return "Shopping"
        case .reference: return "Reference"
        case .news: return "News"
        case .research: return "Research"
        case .jobs: return "Jobs"
        case .entertainment: return "Entertainment"
        case .recorded: return "Recorded"
        case .other: return "Other"
        }
    }

    var icon: String {
        switch self {
        case .all: return "square.grid.2x2"
        case .search: return "magnifyingglass"
        case .dev: return "chevron.left.forwardslash.chevron.right"
        case .travel: return "airplane"
        case .local: return "map"
        case .video: return "play.rectangle"
        case .shopping: return "cart"
        case .reference: return "book"
        case .news: return "newspaper"
        case .research: return "graduationcap"
        case .jobs: return "briefcase"
        case .entertainment: return "film"
        case .recorded: return "record.circle"
        case .other: return "folder"
        }
    }

    var tint: Color {
        switch self {
        case .all: return .primary
        case .search: return .blue
        case .dev: return .purple
        case .travel: return .orange
        case .local: return .green
        case .video: return .red
        case .shopping: return .yellow
        case .reference: return .indigo
        case .news: return .cyan
        case .research: return .mint
        case .jobs: return .brown
        case .entertainment: return .pink
        case .recorded: return .secondary
        case .other: return .gray
        }
    }
}

// MARK: - Tags layout

private struct FlowLayoutTags: View {
    let tags: [String]

    var body: some View {
        HStack(spacing: 6) {
            ForEach(tags.prefix(8), id: \.self) { tag in
                Text(tag)
                    .font(.caption2)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(.quaternary, in: Capsule())
            }
        }
    }
}
