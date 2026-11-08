import Foundation
import Testing

@testable import ShellIntegrations

struct LSOutputParserTests {
  static let bsdFixture = """
    total 24
    drwxr-xr-x@ 14 v57  staff   448 Aug 26 20:06 .
    drwxr-xr-x   4 v57  staff   128 Aug 26 20:06 ..
    drwxr-xr-x   5 v57  staff   160 Aug 26 20:06 Apps
    drwxr-xr-x   6 v57  staff   192 Aug 26 20:06 Documents
    -rw-r--r--   1 v57  staff  20480 Aug 26 20:06 release notes.txt
    -rw-r--r--   1 v57  staff  14340 Aug 26 20:06 .DS_Store
    lrwxr-xr-x   1 v57  staff    21 Aug 26 20:06 current -> Documents/Archive 2025
    lrwxr-xr-x   1 v57  staff    21 Aug 26 20:06 my link -> ../src
    """

  static let gnuFixture = """
    total 48
    drwxr-xr-x 5 root root 4096 Aug 26 20:06 .
    drwxr-xr-x 4 root root 4096 Aug 26 20:06 ..
    -rw-r--r-- 1 root root 14340 Aug 26 20:06 .config
    drwxr-xr-x 3 root root 4096 Aug 26 20:06 src
    -rw-r--r-- 1 root root 20480 Aug 26 20:06 release notes.txt
    lrwxrwxrwx 1 root root 21 Aug 26 20:06 current -> ../src/main
    drwxr-xr-x 2 root root 4096 Nov 12 2024 old-archive
    -rw-r--r-- 1 root root 512 Jan  3 2020 deprecated.txt
    """

  private func makeDate(year: Int, month: Int, day: Int, hour: Int, minute: Int) -> Date {
    var components = DateComponents()
    components.year = year
    components.month = month
    components.day = day
    components.hour = hour
    components.minute = minute
    return Calendar.current.date(from: components)!
  }

  private var currentYear: Int { Calendar.current.component(.year, from: Date()) }

