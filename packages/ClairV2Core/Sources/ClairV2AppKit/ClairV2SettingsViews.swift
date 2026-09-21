#if os(macOS)
  import ClairV2DesignSystem
  import SwiftUI

  private typealias C = DesignTokens.Color
  private typealias L = DesignTokens.Line

  /// Mock `Settings.tsx` building blocks: a card of rows, each row a title (+ note) and one control.
  struct SettingsCard<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content
    var body: some View {
      VStack(alignment: .leading, spacing: 16) {
        Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(C.textPrimary)
        VStack(spacing: 0) { content }
      }
      .padding(.horizontal, 22).padding(.vertical, 20)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(C.chrome, in: RoundedRectangle(cornerRadius: Radius.card))
    }
  }

  struct SettingsRow<Control: View>: View {
    let title: String
    var note: String?
    @ViewBuilder var control: Control
    var body: some View {
      HStack(spacing: 12) {
        VStack(alignment: .leading, spacing: 2) {
          Text(title).font(.system(size: 12, weight: .semibold)).foregroundStyle(C.textPrimary)
          if let note { Text(note).font(.system(size: 11)).foregroundStyle(C.textTertiary).fixedSize(horizontal: false, vertical: true) }
        }
        Spacer(minLength: 12)
        control
      }
      .frame(minHeight: 52).padding(.vertical, 12)
      .overlay(alignment: .top) { Rectangle().fill(L.hairlineSoft).frame(height: 1) }
    }
  }

  /// A closed set of more than two values; selection is lightness only (`surfaceActive`), no new hue.
  struct SettingsSegmented: View {
    let options: [String]
    let value: String
    let onChange: (String) -> Void
    var body: some View {
      HStack(spacing: 0) {
        ForEach(options, id: \.self) { o in
          let on = o == value
          Button { onChange(o) } label: {
            Text(o).font(.system(size: 11, weight: on ? .semibold : .regular))
              .foregroundStyle(on ? C.textPrimary : C.textSecondary)
              .padding(.horizontal, 10).frame(height: 26).background(on ? C.surfaceActive : .clear)
          }.buttonStyle(.plain)
        }
      }
      .clipShape(RoundedRectangle(cornerRadius: Radius.control))
      .overlay(RoundedRectangle(cornerRadius: Radius.control).stroke(L.hairline))
    }
  }

  struct SettingsSwitch: View {
    let on: Bool
    let onChange: (Bool) -> Void
    var body: some View {
      Button { onChange(!on) } label: {
        Capsule().fill(on ? C.textSecondary : C.surfaceActive).frame(width: 34, height: 20)
          .overlay(alignment: on ? .trailing : .leading) {
            Circle().fill(on ? C.canvas : C.textTertiary).frame(width: 14, height: 14).padding(3)
          }
          .animation(.easeOut(duration: 0.12), value: on)
      }
      .buttonStyle(.plain).accessibilityAddTraits(.isButton).accessibilityValue(on ? "オン" : "オフ")
    }
  }

  /// Read-only value box (the mock's `FieldValue`).
  struct SettingsField: View {
    let text: String
    var body: some View {
      Text(text).font(.system(size: 11)).foregroundStyle(C.textSecondary).lineLimit(1)
        .padding(.horizontal, 8).frame(minHeight: 26)
        .background(C.chrome, in: RoundedRectangle(cornerRadius: Radius.control))
        .overlay(RoundedRectangle(cornerRadius: Radius.control).stroke(L.hairline))
    }
  }
#endif
