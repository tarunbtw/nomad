//
//  DevDrawerView.swift
//  nomad
//
//  Created by tarun on 12/10/26.
//

import SwiftUI
import AppKit
import WebKit

/// Minimalist DevX Drawer providing live Element Inspection, Console with JS REPL,
/// and live Agent Perception testing (Dense Semantic Tree & Vision Grounding).
struct DevDrawerView: View {
    @ObservedObject var tab: Tab
    @ObservedObject var store: BrowserStore
    @StateObject private var agentServer = NomadAgentServer.shared

    @AppStorage("nomad.devDrawer.height") private var drawerHeight: Double = 270
    @State private var dragStartHeight: Double = 270
    @State private var isDragging: Bool = false

    @State private var selectedTab: DevTab = .inspect
    @State private var replInput: String = ""
    @State private var consoleFilter: ConsoleFilter = .all
    @State private var networkFilter: NetworkFilter = .all
    @State private var networkSearch: String = ""
    @State private var selectedNetworkEntry: NetworkEntry? = nil
    @State private var snapshotPreview: String? = nil
    @State private var screenshotPreview: NSImage? = nil
    @State private var isCapturingAgentData: Bool = false

    enum DevTab: String, CaseIterable, Identifiable {
        case inspect = "Inspect"
        case console = "Console"
        case network = "Network"
        case agent = "Agent"

        var id: String { rawValue }

        var icon: String {
            switch self {
            case .inspect: return "viewfinder"
            case .console: return "terminal"
            case .network: return "arrow.triangle.swap"
            case .agent: return "cpu"
            }
        }
    }

    enum ConsoleFilter: String, CaseIterable {
        case all = "All"
        case logs = "Logs"
        case warnings = "Warn"
        case errors = "Errors"
    }

    enum NetworkFilter: String, CaseIterable {
        case all = "All"
        case fetch = "Fetch"
        case xhr = "XHR"
        case errors = "Errors"
    }

    var body: some View {
        VStack(spacing: 0) {
            // Drag handle for smooth vertical resizing
            resizeHandle

            // Header Bar
            headerBar
                .padding(.horizontal, 12)
                .frame(height: 34)
                .background(Color(nsColor: .windowBackgroundColor).opacity(0.95))

            Divider().opacity(0.12)

            // Content Area
            Group {
                switch selectedTab {
                case .inspect:
                    inspectTabView
                case .console:
                    consoleTabView
                case .network:
                    networkTabView
                case .agent:
                    agentTabView
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: .textBackgroundColor).opacity(0.45))
        }
        .frame(height: max(160, min(drawerHeight, 650)))
    }

    // MARK: - Vertical Resize Handle

    private var resizeHandle: some View {
        ZStack {
            Rectangle()
                .fill(Color.clear)
                .frame(height: 5)

            Capsule()
                .fill(Color.primary.opacity(isDragging ? 0.35 : 0.12))
                .frame(width: 36, height: 3)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 5)
        .background(Color(nsColor: .windowBackgroundColor).opacity(0.95))
        .contentShape(Rectangle())
        .onHover { inside in
            if inside {
                NSCursor.resizeUpDown.push()
            } else {
                NSCursor.pop()
            }
        }
        .gesture(
            DragGesture(minimumDistance: 1, coordinateSpace: .global)
                .onChanged { value in
                    isDragging = true
                    let newH = dragStartHeight - value.translation.height
                    drawerHeight = max(160, min(newH, 650))
                }
                .onEnded { _ in
                    isDragging = false
                    dragStartHeight = drawerHeight
                }
        )
        .onAppear {
            dragStartHeight = drawerHeight
        }
    }

    // MARK: - Header Bar