  @Test func bsdFixtureParsesInOrderAndSkipsSummaryDots() {
    let rows = LSOutputParser.parse(Self.bsdFixture)
    #expect(
      rows.map(\.name) == [
        "Apps", "Documents", "release notes.txt", ".DS_Store", "current", "my link",
      ])
    #expect(rows.count == 6)
  }

  @Test func bsdDirectoryRow() {
    let apps = LSOutputParser.parse(Self.bsdFixture)[0]
    #expect(apps.name == "Apps")
    #expect(apps.isDirectory)
    #expect(apps.size == 160)
    #expect(apps.symlinkTarget == nil)
    #expect(apps.modified == makeDate(year: currentYear, month: 8, day: 26, hour: 20, minute: 6))
    #expect(LSOutputParser.isDirectory(fromPermissions: apps.permissions!))
  }

  @Test func bsdRegularFileRow() {
    let notes = LSOutputParser.parse(Self.bsdFixture)[2]
    #expect(notes.name == "release notes.txt")
    #expect(!notes.isDirectory)
    #expect(notes.size == 20480)
    #expect(notes.modified == makeDate(year: currentYear, month: 8, day: 26, hour: 20, minute: 6))
    #expect(!LSOutputParser.isDirectory(fromPermissions: notes.permissions!))
  }

  @Test func bsdDotfileRow() {
    let dotfile = LSOutputParser.parse(Self.bsdFixture)[3]
    #expect(dotfile.name == ".DS_Store")
    #expect(dotfile.size == 14340)
    #expect(!dotfile.isDirectory)
  }

  @Test func bsdSymlinkSplitsNameAndTarget() {
    let rows = LSOutputParser.parse(Self.bsdFixture)
    let current = rows[4]
    #expect(current.name == "current")
    #expect(current.isDirectory == false)
    #expect(current.symlinkTarget == "Documents/Archive 2025")
    #expect(LSOutputParser.isSymlink(fromPermissions: current.permissions!))
  }

  @Test func bsdSymlinkWithSpacedName() {
    let myLink = LSOutputParser.parse(Self.bsdFixture)[5]
    #expect(myLink.name == "my link")
    #expect(myLink.symlinkTarget == "../src")
    #expect(LSOutputParser.isSymlink(fromPermissions: myLink.permissions!))
  }

  @Test func gnuFixtureParsesYearDates() {
    let rows = LSOutputParser.parse(Self.gnuFixture)
    #expect(
      rows.map(\.name) == [
        ".config", "src", "release notes.txt", "current", "old-archive", "deprecated.txt",
      ])

    let oldArchive = rows[4]
    #expect(oldArchive.name == "old-archive")
    #expect(oldArchive.isDirectory)
    #expect(oldArchive.size == 4096)
    #expect(oldArchive.modified == makeDate(year: 2024, month: 11, day: 12, hour: 0, minute: 0))

    let deprecated = rows[5]
    #expect(deprecated.name == "deprecated.txt")
    #expect(deprecated.modified == makeDate(year: 2020, month: 1, day: 3, hour: 0, minute: 0))
  }

  @Test func gnuRecentEntryUsesTimeFormat() {
    let config = LSOutputParser.parse(Self.gnuFixture)[0]
    #expect(config.name == ".config")
    #expect(config.modified == makeDate(year: currentYear, month: 8, day: 26, hour: 20, minute: 6))
  }

  @Test func permissionHelpers() {
    #expect(LSOutputParser.isDirectory(fromPermissions: "drwxr-xr-x"))
    #expect(!LSOutputParser.isDirectory(fromPermissions: "-rw-r--r--"))
    #expect(!LSOutputParser.isDirectory(fromPermissions: "lrwxr-xr-x"))
    #expect(LSOutputParser.isSymlink(fromPermissions: "lrwxr-xr-x"))
    #expect(!LSOutputParser.isSymlink(fromPermissions: "-rw-r--r--"))
  }

  /// BusyBox's `ls -la` on a pty (Alpine), as Shell's Files panel got it: every name coloured, CRLF line ends (S-003).
  static let busyBoxColourFixture = [
    "total 12",
    "drwxr-xr-x    3 root     root          4096 Nov  8 18:18 \u{1B}[1;34m.\u{1B}[m",
    "drwxr-xr-x    1 root     root          4096 Nov  8 18:18 \u{1B}[1;34m..\u{1B}[m",
    "-rw-r--r--    1 root     root             0 Nov  8 18:18 \u{1B}[0;0m.ash_history\u{1B}[m",
    "lrwxrwxrwx    1 root     root             2 Nov  8 18:18 \u{1B}[1;36mlink\u{1B}[m -> \u{1B}[1;34mzz\u{1B}[m",
    "-rw-r--r--    1 root     root             0 Nov  8 18:18 \u{1B}[0;0mmy file\u{1B}[m",
    "drwxr-xr-x    2 root     root          4096 Nov  8 18:18 \u{1B}[1;34mzz\u{1B}[m",
  ].joined(separator: "\r\n")

  @Test func busyBoxColouredListingParsesPlainNamesWithoutDots() {
    let rows = LSOutputParser.parse(Self.busyBoxColourFixture)
    #expect(rows.map(\.name) == [".ash_history", "link", "my file", "zz"])
    #expect(rows[1].symlinkTarget == "zz")
    #expect(rows[3].isDirectory)
    #expect(rows[3].size == 4096)
    #expect(rows[3].modified == makeDate(year: currentYear, month: 11, day: 8, hour: 18, minute: 18))
  }

  @Test func escapesAreDroppedFromALine() {
    #expect(LSOutputParser.withoutEscapes("\u{1B}[01;34mdir\u{1B}[0m") == "dir")
    // ls --hyperlink: OSC 8 links ended by ESC \ or BEL.
    #expect(LSOutputParser.withoutEscapes("\u{1B}]8;;file:///a\u{1B}\\a\u{1B}]8;;\u{07}") == "a")
    #expect(LSOutputParser.withoutEscapes("plain name") == "plain name")
  }
}
