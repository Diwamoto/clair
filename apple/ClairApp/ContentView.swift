import AppKit
import SwiftUI

struct ContentView: View {
  let state: BootstrapState
  @ObservedObject var workspace: ProjectWorkspaceModel

  @State private var renameProjectID: UUID?
  @State private var renameValue = ""

  var body: some View {
    NavigationSplitView {
      projectSidebar
    } detail: {
      projectDetail
    }
    .frame(minWidth: 820, minHeight: 520)
    .alert("Rename Project", isPresented: renameAlertIsPresented) {
      TextField("Project name", text: $renameValue)
      Button("Cancel", role: .cancel) {
        cancelRename()
      }
      Button("Rename") {
        confirmRename()
      }
    } message: {
      Text("This changes the name shown by Clair, not the folder on disk.")
    }
    .alert("Project command failed", isPresented: errorAlertIsPresented) {
      Button("OK") {
        workspace.dismissError()
      }
    } message: {
      Text(workspace.lastErrorMessage ?? "Unknown Project error.")
    }
  }

  private var projectSidebar: some View {
    VStack(spacing: 0) {
      HStack {
        Text("Projects")
          .font(.headline)
        Spacer()
        Button(action: openProject) {
          Label("Open Folder", systemImage: "folder.badge.plus")
        }
        .labelStyle(.iconOnly)
        .help("Open Project Folder")
        .keyboardShortcut("o", modifiers: [.command])
      }
      .padding(.horizontal, 12)
      .padding(.vertical, 10)

      if workspace.projects.isEmpty {
        ContentUnavailableView(
          "No Projects",
          systemImage: "folder",
          description: Text("Open a local folder to start a Project.")
        )
      } else {
        List(
          selection: Binding(
            get: { workspace.activeProjectID },
            set: { projectID in
              guard let projectID else { return }
              _ = workspace.execute(
                .switchProject(SwitchProjectCommand(projectID: projectID))
              )
            }
          )
        ) {
          ForEach(workspace.projects) { project in
            projectRow(project)
              .tag(project.id)
          }
        }
        .listStyle(.sidebar)
      }
    }
  }

  private func projectRow(_ project: Project) -> some View {
    HStack(spacing: 9) {
      Circle()
        .fill(project.color.swiftUIColor)
        .frame(width: 9, height: 9)

      VStack(alignment: .leading, spacing: 2) {
        Text(project.name)
          .lineLimit(1)
        Text(project.rootURL.path)
          .font(.caption2)
          .foregroundStyle(.secondary)
          .lineLimit(1)
      }

      Spacer(minLength: 0)

      if !project.availability.isAvailable {
        Image(systemName: "exclamationmark.triangle.fill")
          .foregroundStyle(.orange)
          .help(project.availability.displayName)
      }
    }
    .contextMenu {
      Button("Rename…") {
        beginRename(project)
      }

      Menu("Color") {
        ForEach(ProjectColor.allCases, id: \.self) { color in
          Button {
            _ = workspace.execute(
              .setProjectColor(
                SetProjectColorCommand(projectID: project.id, color: color)
              )
            )
          } label: {
            HStack {
              Circle()
                .fill(color.swiftUIColor)
                .frame(width: 9, height: 9)
              Text(color.displayName)
              if color == project.color {
                Image(systemName: "checkmark")
              }
            }
          }
        }
      }

      Divider()

      Button("Move Up") {
        workspace.moveProject(id: project.id, by: -1)
      }
      Button("Move Down") {
        workspace.moveProject(id: project.id, by: 1)
      }
      Button("Close Project", role: .destructive) {
        _ = workspace.execute(
          .closeProject(CloseProjectCommand(projectID: project.id))
        )
      }
    }
  }

