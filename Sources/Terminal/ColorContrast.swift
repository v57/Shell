import SwiftUI

/// Contrast math and the "replace low-contrast colors with primary" policy
/// used when character backgrounds are disabled.
///
/// The terminal window background is a DYNAMIC system color
/// (NSColor.windowBackgroundColor), which has no resolvable RGB until paint
/// time. Contrast decisions therefore compare against fixed sRGB
/// approximations of that color per appearance scheme, so the math is pure
/// and memoizable:
///   dark  ≈ #272727 (0.153)    light ≈ #ECECEC (0.925)
public enum TerminalContrast {
  /// The floor below which an explicit foreground is considered unreadable
  /// and replaced with `.primary`. 1.8 keeps mid-grays on light, kills
  /// bright-white-on-light and near-black-on-dark. Tunable.
  public static let minimumRatio: CGFloat = 1.8

  // MARK: - Scheme backgrounds used for contrast decisions

  public static let darkBackground: (r: CGFloat, g: CGFloat, b: CGFloat) = (0.153, 0.153, 0.153)
  public static let lightBackground: (r: CGFloat, g: CGFloat, b: CGFloat) = (0.925, 0.925, 0.925)

  public static func background(for scheme: ColorScheme) -> (r: CGFloat, g: CGFloat, b: CGFloat) {
    scheme == .dark ? darkBackground : lightBackground
  }

  // MARK: - Pure math

  /// WCAG relative luminance of linearized sRGB components.
  public static func luminance(r: CGFloat, g: CGFloat, b: CGFloat) -> CGFloat {
    func linear(_ c: CGFloat) -> CGFloat {
      c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
    }
    let R = linear(r), G = linear(g), B = linear(b)
    return 0.2126 * R + 0.7152 * G + 0.0722 * B
  }

  public static func contrastRatio(
    _ a: (r: CGFloat, g: CGFloat, b: CGFloat),
    _ b: (r: CGFloat, g: CGFloat, b: CGFloat)
  ) -> CGFloat {
    let la = luminance(r: a.r, g: a.g, b: a.b)
    let lb = luminance(r: b.r, g: b.g, b: b.b)
    let lighter = max(la, lb), darker = min(la, lb)
    return (lighter + 0.05) / (darker + 0.05)
  }

  /// Whether an explicit color falls below the readability floor against
  /// the scheme's terminal background. Only .rgb/.ansi have components;
  /// .clear/.default answer false (the caller renders those as primary).
  public static func isLowContrast(_ color: TerminalColor, on scheme: ColorScheme) -> Bool {
    guard let c = color.colorComponents() else { return false }
    return contrastRatio(c, background(for: scheme)) < minimumRatio
  }

  // MARK: - Memoized decision (rendering path)

  /// True when the explicit color gets replaced by `.primary` in
  /// background-suppressed rendering. The decision is pure and stable per
  /// (color, scheme), and truecolor apps reuse colors constantly, so memoize
  /// it. Process-lifetime; never invalidated (the mapping is fixed).
  private static var decisionCache: [TerminalColor: [ColorScheme: Bool]] = [:]

  public static func shouldReplace(withPrimary color: TerminalColor, on scheme: ColorScheme) -> Bool {
    if let byScheme = decisionCache[color], let cached = byScheme[scheme] { return cached }
    let decision = isLowContrast(color, on: scheme)
    decisionCache[color, default: [:]][scheme] = decision
    return decision
  }

  /// The foreground for a cell's own color when character backgrounds are
  /// suppressed: .default/.clear → primary; explicit colors → primary when
  /// low contrast, the color itself otherwise.
  public static func suppressedBackgroundForeground(for color: TerminalColor, scheme: ColorScheme) -> Color {
    switch color {
    case .clear, .default:
      return Color.primary
    case .rgb, .ansi:
      return shouldReplace(withPrimary: color, on: scheme) ? Color.primary : (color.color ?? Color.primary)
    }
  }
}

extension EnvironmentValues {
  /// Suppresses per-character background fills and replaces low-contrast
  /// foreground colors with primary (the "Disable Background Colors" theme
  /// option). Default false → current rendering unchanged.
  @Entry public var terminalBackgroundsDisabled = false
}
