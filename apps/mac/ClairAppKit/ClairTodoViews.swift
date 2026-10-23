#if os(macOS)
  import ClairDesignSystem
  import ClairShared
  import ClairWorkspace
  import SwiftUI

  private typealias C = DesignTokens.Color
  private typealias L = DesignTokens.Line

  /// Add / edit a TODO's title, priority and due date, dressed like the ⌘K palette.
  /// The body stays in the Markdown file, opened from the sidebar row.
  struct TodoEditor: View {
    let todo: ClairTodo
    let isNew: Bool
    let save: (ClairTodo) -> Void
    let cancel: () -> Void

    @State private var title = ""
    @State private var priority = 2
    @State private var hasDue = false
    @State private var due = Date()
    @FocusState private var focused: Bool

    private static let day: DateFormatter = {
      let f = DateFormatter(); f.calendar = Calendar(identifier: .gregorian); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd"; return f
    }()

    var body: some View {
      ZStack(alignment: .top) {
        Color(red: 8 / 255, green: 10 / 255, blue: 12 / 255).opacity(0.68).onTapGesture(perform: cancel)
        VStack(alignment: .leading, spacing: 12) {
          Text(isNew ? tr("TODO を追加") : tr("TODO を編集")).font(.system(size: 13, weight: .semibold)).foregroundStyle(C.textPrimary)
          TextField(tr("タイトル"), text: $title)
            .focused($focused).textFieldStyle(.plain).font(.system(size: 13)).foregroundStyle(C.textPrimary)
            .padding(.horizontal, 8).frame(height: 32)
            .background(C.canvas, in: RoundedRectangle(cornerRadius: Radius.control))
            .overlay(RoundedRectangle(cornerRadius: Radius.control).stroke(L.hairline))
            .onSubmit(commit)
          HStack(spacing: 12) {
            Picker(tr("優先度"), selection: $priority) {
              Text(tr("高")).tag(1); Text(tr("中")).tag(2); Text(tr("低")).tag(3)
            }.pickerStyle(.segmented).frame(width: 200)
            Toggle(tr("期限"), isOn: $hasDue)
            DatePicker("", selection: $due, displayedComponents: .date).labelsHidden().disabled(!hasDue)
            Spacer(minLength: 0)
          }.font(.system(size: 12)).foregroundStyle(C.textSecondary)
          HStack {
            Spacer()
            Button(tr("キャンセル"), action: cancel).keyboardShortcut(.cancelAction)
            Button(isNew ? tr("追加") : tr("保存"), action: commit).keyboardShortcut(.defaultAction)
              .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty)
          }
        }
        .padding(16)
        .frame(width: 560).background(C.chromeRaised, in: RoundedRectangle(cornerRadius: Radius.overlay))
        .overlay(RoundedRectangle(cornerRadius: Radius.overlay).stroke(L.strong))
        .padding(.top, 96)
      }
      .onAppear {
        title = todo.title; priority = todo.priority
        if let d = todo.due.flatMap(Self.day.date(from:)) { hasDue = true; due = d }
        focused = true
      }
    }

    private func commit() {
      let t = title.trimmingCharacters(in: .whitespaces)
      guard !t.isEmpty else { return }
      var out = todo
      out.title = t; out.priority = priority; out.due = hasDue ? Self.day.string(from: due) : nil
      save(out)
    }
  }
#endif