  @ViewBuilder
  private var projectDetail: some View {
    if let project = workspace.activeProject, let surface = workspace.activeSurface {
      ProjectWorkspaceDetail(state: state, project: project, surface: surface)
    } else {
      VStack(spacing: 12) {
        Image(systemName: "folder.badge.plus")
          .font(.system(size: 42))
          .foregroundStyle(.secondary)
        Text("Open a Project folder")
          .font(.title2.weight(.semibold))
        Text("Git repositories and ordinary local folders are supported.")
          .foregroundStyle(.secondary)
        Button("Open Folder…", action: openProject)
          .keyboardShortcut("o", modifiers: [.command])
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .padding(32)
    }
  }

  private var renameAlertIsPresented: Binding<Bool> {
    Binding(
      get: { renameProjectID != nil },
      set: { isPresented in
        if !isPresented {
          cancelRename()
        }
      }
    )
  }

  private var errorAlertIsPresented: Binding<Bool> {
    Binding(
      get: { workspace.lastErrorMessage != nil },
      set: { isPresented in
        if !isPresented {
          workspace.dismissError()
        }
      }
    )
  }

  private func openProject() {
    let panel = NSOpenPanel()
    panel.canChooseFiles = false
    panel.canChooseDirectories = true
    panel.allowsMultipleSelection = false
    panel.prompt = "Open Project"

    guard panel.runModal() == .OK, let url = panel.url else {
      return
    }

    _ = workspace.execute(.openProject(OpenProjectCommand(rootURL: url)))
  }

  private func beginRename(_ project: Project) {
    renameProjectID = project.id
    renameValue = project.name
  }

  private func cancelRename() {
    renameProjectID = nil
    renameValue = ""
  }

  private func confirmRename() {
    guard let projectID = renameProjectID else {
      return
    }
    _ = workspace.execute(
      .renameProject(
        RenameProjectCommand(projectID: projectID, name: renameValue)
      )
    )
    cancelRename()
  }

}

private enum ProjectNavigationSheet: String, Identifiable {
  case quickOpen
  case search
  case history

  var id: String {
    rawValue
  }
}

private struct ProjectWorkspaceDetail: View {
  let state: BootstrapState
  let project: Project
  @ObservedObject var surface: ProjectSurfaceModel
  @State private var navigationSheet: ProjectNavigationSheet?

  var body: some View {
    VStack(spacing: 0) {
      HStack(spacing: 12) {
        Image(systemName: "folder.fill")
          .font(.title2.weight(.semibold))
          .foregroundStyle(project.color.swiftUIColor)

        VStack(alignment: .leading, spacing: 2) {
          Text(project.name)
            .font(.headline)
          Text(project.rootURL.path)
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }

        Spacer()

        Button {
          navigationSheet = .quickOpen
        } label: {
          Label("Quick Open", systemImage: "magnifyingglass")
        }
        .buttonStyle(.bordered)

        Button {
          navigationSheet = .search
        } label: {
          Label("Search", systemImage: "text.magnifyingglass")
        }
        .buttonStyle(.bordered)

        Button {
          navigationSheet = .history
        } label: {
          Label("History", systemImage: "clock.arrow.circlepath")
        }
        .buttonStyle(.bordered)

        Button(surface.isTerminalVisible ? "Show Editor" : "Open Terminal") {
          if surface.isTerminalVisible {
            surface.hideTerminal()
          } else {
            surface.showTerminal()
          }
        }
        .buttonStyle(.bordered)

        Button(surface.isFocusedPaneMaximized ? "Restore Pane" : "Maximize Pane") {
          surface.toggleMaximizeFocusedPane()
        }
        .buttonStyle(.bordered)

        Button("Equalize") {
          surface.equalizeSplits()
        }
        .buttonStyle(.bordered)

        Button("Diff") {
          surface.openDiff()
        }
        .buttonStyle(.bordered)

        Text(surface.fileTree.availability.displayName)
          .font(.caption.weight(.bold))
          .foregroundStyle(surface.fileTree.isAvailable ? .green : .orange)
          .padding(.horizontal, 9)
          .padding(.vertical, 5)
          .background(.quaternary, in: Capsule())
      }
      .padding(.horizontal, 16)
      .padding(.vertical, 12)

      Divider()

      HStack(spacing: 0) {
        ProjectFileTreeView(surface: surface)
          .frame(minWidth: 220, idealWidth: 270, maxWidth: 360)

        Divider()

        ProjectPaneLayoutView(
          state: state,
          project: project,
          surface: surface,
          node: surface.visibleLayout
        )
      }
    }
    .alert("Editor command failed", isPresented: editorErrorIsPresented) {
      Button("OK") {
        surface.dismissEditorError()
      }
    } message: {
      Text(surface.lastEditorErrorMessage ?? "Unknown editor error.")
    }
    .alert("Project navigation failed", isPresented: navigationErrorIsPresented) {
      Button("OK") {
        surface.dismissNavigationError()
      }
    } message: {
      Text(surface.lastNavigationErrorMessage ?? "Unknown navigation error.")
    }
    .sheet(item: $navigationSheet) { sheet in
      switch sheet {
      case .quickOpen:
        ProjectQuickOpenView(surface: surface)
      case .search:
        ProjectSearchView(surface: surface)
      case .history:
        ProjectHistoryView(surface: surface)
      }
    }
  }

  private var editorErrorIsPresented: Binding<Bool> {
    Binding(
      get: { surface.lastEditorErrorMessage != nil },
      set: { isPresented in
        if !isPresented {
          surface.dismissEditorError()
        }
      }
    )
  }