    private var headerBar: some View {
        HStack(spacing: 12) {
            // Tab Selector
            HStack(spacing: 2) {
                ForEach(DevTab.allCases) { tabOption in
                    Button(action: { selectedTab = tabOption }) {
                        HStack(spacing: 5) {
                            Image(systemName: tabOption.icon)
                                .font(.system(size: 10, weight: .medium))

                            Text(tabOption.rawValue)
                                .font(.system(size: 11, weight: selectedTab == tabOption ? .semibold : .regular))

                            if tabOption == .console {
                                let errorCount = tab.consoleEntries.filter { $0.level == .error }.count
                                if errorCount > 0 {
                                    Text("\(errorCount)")
                                        .font(.system(size: 9, weight: .bold))
                                        .foregroundStyle(.white)
                                        .padding(.horizontal, 4)
                                        .padding(.vertical, 1)
                                        .background(Color.red, in: Capsule())
                                }
                            } else if tabOption == .network {
                                let errorCount = tab.networkEntries.filter { $0.isError }.count
                                if errorCount > 0 {
                                    Text("\(errorCount)")
                                        .font(.system(size: 9, weight: .bold))
                                        .foregroundStyle(.white)
                                        .padding(.horizontal, 4)
                                        .padding(.vertical, 1)
                                        .background(Color.red, in: Capsule())
                                }
                            }
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(
                            selectedTab == tabOption ? Color.primary.opacity(0.08) : Color.clear,
                            in: RoundedRectangle(cornerRadius: 5, style: .continuous)
                        )
                        .foregroundStyle(selectedTab == tabOption ? Color.primary : Color.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }

            Spacer()

            // Safari Web Inspector bridge (zero overhead native fallback)
            Button(action: {
                tab.webView.evaluateJavaScript("console.log('Opened from Nomad DevTools');", completionHandler: nil)
            }) {
                HStack(spacing: 4) {
                    Image(systemName: "safari")
                        .font(.system(size: 10))
                    Text("Web Inspector")
                        .font(.system(size: 10))
                }
                .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Right-click any element on the page and select 'Inspect Element' to use the full Safari Web Inspector")

            // Close Drawer
            Button(action: {
                withAnimation(.spring(response: 0.28, dampingFraction: 0.85)) {
                    tab.isDevDrawerVisible = false
                }
            }) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Close Developer Tools (⌘⌥I)")
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            withAnimation(.spring(response: 0.28, dampingFraction: 0.82)) {
                drawerHeight = (drawerHeight > 320) ? 240 : 460
                dragStartHeight = drawerHeight
            }
        }
    }

    // MARK: - Inspect Tab

    private var inspectTabView: some View {
        VStack(spacing: 0) {
            // Inspector Toolbar
            HStack(spacing: 10) {
                Button(action: { tab.startElementInspector() }) {
                    HStack(spacing: 5) {
                        Image(systemName: tab.isInspectorActive ? "viewfinder.circle.fill" : "viewfinder")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(tab.isInspectorActive ? Color.accentColor : Color.primary)
                        Text(tab.isInspectorActive ? "Inspecting (Click element)..." : "Pick Element")
                            .font(.system(size: 11, weight: .medium))
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(tab.isInspectorActive ? Color.accentColor.opacity(0.12) : Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 5))
                }
                .buttonStyle(.plain)
                .help("Hover over page elements and click to inspect")

                if let info = tab.inspectedElementInfo {
                    Text(info.selector)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)

                    Spacer()

                    Button("Highlight") {
                        tab.highlightInspectedElement()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.mini)

                    Button("Copy Selector") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(info.selector, forType: .string)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
                } else {
                    Spacer()
                    Text("Select an element from the page to inspect its structure.")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Color.primary.opacity(0.02))

            Divider().opacity(0.08)

            // Inspector Detail Card
            if let info = tab.inspectedElementInfo {
                ScrollView(.vertical, showsIndicators: true) {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 16) {
                            detailPill(label: "Tag", value: "<" + info.tag + ">")
                            if !info.idAttr.isEmpty {
                                detailPill(label: "ID", value: "#" + info.idAttr)
                            }
                            detailPill(label: "Size", value: "\(info.width) × \(info.height) px")
                            if let agentId = info.agentId {
                                detailPill(label: "Agent Ref", value: "[" + agentId + "]", isAccent: true)
                            }
                        }

                        if !info.classes.isEmpty {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Classes:")
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundStyle(.secondary)
                                Text(info.classes)
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundStyle(.primary)
                            }
                        }

                        if !info.text.isEmpty {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Inner Text:")
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundStyle(.secondary)
                                Text(info.text)
                                    .font(.system(size: 11))
                                    .foregroundStyle(.primary)
                                    .lineLimit(3)
                            }
                        }
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                VStack(spacing: 8) {
                    Spacer()
                    Image(systemName: "viewfinder")
                        .font(.system(size: 24))
                        .foregroundStyle(.tertiary)
                    Text("Click 'Pick Element' above to inspect live DOM nodes and attributes.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            }
        }
    }

    private func detailPill(label: String, value: String, isAccent: Bool = false) -> some View {
        HStack(spacing: 4) {
            Text(label + ":")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(isAccent ? Color.accentColor : Color.primary)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 4))
    }

    // MARK: - Console Tab

    private var consoleTabView: some View {
        VStack(spacing: 0) {
            // Console Toolbar
            HStack(spacing: 8) {
                ForEach(ConsoleFilter.allCases, id: \.self) { filter in
                    Button(action: { consoleFilter = filter }) {
                        Text(filter.rawValue)
                            .font(.system(size: 10, weight: consoleFilter == filter ? .semibold : .regular))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(consoleFilter == filter ? Color.primary.opacity(0.1) : Color.clear, in: Capsule())
                            .foregroundStyle(consoleFilter == filter ? Color.primary : Color.secondary)
                    }
                    .buttonStyle(.plain)
                }

                Spacer()

                Button("Clear") {
                    tab.consoleEntries.removeAll()
                }
                .font(.system(size: 10))
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
            .background(Color.primary.opacity(0.02))

            Divider().opacity(0.08)

            // Console Logs Stream
            ScrollViewReader { proxy in
                ScrollView(.vertical, showsIndicators: true) {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(filteredConsoleEntries) { entry in
                            HStack(alignment: .top, spacing: 6) {
                                Image(systemName: consoleIcon(for: entry.level))
                                    .font(.system(size: 9))
                                    .foregroundStyle(consoleColor(for: entry.level))
                                    .frame(width: 12, height: 14)

                                Text(entry.message)
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundStyle(entry.level == .error ? Color.red : (entry.level == .warn ? Color.orange : Color.primary))
                                    .lineLimit(4)

                                Spacer()
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 3)
                            .id(entry.id)
                        }
                    }
                    .padding(.vertical, 4)
                }
                .onChange(of: tab.consoleEntries.count) { _, _ in
                    if let last = tab.consoleEntries.last {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }

            Divider().opacity(0.12)

            // REPL Input Bar
            HStack(spacing: 6) {
                Text(">")
                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                    .foregroundStyle(Color.accentColor)

                TextField("Evaluate JavaScript in active tab...", text: $replInput)
                    .textFieldStyle(.plain)
                    .font(.system(size: 11, design: .monospaced))
                    .onSubmit {
                        submitREPL()
                    }

                Button("Run") {
                    submitREPL()
                }
                .buttonStyle(.bordered)
                .controlSize(.mini)
                .disabled(replInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color(nsColor: .windowBackgroundColor).opacity(0.8))
        }
    }

    private var filteredConsoleEntries: [ConsoleEntry] {
        switch consoleFilter {
        case .all: return tab.consoleEntries
        case .logs: return tab.consoleEntries.filter { $0.level == .log || $0.level == .info }
        case .warnings: return tab.consoleEntries.filter { $0.level == .warn }
        case .errors: return tab.consoleEntries.filter { $0.level == .error }
        }
    }

    private func consoleIcon(for level: ConsoleEntry.Level) -> String {
        switch level {
        case .log: return "circle.fill"
        case .info: return "info.circle.fill"
        case .warn: return "exclamationmark.triangle.fill"
        case .error: return "xmark.circle.fill"
        }
    }

    private func consoleColor(for level: ConsoleEntry.Level) -> Color {
        switch level {
        case .log: return .secondary.opacity(0.6)
        case .info: return .blue
        case .warn: return .orange
        case .error: return .red
        }
    }

    private func submitREPL() {
        let code = replInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !code.isEmpty else { return }
        replInput = ""
        Task {
            tab.appendConsoleEntry(level: .info, message: "> " + code)
            do {
                let result = try await tab.webView.evaluateJavaScript(code)
                tab.appendConsoleEntry(level: .log, message: "< " + String(describing: result ?? "undefined"))
            } catch {
                tab.appendConsoleEntry(level: .error, message: error.localizedDescription)
            }
        }
    }

    // MARK: - Agent Tab (Live Perception & Vision Grounding)

    private var agentTabView: some View {
        ScrollView(.vertical, showsIndicators: true) {
            VStack(alignment: .leading, spacing: 12) {
                // Server Status Card
                HStack(spacing: 8) {
                    Circle()
                        .fill(agentServer.isRunning ? Color.green : Color.red)
                        .frame(width: 8, height: 8)

                    Text(agentServer.isRunning ? "Agent Server Active" : "Agent Server Inactive")
                        .font(.system(size: 11, weight: .semibold))

                    Text("http://127.0.0.1:\(agentServer.port)")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)

                    Spacer()

                    Text("\(agentServer.requestCount) requests served")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                .padding(8)
                .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 6))

                // Actions
                HStack(spacing: 10) {
                    Button("Capture Semantic Tree") {
                        captureSemanticTree()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)

                    Button("Take Labeled Screenshot") {
                        captureLabeledScreenshot()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)

                    if isCapturingAgentData {
                        ProgressView().controlSize(.small)
                    }

                    Spacer()
                }

                // Semantic Tree or Screenshot Preview
                if let summary = snapshotPreview {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Dense Semantic Tree for LLMs (~300 tokens):")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.secondary)

                        Text(summary)
                            .font(.system(size: 10.5, design: .monospaced))
                            .foregroundStyle(.primary)
                            .padding(8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: 6))
                    }
                }

                if let img = screenshotPreview {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Vision Grounded Screenshot with Element Badges:")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.secondary)

                        Image(nsImage: img)
                            .resizable()
                            .scaledToFit()
                            .frame(maxHeight: 180)
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.primary.opacity(0.1), lineWidth: 1))
                    }
                }
            }
            .padding(12)
        }
    }

    private func captureSemanticTree() {
        isCapturingAgentData = true
        Task {
            do {
                let snapshot = try await tab.getSemanticTree()
                self.snapshotPreview = snapshot.summary
            } catch {
                self.snapshotPreview = "Error: \(error.localizedDescription)"
            }
            self.isCapturingAgentData = false
        }
    }

    private func captureLabeledScreenshot() {
        isCapturingAgentData = true
        Task {
            do {
                let img = try await tab.captureScreenshot(labeled: true)
                self.screenshotPreview = img
            } catch {
                print("⚠️ Screenshot failed: \(error)")
            }
            self.isCapturingAgentData = false
        }
    }

    // MARK: - Network Tab Views

    private var filteredNetworkEntries: [NetworkEntry] {
        var list = tab.networkEntries
        switch networkFilter {
        case .all: break
        case .fetch: list = list.filter { $0.type == "fetch" }
        case .xhr: list = list.filter { $0.type == "xhr" }
        case .errors: list = list.filter { $0.isError }
        }
        let q = networkSearch.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if !q.isEmpty {
            list = list.filter { $0.url.lowercased().contains(q) || $0.method.lowercased().contains(q) }
        }
        return list
    }

    private var networkTabView: some View {
        VStack(spacing: 0) {
            // Network Toolbar
            HStack(spacing: 8) {
                ForEach(NetworkFilter.allCases, id: \.self) { filter in
                    Button(action: { networkFilter = filter }) {
                        Text(filter.rawValue)
                            .font(.system(size: 10, weight: networkFilter == filter ? .semibold : .regular))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(networkFilter == filter ? Color.primary.opacity(0.1) : Color.clear, in: Capsule())
                            .foregroundStyle(networkFilter == filter ? Color.primary : Color.secondary)
                    }
                    .buttonStyle(.plain)
                }

                // Search Filter
                HStack(spacing: 4) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                    TextField("Filter URL...", text: $networkSearch)
                        .textFieldStyle(.plain)
                        .font(.system(size: 10))
                        .frame(width: 140)
                    if !networkSearch.isEmpty {
                        Button(action: { networkSearch = "" }) {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 9))
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 4))

                Spacer()

                Text("\(tab.networkEntries.count) requests")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)

                Button("Clear") {
                    tab.networkEntries.removeAll()
                    selectedNetworkEntry = nil
                }
                .font(.system(size: 10))
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
            .background(Color.primary.opacity(0.02))

            Divider().opacity(0.08)

            // Content Split View
            if tab.networkEntries.isEmpty {
                VStack(spacing: 8) {
                    Spacer()
                    Image(systemName: "arrow.triangle.swap")
                        .font(.system(size: 24))
                        .foregroundStyle(.tertiary)
                    Text("No network requests recorded.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Text("Perform fetch() or XMLHttpRequest calls on the page to inspect network traffic.")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                HStack(spacing: 0) {
                    // Requests List
                    networkListView
                        .frame(maxWidth: .infinity)

                    // Detail Inspector Pane (if a request is selected)
                    if let entry = selectedNetworkEntry {
                        Divider().opacity(0.12)
                        networkDetailView(entry: entry)
                            .frame(width: 280)
                            .transition(.move(edge: .trailing))
                    }
                }
            }
        }
    }

