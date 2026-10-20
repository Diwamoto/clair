#if os(macOS)
  import AppKit
  import ClairDesignSystem
  import ClairShared
  import ClairWorkspace
  import SwiftUI
  import UniformTypeIdentifiers

  private typealias C = DesignTokens.Color
  private typealias L = DesignTokens.Line

  // ADR-0025: the file browser (Finder artboard). Finder's column view as an editor tab (`finder:<folder>`):
  // columns flow left to right, a folder is listed one level at a time when its column appears, a single file gets a
  // preview column. Rows are the explorer's (24pt, radius.control); the selection is surfaceActive and the trail (a
  // folder whose column is open to the right) keeps surfaceHover. Its places live in the sidebar (`FileBrowserSidebar`).

  /// One tab's columns, selection and history. Owned by the shell per tab, so switching tabs keeps them.
  @MainActor @Observable final class FileBrowserModel {
    struct Location: Equatable { var columns: [String]; var selection: [String] }
    enum Listing: Equatable { case loading, loaded([FileBrowser.Entry]), failed(String) }

    var location: Location
    private(set) var back: [Location] = []
    private(set) var forward: [Location] = []
    var listings: [String: Listing] = [:]
    var showHidden = false
    /// Footer text for a moment after an action; Finder's item count otherwise.
    var notice: String?
    /// The last `finder.reveal` this tab acted on.
    var revealed = 0

    init(root: String) { location = Location(columns: [root], selection: []) }

    var root: String { location.columns[0] }
    var picked: FileBrowser.Entry? { location.selection.count == 1 ? entry(location.selection[0]) : nil }
    /// The deepest folder on screen: what `finder.selection` reports and where ⌘V lands.
    var folder: String {
      if let p = picked, p.isDirectory { return p.path }
      return location.selection.first.map { ($0 as NSString).deletingLastPathComponent } ?? location.columns.last!
    }

    func entries(_ folder: String) -> [FileBrowser.Entry]? { if case .loaded(let e)? = listings[folder] { e } else { nil } }
    func entry(_ path: String) -> FileBrowser.Entry? { entries((path as NSString).deletingLastPathComponent)?.first { $0.path == path } }

    func go(_ next: Location) {
      guard next != location else { return }
      back.append(location); forward = []; location = next
    }
    func goBack() { guard let l = back.popLast() else { return }; forward.insert(location, at: 0); location = l }
    func goForward() { guard !forward.isEmpty else { return }; back.append(location); location = forward.removeFirst() }

    /// Lists every column not yet listed (or all of them, `force`), off the main thread — one level per folder.
    func load(force: Bool = false) {
      for folder in location.columns where force || listings[folder] == nil {
        if listings[folder] == nil { listings[folder] = .loading }
        let hidden = showHidden
        Task.detached(priority: .userInitiated) {
          let result: Listing
          do { result = .loaded(try FileBrowser.list(folder, showHidden: hidden)) } catch { result = .failed(error.localizedDescription) }
          await MainActor.run { self.listings[folder] = result }
        }
      }
    }

    /// Click: a folder opens its column to the right, a file selects; anything right of `column` closes.
    /// ⌘-click toggles within the same column (Finder's multi-select).
    func select(_ e: FileBrowser.Entry, column: Int, toggle: Bool) {
      let columns = Array(location.columns.prefix(column + 1))
      if toggle, let first = location.selection.first, (first as NSString).deletingLastPathComponent == location.columns[column] {
        var sel = location.selection
        if let i = sel.firstIndex(of: e.path) { sel.remove(at: i) } else { sel.append(e.path) }
        location = Location(columns: columns, selection: sel)
      } else {
        location = Location(columns: e.isDirectory ? columns + [e.path] : columns, selection: [e.path])
      }
      load()
    }

    func flash(_ text: String) {
      notice = text
      Task { try? await Task.sleep(for: .seconds(2.4)); if notice == text { notice = nil } }
    }
  }

  /// What the shell lends the browser: opening, agents and terminals, the Project root, and the selection hand-off.
  struct FileBrowserHost {
    var projectRoot: String?
    var agents: [(title: String, pane: Int)]
    /// The plain terminal a path is typed into, if this Project has one.
    var terminal: Int?
    var openInClair: (String) -> Void
    var openBrowser: (String) -> Void
    var focusPane: (Int) -> Void
    var context: (FileBrowserContext) -> Void
    /// よく使う項目 (`WorkbenchState.favorites`) and the commands that change it.
    var favorites: [String]
    var addFavorites: ([String]) -> Void
    var removeFavorite: (String) -> Void
  }

  struct FileBrowserView: View {
    let model: FileBrowserModel
    let tab: String
    let reveal: FileBrowserReveal?
    let menus: ClairMenuController
    let host: FileBrowserHost
    @FocusState private var focused: Bool
    @State private var favoriteDrop = false

    var body: some View {
      VStack(spacing: 0) {
        toolbar
        Rectangle().fill(L.hairlineFaint).frame(height: 1)
        HStack(spacing: 0) {
          favoritesColumn
          Rectangle().fill(L.hairlineFaint).frame(width: 1)
          columnsArea
        }
        Rectangle().fill(L.hairlineFaint).frame(height: 1)
        footer
      }
      .background(C.canvas)
      .focusable().focused($focused).focusEffectDisabled()
      .onKeyPress(phases: .down, action: key)
      .onCopyCommand { model.location.selection.map { NSItemProvider(object: URL(fileURLWithPath: $0) as NSURL) } }
      .onPasteCommand(of: [.fileURL]) { _ in paste(into: model.folder) }
      .onDeleteCommand { trash(model.location.selection) }
      .onAppear { model.load(force: true); takeReveal(); publish() }
      .onChange(of: reveal?.seq) { takeReveal() }
      .onChange(of: model.location) { publish() }
    }

    /// The columns, left to right, then the preview; scrolled so the newest column stays in view.
    private var columnsArea: some View {
      ScrollViewReader { proxy in
        ScrollView(.horizontal) {
          HStack(spacing: 0) {
            ForEach(Array(model.location.columns.enumerated()), id: \.element) { index, folder in
              column(folder, index: index)
              Rectangle().fill(L.hairlineFaint).frame(width: 1)
            }
            if let p = model.picked, !p.isDirectory {
              FileBrowserPreview(entry: p, open: { open(p) }, openElsewhere: { openWithDefault(p) }).id("preview")
            } else if model.location.selection.count > 1 {
              Text(tr("%@ 項目を選択", model.location.selection.count)).font(.system(size: 12)).foregroundStyle(C.textTertiary)
                .frame(width: 240).frame(maxHeight: .infinity).id("preview")
            }
            Color.clear.frame(width: 1).id("end")
          }.clairScroller()
        }
        // The newest column is the one being read: keep it in view.
        .onChange(of: model.location) { withAnimation(.easeOut(duration: 0.12)) { proxy.scrollTo("end", anchor: .trailing) } }
      }
    }

    // MARK: toolbar / footer

    private var toolbar: some View {
      HStack(spacing: 4) {
        navButton("chevron.left", tr("戻る"), enabled: !model.back.isEmpty) { model.goBack(); model.load() }
        navButton("chevron.right", tr("進む"), enabled: !model.forward.isEmpty) { model.goForward(); model.load() }
        // Path bar: `~` for home, then each folder down to what is selected; a segment starts the columns there.
        HStack(spacing: 4) {
          ForEach(Array(crumbs.enumerated()), id: \.offset) { i, c in
            if i > 0 { Text("›").foregroundStyle(C.textQuaternary) }
            Button { if FileBrowser.isFolder(c.path) { model.go(.init(columns: [c.path], selection: [])); model.load() } } label: {
              Text(c.label).fontWeight(i == crumbs.count - 1 ? .semibold : .regular)
                .foregroundStyle(i == crumbs.count - 1 ? C.textSecondary : C.textQuaternary).lineLimit(1)
                .padding(.horizontal, 4).padding(.vertical, 1)
            }.buttonStyle(HoverWashStyle(radius: Radius.control))
          }
        }.font(.system(size: 11, design: .monospaced)).padding(.leading, 4)
        Spacer(minLength: 0)
      }.padding(.horizontal, 8).frame(height: 28)
    }

    private func navButton(_ symbol: String, _ label: String, enabled: Bool, _ action: @escaping () -> Void) -> some View {
      Button(action: action) {
        Image(systemName: symbol).font(.system(size: 10, weight: .semibold)).frame(width: 22, height: 22)
          .foregroundStyle(enabled ? C.textTertiary : C.textQuaternary)
      }.buttonStyle(HoverWashStyle(radius: Radius.control)).disabled(!enabled).opacity(enabled ? 1 : 0.5).help(label)
    }

    private var crumbs: [(label: String, path: String)] {
      let deepest = model.picked?.path ?? model.location.columns.last!
      let home = NSHomeDirectory()
      let base = deepest == home || deepest.hasPrefix(home + "/") ? home : ""
      let rest = deepest.dropFirst(base.count).split(separator: "/").map(String.init)
      var out: [(label: String, path: String)] = base.isEmpty ? [(label: "/", path: "/")] : [(label: "~", path: home)]
      for i in rest.indices { out.append((label: rest[i], path: base + "/" + rest[...i].joined(separator: "/"))) }
      return out
    }

    private var footer: some View {
      let count = model.entries(model.location.columns.last!)?.count ?? 0
      let selected = model.location.selection.count
      let text = model.notice
        ?? [tr("%@ 項目", count), selected > 0 ? tr("%@ 項目を選択", selected) : nil, model.showHidden ? tr("隠しファイルを表示中") : nil]
          .compactMap { $0 }.joined(separator: " · ")
      return Text(text).font(.system(size: 11)).foregroundStyle(model.notice == nil ? C.textQuaternary : C.textSecondary)
        .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 12).frame(height: 22)
    }

    // MARK: favorites (よく使う項目)

    /// Finder's favorites as the first, fixed column: pins the user adds with 「よく使う項目に追加」 or by dropping rows
    /// here. A folder starts the columns there; a file opens its folder with it selected. A pin whose item is gone
    /// stays, dimmed, until removed.
    private var favoritesColumn: some View {
      ScrollView(.vertical) {
        LazyVStack(alignment: .leading, spacing: 0) {
          Text(tr("よく使う項目")).font(.system(size: 11)).foregroundStyle(C.textQuaternary)
            .padding(.horizontal, 16).padding(.top, 4).padding(.bottom, 6)
          ForEach(host.favorites, id: \.self) { favoriteRow($0) }
          if host.favorites.isEmpty {
            Text(tr("フォルダやファイルをここへドラッグするか、右クリックの「よく使う項目に追加」で登録"))
              .font(.system(size: 11)).foregroundStyle(C.textQuaternary).lineSpacing(2)
              .padding(.horizontal, 16).padding(.vertical, 4)
          }
        }.padding(.vertical, 6).clairScroller()
      }
      .frame(width: 148)
      .background(C.panel)
      .overlay(Rectangle().stroke(favoriteDrop ? L.ring : .clear, lineWidth: 1))
      // Rows from the columns, the explorer, a tab or the macOS Finder: each becomes a pin.
      .dropDestination(for: URL.self) { urls, _ in
        let paths = urls.filter(\.isFileURL).map(\.path)
        guard !paths.isEmpty else { return false }
        host.addFavorites(paths)
        return true
      } isTargeted: { favoriteDrop = $0 }
    }

    private func favoriteRow(_ path: String) -> some View {
      var isDir: ObjCBool = false
      let exists = FileManager.default.fileExists(atPath: path, isDirectory: &isDir)
      let folder = !exists || isDir.boolValue
      let on = folder ? model.root == path : model.location.selection.contains(path)
      let name = path == NSHomeDirectory() ? tr("ホーム") : (path as NSString).lastPathComponent
      return HStack(spacing: 8) {
        (folder ? FileIcon.folder(open: false) : FileIcon.forPath(name)).image(size: 11, ink: C.textTertiary).frame(width: 14)
        Text(name).font(.system(size: 12, weight: on ? .semibold : .regular)).lineLimit(1).truncationMode(.middle)
          .foregroundStyle(on ? C.textPrimary : C.textSecondary)
        Spacer(minLength: 0)
      }
      .padding(.horizontal, 8).frame(height: 24)
      .background(on ? C.surfaceActive : .clear, in: RoundedRectangle(cornerRadius: Radius.control))
      .contentShape(Rectangle())
      .padding(.horizontal, 6)
      .opacity(exists ? 1 : 0.5)
      .onTapGesture {
        guard exists else { return }
        model.go(folder ? .init(columns: [path], selection: []) : .init(columns: [(path as NSString).deletingLastPathComponent], selection: [path]))
        model.load()
        focused = true
      }
      .simultaneousGesture(TapGesture(count: 2).onEnded {
        guard exists, !folder else { return }
        if FileBrowser.isText(path) { host.openInClair(path) } else { NSWorkspace.shared.open(URL(fileURLWithPath: path)) }
      })
      .onDrag { NSItemProvider(object: URL(fileURLWithPath: path) as NSURL) }
      .help(path)
      .clairContextMenu(menus) {
        ClairMenuSpec(title: name, sub: path, entries: [
          .item(folder ? tr("開く") : tr("Clair で開く"), disabled: !exists || (!folder && !FileBrowser.isText(path))) {
            if folder { model.go(.init(columns: [path], selection: [])); model.load() } else { host.openInClair(path) }
          },
          .item(tr("新しいタブで開く"), disabled: !exists || !folder) { host.openBrowser(path) },
          .separator,
          agentMenu(tr("Agent に送る"), text: FileBrowser.mention(path, root: host.projectRoot) + " "),
          .item(tr("パスをコピー")) { copyPaths([path]) },
          .separator,
          .item(tr("よく使う項目から外す")) { host.removeFavorite(path) },
        ])
      }
    }

    // MARK: columns

    private func column(_ folder: String, index: Int) -> some View {
      ScrollView(.vertical) {
        LazyVStack(alignment: .leading, spacing: 0) {
          switch model.listings[folder] {
          case .loaded(let list) where list.isEmpty: note(tr("空のフォルダ"))
          case .loaded(let list):
            ForEach(list) { row($0, column: index) }
          case .failed: note(tr("開けません"))
          case .loading, nil: note(tr("読み込み中…"))
          }
          // The empty part below the rows is the column's own: a click clears what is right of it, a right-click
          // offers paste / new folder / hidden files. (A catcher over the whole column would cover the rows' own.)
          Color.clear.frame(height: 160).contentShape(Rectangle())
            .onTapGesture {
              model.location = .init(columns: Array(model.location.columns.prefix(index + 1)), selection: [])
              focused = true
            }
            .clairContextMenu(menus) { backgroundMenu(folder) }
        }.padding(.vertical, 4).clairScroller()
      }
      .frame(width: 200)
    }

    private func note(_ text: String) -> some View {
      Text(text).font(.system(size: 12)).foregroundStyle(C.textTertiary).padding(.horizontal, 16).frame(height: 24)
    }

    private func row(_ e: FileBrowser.Entry, column: Int) -> some View {
      let selected = model.location.selection.contains(e.path)
      let trail = !selected && model.location.columns.dropFirst(column + 1).first == e.path
      return HStack(spacing: 8) {
        (e.isDirectory ? FileIcon.folder(open: false) : FileIcon.forPath(e.name)).image(size: 11, ink: C.textTertiary).frame(width: 14)
        Text(e.name).font(.system(size: 12)).lineLimit(1).truncationMode(.middle)
          .foregroundStyle(e.isHidden ? C.textQuaternary : selected || trail ? C.textPrimary : C.textSecondary)
        Spacer(minLength: 0)
        if e.isDirectory { Image(systemName: "chevron.right").font(.system(size: 8, weight: .semibold)).foregroundStyle(C.textQuaternary) }
      }
      .padding(.horizontal, 8).frame(height: 24)
      .background(selected ? C.surfaceActive : trail ? C.surfaceHover : .clear, in: RoundedRectangle(cornerRadius: Radius.control))
      .contentShape(Rectangle())
      .padding(.horizontal, 6)
      .onTapGesture {
        model.select(e, column: column, toggle: NSEvent.modifierFlags.contains(.command))
        focused = true
      }
      .simultaneousGesture(TapGesture(count: 2).onEnded { open(e) })
      // A row drags out as a file URL: onto a terminal it becomes its escaped path, onto the macOS Finder a copy.
      // ponytail: one item per drag (SwiftUI's onDrag carries a single provider); a multi-selection goes through the menu.
      .onDrag { NSItemProvider(object: URL(fileURLWithPath: e.path) as NSURL) }
      .help(e.path)
      .clairContextMenu(menus) {
        if !model.location.selection.contains(e.path) { model.select(e, column: column, toggle: false) }
        return entryMenu(e)
      }
    }

    // MARK: actions

    private func open(_ e: FileBrowser.Entry) {
      if e.isDirectory {
        let column = model.location.columns.firstIndex(of: (e.path as NSString).deletingLastPathComponent) ?? 0
        model.go(.init(columns: Array(model.location.columns.prefix(column + 1)) + [e.path], selection: []))
        model.load()
      } else if FileBrowser.isText(e.path) {
        host.openInClair(e.path)
      } else {
        openWithDefault(e)
      }
    }

    private func openWithDefault(_ e: FileBrowser.Entry) {
      NSWorkspace.shared.open(URL(fileURLWithPath: e.path))
    }

    private func open(_ e: FileBrowser.Entry, with app: URL) {
      NSWorkspace.shared.open([URL(fileURLWithPath: e.path)], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
    }

    private func refresh() { model.load(force: true) }

    private func copy(_ paths: [String]) {
      NSPasteboard.general.clearContents()
      NSPasteboard.general.writeObjects(paths.map { URL(fileURLWithPath: $0) as NSURL })
      model.flash(tr("%@ 項目をコピーしました", paths.count))
    }

    /// ⌘V: the file URLs on the pasteboard (Clair's ⌘C or the macOS Finder's) are copied into `folder`.
    private func paste(into folder: String) {
      let urls = NSPasteboard.general.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
      guard !urls.isEmpty else { return }
      do {
        let made = try FileBrowser.paste(urls.map(\.path), into: folder)
        model.flash(tr("%@ 項目をペーストしました", made.count))
      } catch { fail(error) }
      refresh()
    }

    private func trash(_ paths: [String]) {
      guard !paths.isEmpty else { return }
      let name = paths.count == 1 ? (paths[0] as NSString).lastPathComponent : tr("%@ 項目", paths.count)
      menus.ask(ClairDialog(title: tr("“%@” を削除しますか?", name), message: tr("ゴミ箱に移動します。"), confirm: tr("ゴミ箱に移動"), destructive: true) { _ in
        do { for p in paths { try FileManager.default.trashItem(at: URL(fileURLWithPath: p), resultingItemURL: nil) } } catch { fail(error) }
        model.location.selection = []
        refresh()
      })
    }

    private func rename(_ e: FileBrowser.Entry) {
      menus.ask(ClairDialog(title: tr("名前を変更"), initial: e.name) { raw in
        let name = raw.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/"), name != e.name else { return }
        let to = ((e.path as NSString).deletingLastPathComponent as NSString).appendingPathComponent(name)
        do { try FileManager.default.moveItem(atPath: e.path, toPath: to) } catch { return fail(error) }
        model.location.selection = [to]
        refresh()
      })
    }

    private func newFolder(in folder: String) {
      menus.ask(ClairDialog(title: tr("新しいフォルダー"), initial: "") { raw in
        let name = raw.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/") else { return }
        do { try FileManager.default.createDirectory(atPath: (folder as NSString).appendingPathComponent(name), withIntermediateDirectories: false) } catch { return fail(error) }
        refresh()
      })
    }

    private func fail(_ error: Error) {
      menus.ask(ClairDialog(title: tr("操作できませんでした"), message: error.localizedDescription) { _ in })
    }

    /// Typed into an agent or terminal, never sent: the user reviews it and presses Return.
    private func typeText(_ text: String, into pane: Int, notice: String) {
      if ClairGhosttySurfaceView.send(text, toPane: pane) { host.focusPane(pane); model.flash(notice) }
    }

    private func key(_ press: KeyPress) -> KeyPress.Result {
      let current = model.location.selection.last
      let column = current.flatMap { model.location.columns.firstIndex(of: ($0 as NSString).deletingLastPathComponent) } ?? 0
      // Arrow keys carry .function / .numericPad; only the user's modifiers count.
      let mods = press.modifiers.intersection([.command, .option, .control, .shift])
      if mods == [.command, .shift], [".", ">"].contains(press.characters) {
        model.showHidden.toggle(); model.listings = [:]; model.load(); return .handled
      }
      if mods == [.command, .option], ["c", "ç"].contains(press.characters.lowercased()) {
        copyPaths(model.location.selection); return .handled
      }
      guard mods.isEmpty, let list = model.entries(model.location.columns[column]) else { return .ignored }
      switch press.key {
      case .downArrow, .upArrow:
        let at = list.firstIndex { $0.path == current } ?? -1
        let next = max(0, min(list.count - 1, at + (press.key == .downArrow ? 1 : -1)))
        if list.indices.contains(next) { model.select(list[next], column: column, toggle: false) }
      case .rightArrow:
        guard let p = model.picked, p.isDirectory, let inner = model.entries(p.path), let first = inner.first else { return .ignored }
        model.select(first, column: column + 1, toggle: false)
      case .leftArrow:
        guard column > 0 else { return .ignored }
        model.location = .init(columns: Array(model.location.columns.prefix(column + 1)), selection: [model.location.columns[column]])
      case .return:
        guard let p = model.picked else { return .ignored }
        open(p)
      default: return .ignored
      }
      return .handled
    }

    private func copyPaths(_ paths: [String]) {
      guard !paths.isEmpty else { return }
      NSPasteboard.general.clearContents()
      NSPasteboard.general.setString(paths.joined(separator: "\n"), forType: .string)
      model.flash(tr("パスをコピーしました"))
    }

    private func takeReveal() {
      guard let r = reveal, r.tab == tab, r.seq != model.revealed else { return }
      model.revealed = r.seq
      model.go(.init(columns: [r.folder], selection: r.select.map { [$0] } ?? []))
      model.load()
    }

    private func publish() { host.context(FileBrowserContext(folder: model.folder, selection: model.location.selection)) }

    // MARK: menus (ContextMenu rules: open first, hand-offs, copies, the destructive one last)

    private func entryMenu(_ e: FileBrowser.Entry) -> ClairMenuSpec {
      let paths = model.location.selection.contains(e.path) ? model.location.selection : [e.path]
      let many = paths.count > 1
      let parent = (e.path as NSString).deletingLastPathComponent
      let relative = host.projectRoot.flatMap { root in e.path.hasPrefix(root + "/") ? String(e.path.dropFirst(root.count + 1)) : nil }
      let apps: [URL] = many ? [] : Array(NSWorkspace.shared.urlsForApplications(toOpen: URL(fileURLWithPath: e.path)).prefix(12))
      var entries: [ClairMenuEntry] = e.isDirectory
        ? [.item(tr("開く"), shortcut: "↵", disabled: many) { open(e) },
           .item(tr("新しいタブで開く"), disabled: many) { host.openBrowser(e.path) }]
        : [.item(tr("Clair で開く"), shortcut: "↵", disabled: many || !FileBrowser.isText(e.path)) { host.openInClair(e.path) },
           .item(tr("既定のアプリで開く"), disabled: many) { openWithDefault(e) }]
      entries.append(.item(tr("このアプリケーションで開く"), disabled: apps.isEmpty, submenu: apps.map { app in
        ClairMenuEntry.item(FileManager.default.displayName(atPath: app.path)) { open(e, with: app) }
      }))
      entries.append(.separator)
      entries.append(agentMenu(tr("Agent に送る"), text: paths.map { FileBrowser.mention($0, root: host.projectRoot) }.joined(separator: " ") + " "))
      if e.isDirectory && !many { entries.append(organizeMenu(e.path)) }
      entries.append(.item(e.isDirectory && !many ? tr("ターミナルで cd") : tr("ターミナルにパスを入力"), disabled: host.terminal == nil) {
        let text = e.isDirectory && !many ? "cd \(FileBrowser.shellEscape(e.path)) " : paths.map(FileBrowser.shellEscape).joined(separator: " ") + " "
        if let t = host.terminal { typeText(text, into: t, notice: tr("ターミナルに入力しました(未送信)")) }
      })
      entries += [
        .separator,
        .item(tr("コピー"), shortcut: "⌘C") { copy(paths) },
        .item(tr("ペースト"), shortcut: "⌘V") { paste(into: e.isDirectory && !many ? e.path : parent) },
        favoriteItem(e.path, paths: paths),
        .item(tr("パスをコピー"), shortcut: "⌥⌘C") { copyPaths(paths) },
        .item(tr("相対パスをコピー"), disabled: many || relative == nil) { copyPaths([relative!]) },
        .item(tr("Finder で表示")) { NSWorkspace.shared.activateFileViewerSelecting(paths.map { URL(fileURLWithPath: $0) }) },
        .separator,
        .item(tr("名前を変更…"), disabled: many) { rename(e) },
        .item(tr("ゴミ箱に入れる"), shortcut: "⌘⌫", destructive: true) { trash(paths) },
      ]
      return ClairMenuSpec(title: many ? tr("%@ 項目", paths.count) : e.name, sub: many ? parent : e.path, entries: entries)
    }

    private func favoriteItem(_ path: String, paths: [String]) -> ClairMenuEntry {
      if paths.count == 1, host.favorites.contains(path) {
        return .item(tr("よく使う項目から外す")) { host.removeFavorite(path) }
      }
      return .item(tr("よく使う項目に追加")) { host.addFavorites(paths) }
    }

    private func backgroundMenu(_ folder: String) -> ClairMenuSpec {
      ClairMenuSpec(entries: [
        .item(tr("ペースト"), shortcut: "⌘V") { paste(into: folder) },
        .item(tr("新しいフォルダー…")) { newFolder(in: folder) },
        .separator,
        organizeMenu(folder),
        .item(tr("ターミナルで cd"), disabled: host.terminal == nil) {
          if let t = host.terminal { typeText("cd \(FileBrowser.shellEscape(folder)) ", into: t, notice: tr("ターミナルに入力しました(未送信)")) }
        },
        .item(tr("パスをコピー")) { copyPaths([folder]) },
        .separator,
        .item(model.showHidden ? tr("隠しファイルを隠す") : tr("隠しファイルを表示"), shortcut: "⇧⌘.") {
          model.showHidden.toggle(); model.listings = [:]; model.load()
        },
      ])
    }

    private func agentMenu(_ label: String, text: String) -> ClairMenuEntry {
      .item(label, disabled: host.agents.isEmpty, submenu: host.agents.map { a in
        ClairMenuEntry.item("\(a.title) · pane \(a.pane)") { typeText(text, into: a.pane, notice: tr("%@ に入力しました(未送信)", a.title)) }
      })
    }

    /// "Agent に整理を頼む ›": the request tells the agent to answer with `finder.propose` instead of moving anything.
    private func organizeMenu(_ folder: String) -> ClairMenuEntry {
      let request = tr("%@ を整理する案を考えて。ファイルは直接動かさず、`clair finder.propose folder=%@ ops='[{\"op\":\"mkdir|move|rename|trash\",\"from\":…,\"to\":…,\"why\":…}]'` で Clair に提案し、`clair finder.wait id=<返ってきた id>` で私の判断を待って結果を報告して。",
        FileBrowser.mention(folder, root: host.projectRoot), FileBrowser.shellEscape(folder))
      return agentMenu(tr("Agent に整理を頼む"), text: request)
    }
  }

  /// The preview column for one file: what it is, its first lines when it is text, and how to open it.
  private struct FileBrowserPreview: View {
    let entry: FileBrowser.Entry
    let open: () -> Void
    let openElsewhere: () -> Void
    @State private var head: String?
    @State private var text = false

    var body: some View {
      VStack(alignment: .leading, spacing: 8) {
        HStack(spacing: 8) {
          FileIcon.forPath(entry.name).image(size: 13, ink: C.textTertiary)
          Text(entry.name).font(.system(size: 13, weight: .semibold)).foregroundStyle(C.textPrimary).lineLimit(2)
        }
        Text(details).font(.system(size: 11)).foregroundStyle(C.textTertiary).lineSpacing(2).textSelection(.enabled)
        Group {
          if let head {
            Text(head).font(.system(size: 11, design: .monospaced)).foregroundStyle(C.code)
              .frame(maxWidth: .infinity, alignment: .topLeading).lineLimit(14)
          } else {
            Text(tr("Clair ではプレビューできません")).font(.system(size: 11)).foregroundStyle(C.textQuaternary)
              .frame(maxWidth: .infinity, minHeight: 100)
          }
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .background(C.panel, in: RoundedRectangle(cornerRadius: Radius.card))
        HStack(spacing: 4) {
          if text { button(tr("Clair で開く"), primary: true, open) }
          button(text ? tr("他のアプリで開く") : tr("既定のアプリで開く"), primary: !text, openElsewhere)
        }
        Spacer(minLength: 0)
      }
      .padding(16).frame(width: 240, alignment: .topLeading).frame(maxHeight: .infinity, alignment: .top)
      .task(id: entry.path) {
        let path = entry.path
        let (isText, lines) = await Task.detached(priority: .userInitiated) { (FileBrowser.isText(path), FileBrowser.head(path)) }.value
        text = isText; head = lines
      }
    }

    private var details: String {
      let size = entry.size.map { ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file) }
      let date = entry.modified.map { $0.formatted(date: .abbreviated, time: .shortened) }
      let home = NSHomeDirectory()
      let path = entry.path.hasPrefix(home + "/") ? "~" + entry.path.dropFirst(home.count) : entry.path
      return [[size, date.map { tr("変更 %@", $0) }].compactMap { $0 }.joined(separator: " · "), path].joined(separator: "\n")
    }

    private func button(_ label: String, primary: Bool, _ action: @escaping () -> Void) -> some View {
      Button(action: action) {
        Text(label).font(.system(size: 12, weight: primary ? .semibold : .regular))
          .foregroundStyle(primary ? C.canvas : C.textSecondary)
          .padding(.horizontal, 10).frame(height: 26)
          .background(primary ? C.textPrimary : .clear, in: RoundedRectangle(cornerRadius: Radius.control))
          .overlay(RoundedRectangle(cornerRadius: Radius.control).stroke(primary ? .clear : L.strong))
      }.buttonStyle(.plain)
    }
  }

  /// The browser's sidebar panel: Finder's sidebar in Clair's. Project folders, home places, then the open browser tabs.
  /// A place moves the active browser tab there (it keeps its history); with none active one opens; ⌘-click opens a new tab.
  struct FileBrowserSidebar: View {
    struct OpenTab: Identifiable { let tab: String; let root: String; var id: String { tab } }
    let project: (name: String, path: String, folders: [String])?
    let tabs: [OpenTab]
    let active: String?
    let activeModel: FileBrowserModel?
    let openBrowser: (String) -> Void
    let activate: (String) -> Void

    var body: some View {
      LazyVStack(alignment: .leading, spacing: 0) {
        if let project {
          heading("Project")
          place(project.name, project.path)
          ForEach(project.folders, id: \.self) { place(($0 as NSString).lastPathComponent, $0) }
        }
        heading(tr("場所"))
        let home = NSHomeDirectory()
        place(tr("ホーム"), home)
        place(tr("デスクトップ"), home + "/Desktop")
        place(tr("書類"), home + "/Documents")
        place(tr("ダウンロード"), home + "/Downloads")
        if !tabs.isEmpty {
          heading(tr("開いているブラウザ"))
          ForEach(tabs) { t in
            row(icon: "rectangle.split.3x1", label: tilde(t.root), mono: true, on: active == t.tab) { activate(t.tab) }
          }
        }
      }.padding(.bottom, 8)
    }

    private func heading(_ text: String) -> some View {
      Text(text).font(.system(size: 11)).foregroundStyle(C.textQuaternary).padding(.horizontal, 16).padding(.top, 10).padding(.bottom, 4)
    }

    private func place(_ label: String, _ path: String) -> some View {
      row(icon: "folder", label: label, mono: false, on: activeModel?.root == path) {
        if let m = activeModel, !NSEvent.modifierFlags.contains(.command) {
          m.go(.init(columns: [path], selection: [])); m.load()
        } else {
          openBrowser(path)
        }
      }
      .onDrag { NSItemProvider(object: URL(fileURLWithPath: path) as NSURL) }
    }

    private func row(icon: String, label: String, mono: Bool, on: Bool, _ action: @escaping () -> Void) -> some View {
      Button(action: action) {
        HStack(spacing: 8) {
          Image(systemName: icon).font(.system(size: 11)).foregroundStyle(C.textTertiary).frame(width: 14)
          Text(label).font(.system(size: mono ? 11 : 13, weight: on ? .semibold : .regular, design: mono ? .monospaced : .default))
            .foregroundStyle(on ? C.textPrimary : C.textSecondary).lineLimit(1).truncationMode(.head)
          Spacer(minLength: 0)
        }
        .padding(.horizontal, 8).frame(height: 28).frame(maxWidth: .infinity, alignment: .leading)
        .background(on ? C.surfaceActive : .clear, in: RoundedRectangle(cornerRadius: Radius.card))
        .contentShape(Rectangle())
      }.buttonStyle(.hoverWash).padding(.horizontal, 8)
    }

    private func tilde(_ path: String) -> String {
      let home = NSHomeDirectory()
      return path == home ? "~" : path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }
  }

  /// An agent's `finder.propose` as a tab (FinderProposal artboard): the operations in order with a checkbox each,
  /// trash unchecked to start. Nothing on disk changes until 適用; the agent reads the outcome with `finder.proposal`.
  struct FileProposalView: View {
    let proposal: FileProposal
    let apply: ([Int]) -> Void
    let reject: () -> Void
    let reveal: () -> Void
    @State private var checked: Set<Int>

    init(proposal: FileProposal, apply: @escaping ([Int]) -> Void, reject: @escaping () -> Void, reveal: @escaping () -> Void) {
      self.proposal = proposal; self.apply = apply; self.reject = reject; self.reveal = reveal
      _checked = State(initialValue: Set(proposal.ops.indices.filter { !proposal.ops[$0].isDestructive }))
    }

    private var pending: Bool { proposal.state == .pending }

    var body: some View {
      VStack(alignment: .leading, spacing: 0) {
        VStack(alignment: .leading, spacing: 4) {
          HStack(spacing: 8) {
            Image(systemName: "sparkles").font(.system(size: 13)).foregroundStyle(C.textTertiary)
            Text(tr("整理の提案")).font(.system(size: 15, weight: .semibold)).foregroundStyle(C.textPrimary)
            Text(short(proposal.folder)).font(.system(size: 11, design: .monospaced)).foregroundStyle(C.textTertiary)
          }
          Text(tr("Agent から · %@ 件の操作。適用するまでディスクは変わりません。", proposal.ops.count))
            .font(.system(size: 12)).foregroundStyle(C.textTertiary)
        }.padding(.horizontal, 20).padding(.top, 16).padding(.bottom, 12)
        Rectangle().fill(L.hairlineFaint).frame(height: 1)
        ScrollView {
          LazyVStack(alignment: .leading, spacing: 0) {
            ForEach(proposal.ops.indices, id: \.self) { opRow($0) }
          }.padding(.vertical, 6).clairScroller()
        }
        Rectangle().fill(L.hairlineFaint).frame(height: 1)
        HStack(spacing: 8) {
          if pending {
            button(tr("選択した %@ 件を適用", checked.count), primary: true, enabled: !checked.isEmpty) { apply(checked.sorted()) }
            button(tr("却下"), primary: false) { reject() }
            Text(tr("結果は Agent に返ります")).font(.system(size: 11)).foregroundStyle(C.textQuaternary)
          } else {
            Text(outcome).font(.system(size: 12)).foregroundStyle(proposal.state == .failed ? C.danger : C.textSecondary).lineLimit(2)
            button(tr("ファイルブラウザで表示"), primary: false) { reveal() }
          }
          Spacer(minLength: 0)
        }.padding(.horizontal, 20).frame(height: 52)
      }
      .background(C.canvas)
    }

    private var outcome: String {
      switch proposal.state {
      case .applied: tr("%@ 件を適用しました", proposal.applied.count)
      case .rejected: tr("却下しました")
      case .failed: tr("%@ 件目で止まりました: %@", proposal.applied.count + 1, proposal.error ?? "")
      case .pending: ""
      }
    }

    private func opRow(_ i: Int) -> some View {
      let op = proposal.ops[i]
      let on = checked.contains(i)
      let (verb, tint): (String, Color) = switch op.op {
      case .mkdir: (tr("フォルダを作成"), C.success)
      case .move: (tr("移動"), C.attention)
      case .rename: (tr("名前を変更"), C.attention)
      case .trash: (tr("ゴミ箱に入れる"), C.danger)
      }
      let target = switch op.op {
      case .mkdir: rel(op.to!)
      case .trash: rel(op.from!)
      case .move, .rename: "\(rel(op.from!))  →  \(rel(op.to!))"
      }
      return Button {
        guard pending else { return }
        if on { checked.remove(i) } else { checked.insert(i) }
      } label: {
        HStack(spacing: 12) {
          Image(systemName: on ? "checkmark.square.fill" : "square").font(.system(size: 13))
            .foregroundStyle(on ? C.textPrimary : C.textTertiary)
          Text(verb).font(.system(size: 12, weight: .semibold)).foregroundStyle(tint).frame(width: 96, alignment: .leading)
          Text(target).font(.system(size: 12, design: .monospaced)).foregroundStyle(C.textSecondary).lineLimit(1).truncationMode(.middle)
          Spacer(minLength: 8)
          if let why = op.why { Text(why).font(.system(size: 11)).foregroundStyle(C.textQuaternary).lineLimit(1) }
        }
        .padding(.horizontal, 12).frame(minHeight: 28).contentShape(Rectangle())
        .opacity(!pending && !proposal.applied.contains(i) ? 0.5 : 1)
      }
      .buttonStyle(HoverWashStyle(radius: Radius.control)).disabled(!pending).padding(.horizontal, 8)
    }

    private func rel(_ path: String) -> String { path.hasPrefix(proposal.folder + "/") ? String(path.dropFirst(proposal.folder.count + 1)) : short(path) }
    private func short(_ path: String) -> String {
      let home = NSHomeDirectory()
      return path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }

    private func button(_ label: String, primary: Bool, enabled: Bool = true, _ action: @escaping () -> Void) -> some View {
      Button(action: action) {
        Text(label).font(.system(size: 12, weight: primary ? .semibold : .regular))
          .foregroundStyle(primary ? C.canvas : C.textSecondary)
          .padding(.horizontal, 12).frame(height: 28)
          .background(primary ? C.textPrimary : .clear, in: RoundedRectangle(cornerRadius: Radius.control))
          .overlay(RoundedRectangle(cornerRadius: Radius.control).stroke(primary ? .clear : L.strong))
      }.buttonStyle(.plain).disabled(!enabled).opacity(enabled ? 1 : 0.4)
    }
  }
#endif