  private var navigationErrorIsPresented: Binding<Bool> {
    Binding(
      get: { surface.lastNavigationErrorMessage != nil },
      set: { isPresented in
        if !isPresented {
          surface.dismissNavigationError()
        }
      }
    )
  }
}

private struct ProjectTerminalPanel: View {
  let project: Project
  @ObservedObject var session: TerminalSession
  let onHide: () -> Void
  let onEnd: () -> Void

  var body: some View {
    VStack(spacing: 0) {
      HStack(spacing: 10) {
        Label("Terminal", systemImage: "terminal")
          .font(.headline)
        Text(project.rootURL.path)
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(1)
        Spacer()
        Text(session.statusDescription)
          .font(.caption)
          .foregroundStyle(statusColor)
        Text("\(session.dimensions.columns) × \(session.dimensions.rows)")
          .font(.caption.monospacedDigit())
          .foregroundStyle(.secondary)
        Button("Editor", action: onHide)
          .buttonStyle(.borderless)
        Button("End", action: onEnd)
          .buttonStyle(.borderless)
          .foregroundStyle(.red)
      }
      .padding(.horizontal, 12)
      .padding(.vertical, 8)

      Divider()

      TerminalSurfaceView(session: session)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .textBackgroundColor))
        .onAppear {
          session.start()
        }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  private var statusColor: Color {
    switch session.state {
    case .running, .starting:
      .green
    case .idle, .stopping:
      .secondary
    case .exited:
      .orange
    case .failed:
      .red
    }
  }
}

private struct ProjectPaneLayoutView: View {
  let state: BootstrapState
  let project: Project
  @ObservedObject var surface: ProjectSurfaceModel
  let node: ProjectPaneNode

  var body: some View {
    nodeView(node)
      .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  private func nodeView(_ node: ProjectPaneNode) -> AnyView {
    switch node {
    case .leaf(let leaf):
      return AnyView(
        ProjectPaneView(
          state: state,
          project: project,
          surface: surface,
          paneID: leaf.id
        )
      )
    case .split(_, let orientation, let ratio, let first, let second):
      return AnyView(
        GeometryReader { proxy in
          let fraction = CGFloat(min(max(ratio, 0.05), 0.95))
          Group {
            if orientation == .horizontal {
              HStack(spacing: 0) {
                nodeView(first)
                  .frame(width: proxy.size.width * fraction)
                Divider()
                nodeView(second)
                  .frame(maxWidth: .infinity, maxHeight: .infinity)
              }
            } else {
              VStack(spacing: 0) {
                nodeView(first)
                  .frame(height: proxy.size.height * fraction)
                Divider()
                nodeView(second)
                  .frame(maxWidth: .infinity, maxHeight: .infinity)
              }
            }
          }
        }
      )
    }
  }
}

private struct ProjectPaneView: View {
  let state: BootstrapState
  let project: Project
  @ObservedObject var surface: ProjectSurfaceModel
  let paneID: UUID

  @State private var pendingCloseTabID: String?