    private var networkListView: some View {
        VStack(spacing: 0) {
            // Table Header
            HStack(spacing: 8) {
                Text("Status")
                    .frame(width: 48, alignment: .leading)
                Text("Method")
                    .frame(width: 46, alignment: .leading)
                Text("Resource / URL")
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text("Type")
                    .frame(width: 42, alignment: .trailing)
                Text("Time")
                    .frame(width: 50, alignment: .trailing)
            }
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 3)
            .background(Color.primary.opacity(0.02))

            Divider().opacity(0.06)

            // Table Rows
            ScrollView(.vertical, showsIndicators: true) {
                LazyVStack(spacing: 1) {
                    ForEach(filteredNetworkEntries) { entry in
                        let isSelected = selectedNetworkEntry?.id == entry.id
                        Button(action: {
                            if selectedNetworkEntry?.id == entry.id {
                                selectedNetworkEntry = nil
                            } else {
                                selectedNetworkEntry = entry
                            }
                        }) {
                            HStack(spacing: 8) {
                                // Status badge
                                Text(entry.status == 0 ? "Fail" : "\(entry.status)")
                                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                                    .foregroundStyle(statusColor(for: entry.status))
                                    .frame(width: 48, alignment: .leading)

                                // Method badge
                                Text(entry.method)
                                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                                    .foregroundStyle(Color.primary.opacity(0.8))
                                    .frame(width: 46, alignment: .leading)

                                // Path / resource
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(urlDisplayName(for: entry.url))
                                        .font(.system(size: 11, design: .monospaced))
                                        .foregroundStyle(entry.isError ? Color.red : Color.primary)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)

                                // Type badge
                                Text(entry.type.uppercased())
                                    .font(.system(size: 9, weight: .medium))
                                    .foregroundStyle(.secondary)
                                    .frame(width: 42, alignment: .trailing)

                                // Duration
                                Text("\(entry.durationMs)ms")
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                    .frame(width: 50, alignment: .trailing)
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 3)
                            .background(
                                isSelected ? Color.accentColor.opacity(0.12) : Color.clear,
                                in: RoundedRectangle(cornerRadius: 3)
                            )
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.vertical, 2)
            }
        }
    }

