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
    if let project = workspace.activeProject {
      ScrollView {
        VStack(alignment: .leading, spacing: 24) {
          HStack(spacing: 14) {
            Image(systemName: "folder.fill")
              .font(.system(size: 34, weight: .semibold))
              .foregroundStyle(project.color.swiftUIColor)

            VStack(alignment: .leading, spacing: 3) {
              Text(project.name)
                .font(.largeTitle.weight(.semibold))
              Text("Project workspace")
                .foregroundStyle(.secondary)
            }

            Spacer()

            Text(project.availability.displayName)
              .font(.caption.weight(.bold))
              .foregroundStyle(project.availability.isAvailable ? .green : .orange)
              .padding(.horizontal, 10)
              .padding(.vertical, 5)
              .background(.quaternary, in: Capsule())
          }

          GroupBox("Project") {
            Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 12) {
              detailRow(label: "ID", value: project.id.uuidString)
              detailRow(label: "Root", value: project.rootURL.path)
              detailRow(label: "Color", value: project.color.displayName)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .textSelection(.enabled)
            .padding(.vertical, 4)
          }

          GroupBox("Runtime") {
            Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 12) {
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

          Spacer(minLength: 0)
        }
        .padding(32)
      }
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