  var body: some View {
    VStack(spacing: 0) {
      paneToolbar
      Divider()
      tabBar
      Divider()
      tabContent
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(.background)
    .overlay {
      RoundedRectangle(cornerRadius: 4)
        .stroke(
          surface.isFocusedPane(paneID) ? Color.accentColor : Color.clear,
          lineWidth: 2
        )
        .allowsHitTesting(false)
    }
    .contentShape(Rectangle())
    .onTapGesture {
      surface.focusPane(id: paneID)
    }
    .alert("Discard unsaved changes?", isPresented: pendingCloseIsPresented) {
      Button("Cancel", role: .cancel) {
        pendingCloseTabID = nil
      }
      Button("Discard", role: .destructive) {
        guard let pendingCloseTabID else {
          return
        }
        self.pendingCloseTabID = nil
        surface.closeTab(id: pendingCloseTabID)
      }
    } message: {
      Text("The editor buffer has changes that have not been saved to disk.")
    }
  }

  private var paneToolbar: some View {
    HStack(spacing: 6) {
      Button(surface.isFocusedPane(paneID) ? "Focused" : "Focus") {
        surface.focusPane(id: paneID)
      }
      .buttonStyle(.borderless)

      Menu("Split") {
        Button("Split Right") {
          surface.focusPane(id: paneID)
          surface.splitFocusedPane(orientation: .horizontal)
        }
        Button("Split Below") {
          surface.focusPane(id: paneID)
          surface.splitFocusedPane(orientation: .vertical)
        }
      }
      .menuStyle(.borderlessButton)

      Menu("Move Tab") {
        if surface.paneIDs.count == 1 {
          Text("No other panes")
        } else {
          ForEach(surface.paneIDs.filter { $0 != paneID }, id: \.self) { destination in
            Button("Pane \(destination.uuidString.prefix(4))") {
              surface.focusPane(id: paneID)
              surface.moveActiveTab(to: destination)
            }
          }
        }
      }
      .menuStyle(.borderlessButton)

      Button(
        surface.isFocusedPaneMaximized && surface.isFocusedPane(paneID) ? "Restore" : "Maximize"
      ) {
        surface.focusPane(id: paneID)
        surface.toggleMaximizeFocusedPane()
      }
      .buttonStyle(.borderless)

      Button("Close Pane", role: .destructive) {
        surface.closePane(id: paneID)
      }
      .buttonStyle(.borderless)
      .disabled(surface.paneIDs.count == 1)

      Spacer(minLength: 4)

      Button("Editor") {
        surface.focusPane(id: paneID)
        surface.hideTerminal()
      }
      .buttonStyle(.borderless)
      Button("Terminal") {
        surface.showTerminal(in: paneID)
      }
      .buttonStyle(.borderless)
      Button("Diff") {
        surface.openDiff(in: paneID)
      }
      .buttonStyle(.borderless)
    }
    .font(.caption)
    .padding(.horizontal, 8)
    .padding(.vertical, 5)
    .background(.background.secondary)
  }

  private var tabBar: some View {
    ScrollView(.horizontal) {
      HStack(spacing: 2) {
        ForEach(surface.tabs(in: paneID)) { tab in
          HStack(spacing: 5) {
            Button(displayTitle(for: tab)) {
              surface.activateTab(id: tab.id)
            }
            .buttonStyle(.plain)
            .lineLimit(1)

            Button {
              requestClose(tab)
            } label: {
              Image(systemName: "xmark")
                .font(.caption2.weight(.bold))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close \(tab.title)")
          }
          .padding(.horizontal, 8)
          .padding(.vertical, 5)
          .background(
            surface.activeTab(in: paneID)?.id == tab.id
              ? Color.accentColor.opacity(0.16)
              : Color.clear,
            in: RoundedRectangle(cornerRadius: 5)
          )
        }
        Spacer(minLength: 0)
      }
      .padding(.horizontal, 6)
      .padding(.vertical, 3)
    }
    .scrollIndicators(.hidden)
    .frame(minHeight: 29)
  }

  @ViewBuilder
  private var tabContent: some View {
    if let tab = surface.activeTab(in: paneID) {
      switch tab.kind {
      case .editor:
        if let document = surface.editorDocument(tabID: tab.id) {
          ProjectNativeEditorTab(tab: document, surface: surface)
        } else {
          ContentUnavailableView(
            "Editor Unavailable",
            systemImage: "doc.text.magnifyingglass",
            description: Text("The file could not be restored in this Project.")
          )
        }
      case .terminal:
        if let session = surface.terminalSession(tabID: tab.id) {
          ProjectTerminalPanel(
            project: project,
            session: session,
            onHide: surface.hideTerminal,
            onEnd: surface.endTerminal
          )
        } else {
          ProjectRestoredTerminalView {
            surface.startTerminal(tabID: tab.id)
          }
        }
      case .diff:
        ProjectDiffPreview()
      }
    } else {
      VStack(spacing: 8) {
        Image(systemName: "rectangle.split.3x1")
          .font(.title2)
          .foregroundStyle(.secondary)
        Text("Empty pane")
          .font(.headline)
        Text("Open an editor, terminal, or diff tab.")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
  }

  private var pendingCloseIsPresented: Binding<Bool> {
    Binding(
      get: { pendingCloseTabID != nil },
      set: { isPresented in
        if !isPresented {
          pendingCloseTabID = nil
        }
      }
    )
  }

  private func displayTitle(for tab: ProjectPaneTab) -> String {
    guard tab.kind == .editor,
      surface.editorDocument(tabID: tab.id)?.isDirty == true
    else {
      return tab.title
    }
    return "\(tab.title) •"
  }

  private func requestClose(_ tab: ProjectPaneTab) {
    if tab.kind == .editor, surface.editorDocument(tabID: tab.id)?.isDirty == true {
      pendingCloseTabID = tab.id
    } else {
      surface.closeTab(id: tab.id)
    }
  }
}

private struct ProjectRestoredTerminalView: View {
  let onStart: () -> Void

  var body: some View {
    VStack(spacing: 12) {
      Image(systemName: "terminal")
        .font(.system(size: 34))
        .foregroundStyle(.secondary)
      Text("Terminal session is not running")
        .font(.headline)
      Text(
        "The terminal layout was restored, but its transcript is intentionally not saved. Start a new local session."
      )
      .font(.caption)
      .foregroundStyle(.secondary)
      .multilineTextAlignment(.center)
      .frame(maxWidth: 420)
      Button("Start Terminal", action: onStart)
        .buttonStyle(.borderedProminent)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .padding(24)
  }
}

private struct ProjectDiffPreview: View {
  var body: some View {
    VStack(spacing: 12) {
      Image(systemName: "doc.on.doc")
        .font(.system(size: 34))
        .foregroundStyle(.secondary)
      Text("Diff preview")
        .font(.headline)
      Text(
        "This pane is ready for Project diffs. Git status and change navigation arrive in the Git working-tree slice."
      )
      .font(.caption)
      .foregroundStyle(.secondary)
      .multilineTextAlignment(.center)
      .frame(maxWidth: 420)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .padding(24)
  }
}

private struct ProjectFileTreeView: View {
  @ObservedObject var surface: ProjectSurfaceModel

  var body: some View {
    VStack(spacing: 0) {
      HStack {
        Label("Files", systemImage: "folder")
          .font(.headline)
        Spacer()
        Button {
          surface.reload()
        } label: {
          Image(systemName: "arrow.clockwise")
        }
        .buttonStyle(.borderless)
        .help("Refresh file tree")
      }
      .padding(.horizontal, 12)
      .padding(.vertical, 9)

      Divider()

      if let root = surface.fileTree.root, surface.fileTree.isAvailable {
        ScrollViewReader { proxy in
          ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
              ProjectFileTreeRow(node: root, surface: surface, depth: 0)
            }
            .padding(.vertical, 4)
          }
          .onChange(of: surface.selectedNodeID, initial: false) { _, nodeID in
            guard let nodeID else { return }
            withAnimation(.easeInOut(duration: 0.15)) {
              proxy.scrollTo(nodeID, anchor: .center)
            }
          }
        }
      } else {
        ContentUnavailableView(
          fileTreeTitle,
          systemImage: fileTreeSystemImage,
          description: Text(fileTreeMessage)
        )
        .padding(16)
      }
    }
    .frame(maxHeight: .infinity)
    .background(.background.secondary)
  }

  private var fileTreeTitle: String {
    switch surface.fileTree.availability {
    case .available:
      "No Files"
    case .missing:
      "Folder Missing"
    case .notDirectory:
      "Not a Folder"
    case .unreadable:
      "Folder Unavailable"
    }
  }

  private var fileTreeSystemImage: String {
    surface.fileTree.availability == .available
      ? "doc"
      : "exclamationmark.triangle"
  }

  private var fileTreeMessage: String {
    switch surface.fileTree.availability {
    case .available:
      "This Project folder is empty."
    case .missing:
      "The folder may have been moved or deleted. Clair will refresh when it returns."
    case .notDirectory:
      "The Project root is no longer a folder."
    case .unreadable:
      "Clair cannot read this Project folder."
    }
  }
}

private struct ProjectQuickOpenView: View {
  @ObservedObject var surface: ProjectSurfaceModel
  @Environment(\.dismiss) private var dismiss
  @State private var query = ""

  var body: some View {
    VStack(spacing: 0) {
      HStack(spacing: 8) {
        Image(systemName: "magnifyingglass")
          .foregroundStyle(.secondary)
        TextField("Search files by name or path", text: $query)
          .textFieldStyle(.roundedBorder)
          .onSubmit {
            openFirstResult()
          }
      }
      .padding(12)

      Divider()

      if items.isEmpty {
        ContentUnavailableView(
          query.isEmpty ? "No Files" : "No Matching Files",
          systemImage: "doc.text.magnifyingglass",
          description: Text(
            query.isEmpty
              ? "This Project has no files to open."
              : "Try a different file name or path."
          )
        )
      } else {
        List(items) { item in
          Button {
            surface.openQuickOpenItem(item)
            if surface.lastNavigationErrorMessage == nil {
              dismiss()
            }
          } label: {
            VStack(alignment: .leading, spacing: 3) {
              Text(item.title)
                .font(.body.weight(.medium))
              Text(item.relativePath)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
          }
          .buttonStyle(.plain)
        }
        .listStyle(.inset)
      }
    }
    .frame(minWidth: 480, minHeight: 360)
  }

  private var items: [ProjectQuickOpenItem] {
    surface.quickOpenItems(matching: query)
  }

  private func openFirstResult() {
    guard let item = items.first else {
      return
    }
    surface.openQuickOpenItem(item)
    if surface.lastNavigationErrorMessage == nil {
      dismiss()
    }
  }
}

private struct ProjectSearchView: View {
  @ObservedObject var surface: ProjectSurfaceModel
  @Environment(\.dismiss) private var dismiss
  @State private var query = ""
  @State private var replacement = ""

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      VStack(spacing: 8) {
        HStack(spacing: 8) {
          Image(systemName: "text.magnifyingglass")
            .foregroundStyle(.secondary)
          TextField("Find text in this Project", text: $query)
            .textFieldStyle(.roundedBorder)
            .onSubmit {
              surface.search(query: query)
            }
        }

        HStack(spacing: 8) {
          TextField("Replace with", text: $replacement)
            .textFieldStyle(.roundedBorder)
          Button("Search") {
            surface.search(query: query)
          }
          .disabled(query.isEmpty)
          Button("Preview Replacement") {
            surface.previewReplacement(query: query, replacement: replacement)
          }
          .disabled(query.isEmpty)
        }

        HStack {
          Text(
            query.isEmpty
              ? "Searches UTF-8 text files and refreshes with the Project watcher."
              : "\(surface.searchResults.count) match\(surface.searchResults.count == 1 ? "" : "es")"
          )
          .font(.caption)
          .foregroundStyle(.secondary)
          Spacer()
          Button("Close", action: dismiss.callAsFunction)
            .buttonStyle(.borderless)
        }
      }
      .padding(12)

      if let status = surface.lastNavigationStatusMessage {
        Label(status, systemImage: "checkmark.circle.fill")
          .font(.caption)
          .foregroundStyle(.green)
          .fixedSize(horizontal: false, vertical: true)
          .padding(.horizontal, 12)
          .padding(.bottom, 8)
      }

      if let preview = surface.replacementPreview {
        GroupBox("Replacement Preview") {
          VStack(alignment: .leading, spacing: 8) {
            Text(
              "\(preview.matchCount) match\(preview.matchCount == 1 ? "" : "es") in \(preview.files.count) file\(preview.files.count == 1 ? "" : "s")"
            )
            .font(.caption.weight(.semibold))

            ForEach(preview.files) { file in
              HStack {
                Text(file.relativePath)
                  .lineLimit(1)
                Spacer()
                Text("\(file.matchCount)")
                  .font(.caption.monospacedDigit())
                  .foregroundStyle(.secondary)
              }
            }

            HStack {
              Spacer()
              Button("Apply to Editor Buffers") {
                surface.applyReplacement(preview)
              }
              .buttonStyle(.borderedProminent)
            }
          }
          .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
      }

      Divider()

      if query.isEmpty {
        ContentUnavailableView(
          "Search This Project",
          systemImage: "text.magnifyingglass",
          description: Text("Enter text above to search and preview replacements.")
        )
      } else if surface.searchResults.isEmpty {
        ContentUnavailableView(
          "No Matches",
          systemImage: "magnifyingglass",
          description: Text("No UTF-8 text file contains that text.")
        )
      } else {
        List(surface.searchResults) { match in
          Button {
            surface.openSearchMatch(match)
            if surface.lastNavigationErrorMessage == nil {
              dismiss()
            }
          } label: {
            VStack(alignment: .leading, spacing: 3) {
              HStack(spacing: 6) {
                Text(match.relativePath)
                  .font(.body.weight(.medium))
                  .lineLimit(1)
                Spacer()
                Text("\(match.line):\(match.column)")
                  .font(.caption.monospacedDigit())
                  .foregroundStyle(.secondary)
              }
              Text(match.lineText)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
          }
          .buttonStyle(.plain)
        }
        .listStyle(.inset)
      }
    }
    .frame(minWidth: 620, minHeight: 440)
    .onChange(of: query, initial: true) { _, newValue in
      surface.search(query: newValue)
    }
  }
}

private struct ProjectHistoryView: View {
  @ObservedObject var surface: ProjectSurfaceModel
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack {
        VStack(alignment: .leading, spacing: 3) {
          Text("Project History")
            .font(.title3.weight(.semibold))
          Text("Restore a snapshot into an editor buffer; Save explicitly to write it to disk.")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        Spacer()
        Button("Close", action: dismiss.callAsFunction)
          .buttonStyle(.borderless)
      }
      .padding(12)

      Divider()

      if surface.historyEntries.isEmpty {
        ContentUnavailableView(
          "No History Snapshots",
          systemImage: "clock.arrow.circlepath",
          description: Text("Clair will keep recovery snapshots when files are saved or reloaded.")
        )
      } else {
        List(surface.historyEntries) { entry in
          HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
              Text(entry.filePath)
                .font(.body.weight(.medium))
                .lineLimit(1)
              Text(entry.displayLabel)
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Restore") {
              surface.restoreHistoryEntry(entry)
              if surface.lastNavigationErrorMessage == nil {
                dismiss()
              }
            }
            .buttonStyle(.bordered)
          }
        }
        .listStyle(.inset)
      }
    }
    .frame(minWidth: 560, minHeight: 360)
    .onAppear {
      surface.refreshHistoryEntries()
    }
  }
}

private struct ProjectFileTreeRow: View {
  let node: ProjectFileTreeNode
  @ObservedObject var surface: ProjectSurfaceModel
  let depth: Int

  var body: some View {
    VStack(spacing: 0) {
      HStack(spacing: 5) {
        if node.isDirectory {
          Button {
            surface.toggleExpansion(for: node.id)
          } label: {
            Image(
              systemName: surface.isExpanded(node.id)
                ? "chevron.down"
                : "chevron.right"
            )
            .font(.caption2.weight(.bold))
            .frame(width: 14, height: 18)
          }
          .buttonStyle(.plain)
        } else {
          Color.clear
            .frame(width: 14, height: 18)
        }

        Image(systemName: node.isDirectory ? "folder" : "doc.text")
          .foregroundStyle(node.isDirectory ? .secondary : .primary)
        Text(node.name)
          .lineLimit(1)
        Spacer(minLength: 0)
      }
      .padding(.leading, CGFloat(depth * 14) + 8)
      .padding(.trailing, 8)
      .padding(.vertical, 3)
      .background(
        surface.selectedNodeID == node.id
          ? Color.accentColor.opacity(0.2)
          : Color.clear
      )
      .contentShape(Rectangle())
      .onTapGesture {
        surface.select(nodeID: node.id)
      }
      .id(node.id)

      if node.isDirectory && surface.isExpanded(node.id) {
        ForEach(node.children ?? []) { child in
          ProjectFileTreeRow(node: child, surface: surface, depth: depth + 1)
        }
      }
    }
  }
}

private struct ProjectEditorTabHost: View {
  let state: BootstrapState
  let project: Project
  @ObservedObject var surface: ProjectSurfaceModel
  @State private var pendingCloseTabID: String?

  var body: some View {
    VStack(spacing: 0) {
      if surface.editorTabs.isEmpty {
        ProjectWorkspaceOverview(state: state, project: project, surface: surface)
      } else {
        tabBar
        Divider()
        if let tab = surface.activeTab {
          ProjectNativeEditorTab(tab: tab, surface: surface)
        } else {
          ContentUnavailableView(
            "No Active Tab",
            systemImage: "rectangle.on.rectangle",
            description: Text("Select a file tab to continue.")
          )
        }
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(.background)
    .alert("Discard unsaved changes?", isPresented: pendingCloseIsPresented) {
      Button("Cancel", role: .cancel) {
        pendingCloseTabID = nil
      }
      Button("Discard", role: .destructive) {
        guard let pendingCloseTabID else {
          return
        }
        self.pendingCloseTabID = nil
        surface.closeTab(id: pendingCloseTabID)
      }
    } message: {
      Text("The editor buffer has changes that have not been saved to disk.")
    }
  }

  private var pendingCloseIsPresented: Binding<Bool> {
    Binding(
      get: { pendingCloseTabID != nil },
      set: { isPresented in
        if !isPresented {
          pendingCloseTabID = nil
        }
      }
    )
  }

  private var tabBar: some View {
    ScrollView(.horizontal) {
      HStack(spacing: 2) {
        ForEach(surface.editorTabs) { tab in
          HStack(spacing: 5) {
            Button(tab.displayTitle) {
              surface.activateTab(id: tab.id)
            }
            .buttonStyle(.plain)
            .lineLimit(1)

            Button {
              requestClose(tab)
            } label: {
              Image(systemName: "xmark")
                .font(.caption2.weight(.bold))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close \(tab.title)")
          }
          .padding(.horizontal, 9)
          .padding(.vertical, 6)
          .background(
            surface.activeTabID == tab.id
              ? Color.accentColor.opacity(0.16)
              : Color.clear,
            in: RoundedRectangle(cornerRadius: 5)
          )
        }
        Spacer(minLength: 0)
      }
      .padding(.horizontal, 8)
      .padding(.vertical, 5)
    }
    .scrollIndicators(.hidden)
  }

  private func requestClose(_ tab: ProjectEditorTab) {
    if tab.isDirty {
      pendingCloseTabID = tab.id
    } else {
      surface.closeTab(id: tab.id)
    }
  }
}

private struct ProjectNativeEditorTab: View {
  @ObservedObject var tab: ProjectEditorTab
  @ObservedObject var surface: ProjectSurfaceModel

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack(spacing: 8) {
        Image(systemName: "doc.text")
          .foregroundStyle(.secondary)
        Text(tab.url.path)
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(1)
        Spacer()
        if tab.isMissing {
          Label("Missing", systemImage: "exclamationmark.triangle")
            .font(.caption)
            .foregroundStyle(.orange)
        } else if tab.isDirty {
          Text("Unsaved")
            .font(.caption)
            .foregroundStyle(.orange)
        }
        Menu("History") {
          if tab.historyEntries.isEmpty {
            Text("No recovery snapshots")
          } else {
            ForEach(tab.historyEntries) { entry in
              Button(entry.displayLabel) {
                surface.restoreHistoryEntry(entry.id, tabID: tab.id)
              }
            }
          }
        }
        Button("Undo") {
          surface.undoActiveTab()
        }
        .buttonStyle(.borderless)
        .disabled(!tab.canUndo)
        Button("Redo") {
          surface.redoActiveTab()
        }
        .buttonStyle(.borderless)
        .disabled(!tab.canRedo)
        Button("Save") {
          surface.save(tabID: tab.id)
        }
        .buttonStyle(.borderedProminent)
        .disabled(!tab.isDirty || tab.isMissing)
        Button("Reveal in Tree") {
          surface.reveal(nodeID: tab.id)
        }
        .buttonStyle(.borderless)
      }
      .padding(.horizontal, 16)
      .padding(.vertical, 9)

      Divider()

      ProjectSourceEditorView(document: tab, selection: tab.selectionRequest) {
        surface.save(tabID: tab.id)
      }
    }
    .alert("Editor update failed", isPresented: editorErrorIsPresented) {
      Button("OK") {
        tab.dismissError()
      }
    } message: {
      Text(tab.lastErrorMessage ?? "Unknown editor error.")
    }
  }

  private var editorErrorIsPresented: Binding<Bool> {
    Binding(
      get: { tab.lastErrorMessage != nil },
      set: { isPresented in
        if !isPresented {
          tab.dismissError()
        }
      }
    )
  }
}

private struct ProjectWorkspaceOverview: View {
  let state: BootstrapState
  let project: Project
  @ObservedObject var surface: ProjectSurfaceModel

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 20) {
        VStack(alignment: .leading, spacing: 5) {
          Text("Workspace shell")
            .font(.largeTitle.weight(.semibold))
          Text("Select a file in the tree to open a native editor tab.")
            .foregroundStyle(.secondary)
        }

        GroupBox("Project") {
          Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 10) {
            detailRow(label: "ID", value: project.id.uuidString)
            detailRow(label: "Root", value: project.rootURL.path)
            detailRow(label: "Color", value: project.color.displayName)
            detailRow(label: "Tree", value: surface.fileTree.availability.displayName)
          }
          .frame(maxWidth: .infinity, alignment: .leading)
          .textSelection(.enabled)
          .padding(.vertical, 4)
        }

        GroupBox("Runtime") {
          Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 10) {
            detailRow(label: "Channel", value: state.profile.channel.rawValue.uppercased())
            detailRow(label: "Bundle", value: state.profile.bundleIdentifier)
            detailRow(label: "Preferences", value: state.profile.preferencesDomain)
            detailRow(label: "Data", value: state.applicationSupportURL?.path ?? "Unavailable")
            detailRow(label: "Rust core", value: rustStatus)
          }
          .frame(maxWidth: .infinity, alignment: .leading)
          .textSelection(.enabled)
          .padding(.vertical, 4)
        }

        if let errorMessage = state.errorMessage {
          Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
            .foregroundStyle(.red)
            .fixedSize(horizontal: false, vertical: true)
        } else {
          Label("Swift → Rust smoke path is ready", systemImage: "checkmark.circle.fill")
            .foregroundStyle(.green)
        }
      }
      .padding(28)
    }
  }

  private var rustStatus: String {
    let value = String(format: "0x%08X", state.rustSmokeValue)
    return state.rustSmokeSucceeded ? "ready (\(value))" : "failed (\(value))"
  }

  @ViewBuilder
  private func detailRow(label: String, value: String) -> some View {
    GridRow {
      Text(label)
        .foregroundStyle(.secondary)
      Text(value)
        .font(.system(.body, design: .monospaced))
    }
  }
}

extension ProjectColor {
  fileprivate var swiftUIColor: Color {
    switch self {
    case .blue:
      .blue
    case .purple:
      .purple
    case .orange:
      .orange
    case .green:
      .green
    case .red:
      .red
    case .gray:
      .gray
    }
  }
}
