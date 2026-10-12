import CoreGraphics
import Testing
@testable import ShellKit

/// The macOS 14 / iOS 17 content offset, derived from the anchor line because
/// `onScrollGeometryChange` needs macOS 15 / iOS 18. Expected values are what
/// `onScrollGeometryChange` reported on macOS 27 (402 lines, 18 rows,
/// lineHeight 21, a 398 pt scroll view).
@MainActor
struct ContentOffsetFallbackTests {
  private func offset(anchor: Int, totalLines: Int = 402) -> CGFloat {
    TerminalScreenView.ScrollModifier.ContentOffsetModifier.fallbackOffset(
      anchorLine: anchor, rows: 18, totalLines: totalLines, lineHeight: 21, containerHeight: 398
    )
  }

  @Test func bottomMatchesTheScrollView() {
    // 398 - (402 * 21 + 2 * 4): the grid sits 12 pt below anchor * lineHeight.
    #expect(offset(anchor: 384) == -8052)
  }

  @Test func topAndShortContentAreZero() {
    #expect(offset(anchor: 0) == 0)
    // Content shorter than the scroll view never scrolls.
    #expect(offset(anchor: 0, totalLines: 18) == 0)
  }

  @Test func scrolledUpIsWithinOneLine() {
    // Reported -7952 with anchor 378 (the top line partly scrolled out).
    #expect(abs(offset(anchor: 378) - -7952) < 21)
    #expect(offset(anchor: 382) == -8022)
  }
}
