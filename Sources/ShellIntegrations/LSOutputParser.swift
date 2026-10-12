import Foundation

/// A pure text parser that turns raw `ls -la` output into `[FileRow]` values.
///
/// This phase does no filesystem access — it only decodes the textual listing a
/// peer (e.g. an SSH session) returned, so a directory viewer can render rows
/// without re-enumerating the directory itself.
public enum LSOutputParser {
  private static let monthNames = [
    "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec",
  ]

  /// Parse raw `ls -la` output into rows, in the order they appeared.
  ///
  /// Skips the `total N` summary line, blank lines, and the `.` / `..` entries.
  /// The leading fixed columns (mode, links, owner, group, size, month, day,
  /// time/year) are split first; everything after them is the name. This keeps
  /// names that contain spaces intact rather than splitting them on whitespace.
  public static func parse(_ text: String) -> [FileRow] {
    var rows: [FileRow] = []
    for line in text.split(whereSeparator: { $0.isNewline }) {
      let trimmed = line.drop(while: { $0.isWhitespace })
      guard !trimmed.isEmpty else { continue }
      let lineString = String(trimmed)
      guard !lineString.hasPrefix("total ") else { continue }

      let tokens = trimmed.split(whereSeparator: { $0.isWhitespace })
      guard tokens.count >= 8 else { continue }

      let permissions = String(tokens[0])
      let isDirectory = self.isDirectory(fromPermissions: permissions)
      let isSymlink = self.isSymlink(fromPermissions: permissions)
      let size = Int64(tokens[4])
      let modified = parseDate(
        month: String(tokens[5]), day: tokens[6], timeOrYear: String(tokens[7]))

      // The name is everything after the 8th column, preserving internal spaces.
      let name = String(trimmed[tokens[7].endIndex...].drop(while: { $0.isWhitespace }))
      guard !name.isEmpty else { continue }
      guard name != "." && name != ".." else { continue }

      var rowName = name
      var symlinkTarget: String?
      if isSymlink, let range = name.range(of: " -> ") {
        symlinkTarget = String(name[range.upperBound...])
        rowName = String(name[..<range.lowerBound])
      }

      rows.append(
        FileRow(
          name: rowName, isDirectory: isDirectory, size: size, modified: modified,
          permissions: permissions, symlinkTarget: symlinkTarget))
    }
    return rows
  }

  /// Whether a permission string denotes a directory (leading `d`).
  public static func isDirectory(fromPermissions permissions: String) -> Bool {
    permissions.hasPrefix("d")
  }

  /// Whether a permission string denotes a symbolic link (leading `l`).
  public static func isSymlink(fromPermissions permissions: String) -> Bool {
    permissions.hasPrefix("l")
  }

  /// Build a `Date` from the date columns, accepting BSD (`Mon DD HH:MM`) and
  /// GNU (`Mon DD  YYYY`) formats. Returns `nil` when the columns cannot be parsed.
  private static func parseDate(month: String, day: Substring, timeOrYear: String) -> Date? {
    guard let monthIndex = monthNames.firstIndex(of: month) else { return nil }
    guard let dayNumber = Int(day) else { return nil }

    let calendar = Calendar.current
    var components = DateComponents()
    components.month = monthIndex + 1
    components.day = dayNumber

    if timeOrYear.contains(":") {
      // BSD: `HH:MM` in the current year.
      let parts = timeOrYear.split(separator: ":").compactMap { Int($0) }
      guard parts.count == 2 else { return nil }
      components.year = calendar.component(.year, from: Date())
      components.hour = parts[0]
      components.minute = parts[1]
    } else {
      // GNU: the final column is an explicit 4-digit year at midnight.
      guard let year = Int(timeOrYear) else { return nil }
      components.year = year
      components.hour = 0
      components.minute = 0
    }

    return calendar.date(from: components)
  }
}
