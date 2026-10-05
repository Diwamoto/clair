import CoreGraphics

/// Desktop corner radius — 3 steps (`radius` in `tokens.ts` / checklist
/// §2.3).
public enum Radius {
  public static let control: CGFloat = 4
  public static let card: CGFloat = 6
  public static let overlay: CGFloat = 10
}

/// Desktop spacing scale — 7 steps (`space` in `tokens.ts` / checklist
/// §2.3).
public enum Spacing {
  public static let scale: [CGFloat] = [2, 4, 6, 8, 12, 16, 24]
}

/// Vertical chrome budget shared by every Mac IDE screen: titlebar + status
/// bar = 74px (`chrome` in `tokens.ts` / checklist §2.4). The editor
/// breadcrumb is a documented, intentional exception to this budget
/// (checklist §2.7) and is not modeled here — that is a screen-level
/// concern for `U04`/`U05`, not a token.
public enum ChromeBudget {
  /// Shared module of the two chrome strips: the titlebar's height and the
  /// activity bar's width are one cell, and the selectable control inside
  /// either (a tab, a rail icon) is one `cellControl` box with the same 5pt
  /// inset (checklist §2.4).
  public static let cell: CGFloat = 48
  public static let cellControl: CGFloat = 38
  public static let titlebar: CGFloat = cell
  /// Left vertical nav strip — was a horizontal row nested at the top of
  /// the sidebar panel (`sidebarStrip`, now unused); it sits outside the
  /// panel as its own full-height column instead (checklist §2.4,
  /// 2026-09-20 amendment).
  public static let activityBarWidth: CGFloat = cell
  public static let statusBar: CGFloat = 26
}

/// Mobile-only dimensions (checklist §2.6, "Tokens artboard MOBILE 節").
/// Mobile uses its own radius rule (card 10 / button+field 8), distinct
/// from the desktop 4-6-10 scale above.
public enum MobileMetrics {
  public static let viewportWidth: CGFloat = 390
  public static let viewportHeight: CGFloat = 844
  /// Space reserved at the top for the real device status bar; the mock
  /// does not paint a fake one and native shouldn't either.
  public static let statusBarInset: CGFloat = 54
  public static let tabBarHeight: CGFloat = 78
  public static let gutter: CGFloat = 16
  public static let touchTarget: CGFloat = 44

  public enum Radius {
    public static let card: CGFloat = 10
    public static let button: CGFloat = 8
    public static let field: CGFloat = 8
  }
}