    private func networkDetailView(entry: NetworkEntry) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            // Header
            HStack {
                Text("Request Details")
                    .font(.system(size: 11, weight: .semibold))

                Spacer()

                Button(action: { selectedNetworkEntry = nil }) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }

            Divider().opacity(0.08)

            ScrollView(.vertical, showsIndicators: true) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        Text(entry.method)
                            .font(.system(size: 11, weight: .bold, design: .monospaced))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 4))

                        Text(entry.status == 0 ? "Failed" : "\(entry.status)")
                            .font(.system(size: 11, weight: .bold, design: .monospaced))
                            .foregroundStyle(statusColor(for: entry.status))

                        Spacer()

                        Text("\(entry.durationMs) ms")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }

                    // URL
                    VStack(alignment: .leading, spacing: 3) {
                        Text("URL:")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.secondary)

                        Text(entry.url)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.primary)
                            .textSelection(.enabled)
                            .lineLimit(4)
                    }

                    // Action buttons
                    HStack(spacing: 6) {
                        Button("Copy URL") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(entry.url, forType: .string)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.mini)

                        Button("Copy as cURL") {
                            let curl = "curl -X \(entry.method) '\(entry.url)'"
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(curl, forType: .string)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.mini)
                    }

                    if let err = entry.error {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Error:")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(.red)
                            Text(err)
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(.red)
                        }
                        .padding(6)
                        .background(Color.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 4))
                    }
                }
                .padding(.trailing, 8)
            }
        }
        .padding(10)
        .background(Color(nsColor: .windowBackgroundColor).opacity(0.85))
    }

    private func statusColor(for status: Int) -> Color {
        if status >= 200 && status < 300 {
            return .green
        } else if status >= 300 && status < 400 {
            return .blue
        } else if status >= 400 && status < 600 {
            return .red
        } else if status == 0 {
            return .red
        }
        return .secondary
    }

    private func urlDisplayName(for urlStr: String) -> String {
        guard let url = URL(string: urlStr) else { return urlStr }
        let path = url.path
        if !path.isEmpty && path != "/" {
            let last = url.lastPathComponent
            return last.isEmpty ? path : (url.query != nil ? "\(last)?\(url.query!)" : last)
        }
        return url.host ?? urlStr
    }
}
