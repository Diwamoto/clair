import AppKit
import SwiftUI

struct ProjectEditorTabHost: View {
  let state: BootstrapState
  let project: Project
  let surface: ProjectSurfaceModel
  @State private var pendingCloseTabID: String?

  var body: some View {
    VStack(spacing: 0) {
      if surface.editorTabs.isEmpty {
        ProjectWorkspaceOverview(state: state, project: project, surface: surface)
      } else {
        tabBar
        Divider()
        if let tab = surface.activeTab {
          ProjectNativeEditorTab(
            tab: tab,
            surface: surface,
            debugSession: surface.debugSession,
            showsDebugGutter: false,
            fontSize: 13,
            wordWrap: false
          )
        } else {
          ContentUnavailableView(
            "アクティブなタブはありません",
            systemImage: "rectangle.on.rectangle",
            description: Text("ファイルタブを選択して続行してください。")
          )
        }
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(.background)
    .alert("未保存の変更を破棄しますか？", isPresented: pendingCloseIsPresented) {
      Button("キャンセル", role: .cancel) {
        pendingCloseTabID = nil
      }
      Button("破棄", role: .destructive) {
        guard let pendingCloseTabID else {
          return
        }
        self.pendingCloseTabID = nil
        surface.closeTab(id: pendingCloseTabID)
      }
    } message: {
      Text("エディタバッファにディスクへ保存していない変更があります。")
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
            .buttonStyle(.tactile)
            .lineLimit(1)

            Button {
              requestClose(tab)
            } label: {
              Image(systemName: "xmark")
                .font(.caption2.weight(.bold))
            }
            .buttonStyle(.tactile)
            .accessibilityLabel("\(tab.title)を閉じる")
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

struct ProjectNativeEditorTab: View {
  @ObservedObject var tab: ProjectEditorTab
  let surface: ProjectSurfaceModel
  @ObservedObject var debugSession: DebugSessionModel
  let showsDebugGutter: Bool
  let fontSize: Double
  let wordWrap: Bool

  init(
    tab: ProjectEditorTab,
    surface: ProjectSurfaceModel,
    debugSession: DebugSessionModel,
    showsDebugGutter: Bool = false,
    fontSize: Double = 13,
    wordWrap: Bool = false
  ) {
    _tab = ObservedObject(wrappedValue: tab)
    self.surface = surface
    _debugSession = ObservedObject(wrappedValue: debugSession)
    self.showsDebugGutter = showsDebugGutter
    self.fontSize = fontSize
    self.wordWrap = wordWrap
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      if let loadError = tab.loadError {
        VStack(spacing: 20) {
          Image(systemName: "exclamationmark.triangle.fill")
            .font(.system(size: 48))
            .foregroundStyle(.orange)
          Text("ファイルを開けませんでした。")
            .font(.title3.weight(.semibold))
          Text(loadError.errorDescription ?? "Unknown error.")
            .font(.body)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: 480)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else {
        if ProjectEditorEngine.usesAppKitNativeEditor() {
          ProjectSourceEditorView(
            document: tab,
            selection: tab.selectionRequest,
            fontSize: CGFloat(fontSize),
            wordWrap: wordWrap
          ) {
            surface.save(tabID: tab.id)
          }
        } else {
          CodeMirrorEditorView(
            document: tab,
            selection: tab.selectionRequest,
            fontSize: CGFloat(fontSize),
            wordWrap: wordWrap,
            breakpoints: showsDebugGutter
              ? debugSession.breakpoints
                .filter { $0.sourcePath == tab.url.standardizedFileURL.path }
                .map(\.line)
              : [],
            onToggleBreakpoint: showsDebugGutter
              ? { line in
                debugSession.toggleBreakpoint(
                  sourcePath: tab.url.standardizedFileURL.path,
                  line: line
                )
              }
              : nil
          ) {
            surface.save(tabID: tab.id)
          }
        }
      }
    }
    .background(WorkspaceChrome.canvas)
    .alert("エディタの更新に失敗しました", isPresented: editorErrorIsPresented) {
      Button("OK") {
        tab.dismissError()
      }
    } message: {
      Text(tab.lastErrorMessage ?? "エディタで不明なエラーが発生しました。")
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

struct ProjectWorkspaceOverview: View {
  let state: BootstrapState
  let project: Project
  let surface: ProjectSurfaceModel

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 20) {
        VStack(alignment: .leading, spacing: 5) {
          Text("ワークスペース")
            .font(.largeTitle.weight(.semibold))
          Text("ツリーからファイルを選択すると、ネイティブエディタのタブが開きます。")
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

        GroupBox("ランタイム") {
          Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 10) {
            detailRow(label: "Channel", value: state.profile.channel.rawValue.uppercased())
            detailRow(label: "Bundle", value: state.profile.bundleIdentifier)
            detailRow(label: "Preferences", value: state.profile.preferencesDomain)
            detailRow(label: "データ", value: state.applicationSupportURL?.path ?? "利用できません")
            detailRow(label: "Rustコア", value: rustStatus)
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
          Label("Swift → Rustのスモークパスは準備完了", systemImage: "checkmark.circle.fill")
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
