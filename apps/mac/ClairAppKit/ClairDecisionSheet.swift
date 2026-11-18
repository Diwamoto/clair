#if os(macOS)
  import AppKit
  import ClairDesignSystem
  import ClairShared
  import ClairWorkspace
  import SwiftUI

  private typealias C = DesignTokens.Color
  private typealias L = DesignTokens.Line

  /// ADR-0030 (DecisionSheet artboard): an agent's questions about a card as a panel floating in the window's bottom-right corner.
  /// Recommended options start selected; an option's HTML preview is drawn inside it with the HTML preview pane's
  /// WebView rules. 「まとめて回答」 sends every answer at once; an answered sheet is read-only.
  struct DecisionSheetView: View {
    let sheet: DecisionSheet
    let card: String
    let close: () -> Void
    /// Answers as JSON (`{question id: [option ids or text]}`), per-question notes as JSON, and the overall comment.
    let submit: (String, String, String) -> Void
    @State private var picked: [String: Set<String>]
    @State private var texts: [String: String]
    @State private var notes: [String: String]
    @State private var comment = ""

    init(sheet: DecisionSheet, card: String, close: @escaping () -> Void, submit: @escaping (String, String, String) -> Void) {
      self.sheet = sheet; self.card = card; self.close = close; self.submit = submit
      let answered = sheet.state == .answered
      _picked = State(initialValue: Dictionary(uniqueKeysWithValues: sheet.questions.filter { $0.kind != .text }.map {
        ($0.id, Set(answered ? sheet.answers[$0.id] ?? [] : $0.recommended ?? []))
      }))
      _texts = State(initialValue: Dictionary(uniqueKeysWithValues: sheet.questions.filter { $0.kind == .text }.map {
        ($0.id, answered ? sheet.answers[$0.id]?.first ?? "" : "")
      }))
      _notes = State(initialValue: sheet.notes)
      _comment = State(initialValue: sheet.comment ?? "")
    }

    private var pending: Bool { sheet.state == .pending }

    var body: some View {
      VStack(alignment: .leading, spacing: 0) {
        VStack(alignment: .leading, spacing: 4) {
          HStack(spacing: 8) {
            Circle().fill(pending ? C.attention : C.textMuted).frame(width: 6, height: 6)
            Text(sheet.title ?? tr("判断")).font(Typography.font(Typography.title)).foregroundStyle(C.textPrimary).lineLimit(2)
            Spacer(minLength: 0)
            Button(action: close) { Image(systemName: "xmark").foregroundStyle(C.textTertiary) }
              .buttonStyle(.plain).keyboardShortcut(.cancelAction).accessibilityLabel(tr("閉じる"))
          }
          Text(pending ? tr("%@ 問。推奨を選んだ状態で開いています。", sheet.questions.count) : tr("回答済み"))
            .font(Typography.font(Typography.chrome)).foregroundStyle(C.textTertiary)
        }.padding(.horizontal, 16).padding(.top, 16).padding(.bottom, 12)
        Rectangle().fill(L.hairlineFaint).frame(height: 1)
        ScrollView {
          VStack(alignment: .leading, spacing: 12) {
            ForEach(Array(sheet.questions.enumerated()), id: \.element.id) { i, q in question(i + 1, q) }
            commentEditor
          }.padding(16).clairScroller()
        }
        Rectangle().fill(L.hairlineFaint).frame(height: 1)
        HStack(spacing: 8) {
          Spacer(minLength: 0)
          if pending {
            Text(tr("回答は質問した agent に届きます")).font(Typography.font(Typography.chrome)).foregroundStyle(C.textMuted)
            Button(action: send) {
              Text(tr("まとめて回答")).font(Typography.font(Typography.chromeStrong)).foregroundStyle(C.canvas)
                .padding(.horizontal, 12).frame(height: RowHeight.default)
                .background(C.textPrimary, in: RoundedRectangle(cornerRadius: Radius.control))
            }.buttonStyle(.plain).keyboardShortcut(.return, modifiers: .command)
          }
        }.padding(.horizontal, 16).frame(height: 52)
      }
      .background(C.canvas)
    }

    private func send() {
      var answers: [String: [String]] = [:]
      for (id, set) in picked { answers[id] = sheet.questions.first { $0.id == id }?.options?.map(\.id).filter(set.contains) ?? [] }
      for (id, text) in texts { answers[id] = [text] }
      let enc = JSONEncoder(); enc.outputFormatting = .sortedKeys
      submit(String(decoding: (try? enc.encode(answers)) ?? Data("{}".utf8), as: UTF8.self),
             String(decoding: (try? enc.encode(notes)) ?? Data("{}".utf8), as: UTF8.self), comment)
    }

    private func question(_ n: Int, _ q: DecisionSheet.Question) -> some View {
      VStack(alignment: .leading, spacing: 8) {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
          Text(verbatim: "\(n)").font(Typography.font(Typography.chrome)).foregroundStyle(C.textMuted)
          Text(q.prompt).font(Typography.font(Typography.sidebar)).fontWeight(.semibold).foregroundStyle(C.textPrimary)
            .fixedSize(horizontal: false, vertical: true)
        }
        if let ctx = q.context, !ctx.isEmpty {
          Text(ctx).font(Typography.font(Typography.chrome)).foregroundStyle(C.textSecondary).fixedSize(horizontal: false, vertical: true)
        }
        if q.kind == .text {
          field(tr("任意(空なら agent が決める)"), text: Binding(get: { texts[q.id] ?? "" }, set: { texts[q.id] = $0 }))
        } else {
          ForEach(q.options ?? [], id: \.id) { o in option(q, o) }
          field(tr("補足(任意)"), text: Binding(get: { notes[q.id] ?? "" }, set: { notes[q.id] = $0 }))
        }
      }
      .padding(12).frame(maxWidth: .infinity, alignment: .leading)
      .background(C.surface, in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
      .overlay(RoundedRectangle(cornerRadius: Radius.card, style: .continuous).strokeBorder(L.strong))
      .accessibilityElement(children: .contain)
    }

    private func option(_ q: DecisionSheet.Question, _ o: DecisionSheet.Option) -> some View {
      let on = picked[q.id]?.contains(o.id) == true
      return Button {
        var set = picked[q.id] ?? []
        if q.kind == .multi { if on { set.remove(o.id) } else { set.insert(o.id) } } else { set = on ? [] : [o.id] }
        picked[q.id] = set
      } label: {
        HStack(alignment: .top, spacing: 8) {
          Image(systemName: q.kind == .multi ? (on ? "checkmark.square.fill" : "square") : (on ? "largecircle.fill.circle" : "circle"))
            .font(Typography.font(Typography.chrome)).foregroundStyle(on ? C.textPrimary : C.textMuted).padding(.top, 1)
          VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
              Text(o.label).font(Typography.font(Typography.chrome)).foregroundStyle(C.textPrimary).fixedSize(horizontal: false, vertical: true)
              if q.recommended?.contains(o.id) == true {
                Text(tr("推奨")).font(Typography.font(Typography.sidebarMicro)).foregroundStyle(C.success)
                  .padding(.horizontal, 6).background(C.success.opacity(0.16), in: Capsule())
              }
            }
            if let d = o.detail, !d.isEmpty {
              Text(d).font(Typography.font(Typography.chrome)).foregroundStyle(C.textTertiary).fixedSize(horizontal: false, vertical: true)
            }
            if let html = o.html, let text = try? String(contentsOfFile: html, encoding: .utf8) {
              HTMLWebView(html: text, directory: URL(fileURLWithPath: DecisionSheet.folder(card: card), isDirectory: true))
                .frame(height: 180).clipShape(RoundedRectangle(cornerRadius: Radius.control))
                .overlay(RoundedRectangle(cornerRadius: Radius.control).strokeBorder(L.strong))
                .padding(.top, 6).accessibilityLabel(tr("HTML プレビュー"))
            }
          }
          Spacer(minLength: 0)
        }
        .padding(.horizontal, 10).padding(.vertical, 8).contentShape(Rectangle())
        .background(on ? C.surfaceActive : .clear, in: RoundedRectangle(cornerRadius: Radius.control))
        .overlay(RoundedRectangle(cornerRadius: Radius.control).strokeBorder(on ? L.ring : L.hairlineFaint))
      }
      .buttonStyle(.plain).disabled(!pending)
      .accessibilityAddTraits(on ? [.isButton, .isSelected] : .isButton)
    }

    /// Return inserts a newline here (a TextField would end editing); ⌘Return still sends.
    private var commentEditor: some View {
      TextEditor(text: $comment).scrollContentBackground(.hidden)
        .font(Typography.font(Typography.chrome)).foregroundStyle(C.textPrimary)
        .frame(minHeight: 64, maxHeight: 160).padding(.horizontal, 6).padding(.vertical, 6)
        .overlay(alignment: .topLeading) {
          if comment.isEmpty {
            Text(tr("全体へのコメント(任意)")).font(Typography.font(Typography.chrome)).foregroundStyle(C.textMuted)
              .padding(.horizontal, 11).padding(.vertical, 6).allowsHitTesting(false)
          }
        }
        .overlay(RoundedRectangle(cornerRadius: Radius.control).strokeBorder(L.strong))
        .disabled(!pending).accessibilityLabel(tr("全体へのコメント(任意)"))
    }

    private func field(_ placeholder: String, text: Binding<String>) -> some View {
      TextField(placeholder, text: text, axis: .vertical).lineLimit(1...6).textFieldStyle(.plain)
        .font(Typography.font(Typography.chrome)).foregroundStyle(C.textPrimary)
        .padding(.horizontal, 10).padding(.vertical, 8)
        .overlay(RoundedRectangle(cornerRadius: Radius.control).strokeBorder(L.strong))
        .disabled(!pending)
    }
  }
#endif
