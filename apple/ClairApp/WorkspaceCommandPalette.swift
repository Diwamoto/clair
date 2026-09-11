import AppKit
import SwiftUI

struct WorkspaceCommandPalette: View {
  @ObservedObject var surface: CommandSurfaceModel
  @Binding var mode: WorkspacePaletteMode
  let onDismiss: () -> Void

  @State private var query = ""
  @State private var selectedIndex = 0
  @FocusState private var searchFocused: Bool

  private var commandMatches: [CommandSurfaceMatch] {
    surface.matches(for: query)
  }

  private var quickOpenItems: [ProjectQuickOpenItem] {
    surface.workspace.activeSurface?.quickOpenResults ?? []
  }

  private var resultCount: Int {
    mode == .command ? commandMatches.count : quickOpenItems.count
  }

  var body: some View {
    VStack(spacing: 0) {
      // The overlay header: title and hint on one line, so the window opens at
      // 44px rather than spending a second row on the subtitle.
      HStack(spacing: 9) {
        Image(systemName: mode == .command ? "command" : "doc.text")
          .font(.system(size: 13, weight: .medium))
          .foregroundStyle(WorkspaceChrome.textTertiary)
        Text(mode == .command ? "コマンド" : "ファイルへ移動")
          .font(WorkspaceChrome.chromeFont(size: 13, weight: .semibold))
          .foregroundStyle(WorkspaceChrome.textPrimary)
        Text(mode == .command ? "Command Registryの全操作" : "Project内のファイル")
          .font(WorkspaceChrome.chromeFont(size: 10))
          .foregroundStyle(WorkspaceChrome.textMuted)
        Spacer(minLength: 0)
        Button(action: onDismiss) {
          Text("esc")
            .font(WorkspaceChrome.chromeFont(size: 9, weight: .semibold))
            .monospaced()
            .foregroundStyle(WorkspaceChrome.textQuaternary)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(WorkspaceChrome.panel, in: RoundedRectangle(cornerRadius: 3))
            .overlay {
              RoundedRectangle(cornerRadius: 3)
                .stroke(WorkspaceChrome.hairline, lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
      }
      .padding(.horizontal, 14)
      .frame(height: WorkspaceChrome.Metrics.mainHeader)
      .overlay(alignment: .bottom) {
        Rectangle().fill(WorkspaceChrome.hairline).frame(height: 1)
      }

      HStack(spacing: 8) {
        Image(systemName: "magnifyingglass")
          .foregroundStyle(WorkspaceChrome.textTertiary)
        TextField(
          mode == .command ? "コマンドを検索" : "ファイル名で検索",
          text: $query
        )
        .textFieldStyle(.plain)
        .font(WorkspaceChrome.chromeFont(size: 14))
        .focused($searchFocused)
        .onSubmit {
          runSelected()
        }
        .onKeyPress(keys: [.upArrow, .downArrow, .return]) { keyPress in
          guard keyPress.modifiers.isEmpty else {
            return .ignored
          }
          if keyPress.key == .upArrow {
            moveSelection(.up)
          } else if keyPress.key == .downArrow {
            moveSelection(.down)
          } else if keyPress.key == .return {
            runSelected()
          } else {
            return .ignored
          }
          return .handled
        }
        Text("\(resultCount) 件")
          .font(WorkspaceChrome.chromeFont(size: 10))
          .foregroundStyle(WorkspaceChrome.textMuted)
      }
      .padding(.horizontal, 11)
      .frame(height: 40)
      .background(WorkspaceChrome.canvas, in: RoundedRectangle(cornerRadius: 5))
      .overlay {
        RoundedRectangle(cornerRadius: 5)
          .stroke(WorkspaceChrome.borderStronger, lineWidth: 1)
      }
      .padding(.horizontal, 12)
      .padding(.top, 10)
      .padding(.bottom, 8)

      ScrollView {
        LazyVStack(spacing: 2) {
          resultList
        }
        .id(mode.rawValue)
        .padding(.horizontal, 8)
        .padding(.bottom, 8)
      }
      .frame(maxHeight: .infinity)

      Rectangle().fill(WorkspaceChrome.hairline).frame(height: 1)

      HStack(spacing: 12) {
        Button("コマンド") {
          switchMode(.command)
        }
        .buttonStyle(.tactile)
        .foregroundStyle(
          mode == .command ? WorkspaceChrome.textPrimary : WorkspaceChrome.textTertiary
        )
        .padding(.horizontal, 8)
        .frame(height: 20)
        .background(
          mode == .command ? WorkspaceChrome.surfaceActive : Color.clear,
          in: RoundedRectangle(cornerRadius: 4, style: .continuous)
        )

        Button("ファイルへ移動") {
          switchMode(.quickOpen)
        }
        .buttonStyle(.tactile)
        .foregroundStyle(
          mode == .quickOpen ? WorkspaceChrome.textPrimary : WorkspaceChrome.textTertiary
        )
        .padding(.horizontal, 8)
        .frame(height: 20)
        .background(
          mode == .quickOpen ? WorkspaceChrome.surfaceActive : Color.clear,
          in: RoundedRectangle(cornerRadius: 4, style: .continuous)
        )

        Rectangle()
          .fill(WorkspaceChrome.border)
          .frame(width: 1, height: 14)

        Button("↑") {
          moveSelection(.up)
        }
        .buttonStyle(.tactile)
        .frame(width: 22, height: 20)
        .background(
          WorkspaceChrome.canvas,
          in: RoundedRectangle(cornerRadius: 4, style: .continuous)
        )
        .overlay {
          RoundedRectangle(cornerRadius: 4, style: .continuous)
            .stroke(WorkspaceChrome.border, lineWidth: 1)
        }

        Button("↓") {
          moveSelection(.down)
        }
        .buttonStyle(.tactile)
        .frame(width: 22, height: 20)
        .background(
          WorkspaceChrome.canvas,
          in: RoundedRectangle(cornerRadius: 4, style: .continuous)
        )
        .overlay {
          RoundedRectangle(cornerRadius: 4, style: .continuous)
            .stroke(WorkspaceChrome.border, lineWidth: 1)
        }

        Text("↵ 選択中を実行")
      }
      .font(WorkspaceChrome.chromeFont(size: 9))
      .foregroundStyle(WorkspaceChrome.textQuaternary)
      .padding(.horizontal, 14)
      .padding(.vertical, 8)
      .frame(maxWidth: .infinity, alignment: .leading)
      .overlay(alignment: .trailing) {
        Text("⌘P")
          .font(WorkspaceChrome.chromeFont(size: 9))
          .foregroundStyle(WorkspaceChrome.textQuaternary)
          .padding(.trailing, 14)
      }
    }
    .foregroundStyle(WorkspaceChrome.textPrimary)
    .frame(minWidth: 420, minHeight: 360)
    .onExitCommand(perform: onDismiss)
    .onMoveCommand { direction in
      moveSelection(direction)
    }
    .onAppear {
      searchFocused = true
      refreshQuickOpenResults()
    }
    .onChange(of: query) { _, _ in
      selectedIndex = 0
      refreshQuickOpenResults()
    }
    .onChange(of: mode) { _, _ in
      query = ""
      selectedIndex = 0
      searchFocused = true
      refreshQuickOpenResults()
    }
  }

  @ViewBuilder
  private var resultList: some View {
    if mode == .command {
      if commandMatches.isEmpty {
        emptyResult(message: "コマンドが見つかりません")
      } else {
        ForEach(Array(commandMatches.enumerated()), id: \.offset) { index, match in
          commandRow(match, index: index)
        }
      }
    } else if surface.workspace.activeSurface?.quickOpenIsLoading == true {
      ProgressView("ファイルを検索中…")
        .font(WorkspaceChrome.chromeFont(size: 11))
        .frame(maxWidth: .infinity, minHeight: 82)
    } else if quickOpenItems.isEmpty {
      emptyResult(message: "ファイルが見つかりません")
    } else {
      ForEach(Array(quickOpenItems.enumerated()), id: \.offset) { index, item in
        quickOpenRow(item, index: index)
      }
    }
  }

  private func emptyResult(message: String) -> some View {
    Text(message)
      .font(WorkspaceChrome.chromeFont(size: 11))
      .foregroundStyle(WorkspaceChrome.textTertiary)
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(18)
  }

  private func commandRow(_ match: CommandSurfaceMatch, index: Int) -> some View {
    Button {
      run(match)
    } label: {
      HStack(spacing: 10) {
        Image(systemName: symbol(for: match.descriptor.risk))
          .font(.system(size: 11, weight: .medium))
          .foregroundStyle(color(for: match.descriptor.risk))
          .frame(width: 18)
        VStack(alignment: .leading, spacing: 2) {
          Text(match.descriptor.title)
            .font(WorkspaceChrome.chromeFont(size: 12, weight: .medium))
            .lineLimit(1)
          Text(match.availability.isAvailable ? match.descriptor.id.rawValue : match.statusText)
            .font(WorkspaceChrome.chromeFont(size: 9))
            .foregroundStyle(WorkspaceChrome.textQuaternary)
            .lineLimit(1)
        }
        Spacer(minLength: 8)
        if let shortcut = match.shortcut {
          Text(shortcut.displayName)
            .font(WorkspaceChrome.chromeFont(size: 9, weight: .medium))
            .foregroundStyle(WorkspaceChrome.textTertiary)
        }
      }
      .padding(.horizontal, 9)
      .frame(height: 40)
      .contentShape(Rectangle())
    }
    .buttonStyle(.tactile)
    .foregroundStyle(
      match.availability.isAvailable
        ? WorkspaceChrome.textSecondary : WorkspaceChrome.textQuaternary
    )
    .disabled(!match.availability.isAvailable)
    .help(match.statusText)
    .background(
      selectedIndex == index ? WorkspaceChrome.surfaceActive : Color.clear,
      in: RoundedRectangle(cornerRadius: 5, style: .continuous)
    )
    .overlay {
      if selectedIndex == index {
        RoundedRectangle(cornerRadius: 5, style: .continuous)
          .stroke(WorkspaceChrome.borderStronger, lineWidth: 1)
      }
    }
    .onHover {
      if $0 {
        selectedIndex = index
      }
    }
  }

  private func quickOpenRow(_ item: ProjectQuickOpenItem, index: Int) -> some View {
    Button {
      run(item)
    } label: {
      HStack(spacing: 10) {
        Image(systemName: "doc.text")
          .font(.system(size: 11, weight: .medium))
          .foregroundStyle(WorkspaceChrome.textTertiary)
          .frame(width: 18)
        VStack(alignment: .leading, spacing: 2) {
          Text(item.title)
            .font(WorkspaceChrome.chromeFont(size: 12, weight: .medium))
            .lineLimit(1)
          Text(item.relativePath)
            .font(WorkspaceChrome.chromeFont(size: 9))
            .foregroundStyle(WorkspaceChrome.textQuaternary)
            .lineLimit(1)
        }
        Spacer(minLength: 8)
      }
      .padding(.horizontal, 9)
      .frame(height: 40)
      .contentShape(Rectangle())
    }
    .buttonStyle(.tactile)
    .foregroundStyle(WorkspaceChrome.textSecondary)
    .background(
      selectedIndex == index ? WorkspaceChrome.surfaceActive : Color.clear,
      in: RoundedRectangle(cornerRadius: 5, style: .continuous)
    )
    .overlay {
      if selectedIndex == index {
        RoundedRectangle(cornerRadius: 5, style: .continuous)
          .stroke(WorkspaceChrome.borderStronger, lineWidth: 1)
      }
    }
    .onHover {
      if $0 {
        selectedIndex = index
      }
    }
  }

  private func moveSelection(_ direction: MoveCommandDirection) {
    guard resultCount > 0 else {
      return
    }
    switch direction {
    case .up:
      selectedIndex = max(0, selectedIndex - 1)
    case .down:
      selectedIndex = min(resultCount - 1, selectedIndex + 1)
    default:
      break
    }
  }

  private func runSelected() {
    guard selectedIndex >= 0, selectedIndex < resultCount else {
      return
    }
    if mode == .command {
      run(commandMatches[selectedIndex])
    } else {
      run(quickOpenItems[selectedIndex])
    }
  }

  private func run(_ match: CommandSurfaceMatch) {
    guard match.availability.isAvailable else {
      return
    }
    _ = surface.invoke(commandID: match.id, source: .commandWindow)
    onDismiss()
  }

  private func run(_ item: ProjectQuickOpenItem) {
    guard let activeSurface = surface.workspace.activeSurface else {
      return
    }
    activeSurface.openQuickOpenItem(item)
    if activeSurface.lastNavigationErrorMessage == nil {
      onDismiss()
    }
  }

  private func switchMode(_ nextMode: WorkspacePaletteMode) {
    guard mode != nextMode else {
      return
    }
    mode = nextMode
  }

  private func refreshQuickOpenResults() {
    guard mode == .quickOpen, let activeSurface = surface.workspace.activeSurface else {
      return
    }
    activeSurface.requestQuickOpenItems(matching: query)
  }

  private func symbol(for risk: CommandRisk) -> String {
    switch risk {
    case .read:
      "eye"
    case .additive:
      "plus"
    case .write:
      "pencil"
    case .destructive:
      "trash"
    case .external:
      "arrow.up.right"
    }
  }

  private func color(for risk: CommandRisk) -> Color {
    switch risk {
    case .read:
      WorkspaceChrome.textTertiary
    case .additive:
      WorkspaceChrome.success
    case .write:
      WorkspaceChrome.attention
    case .destructive:
      WorkspaceChrome.danger
    case .external:
      WorkspaceChrome.accent
    }
  }
}
