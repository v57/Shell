import Foundation
import Testing

@testable import TerminalIntegrations

/// Tests for the persistent-session remote scanner parsing, origin tagging,
/// session-name uniquify, and the model distinctions that the app's merged
/// Local section relies on.
///
/// These drive the SAME `ScreenSessionsParser`/`ScreenSessionInfo` the app's
/// local poller and remote scanner use, so a change here reflects real
/// behaviour rather than a re-implementation.
struct PersistentSessionTests {
  // MARK: - tmux `ls -F` parsing

  @Test func tmuxParsesNameAndAttachedFlag() {
    let rows = ScreenSessionsParser.parseTmuxOutput("web 0\napi 1\n")
    #expect(rows.count == 2)
    #expect(rows[0].name == "web")
    #expect(rows[0].pid == 0)
    #expect(rows[0].state == "0")
    #expect(rows[0].kind == .tmux)
    #expect(rows[1].name == "api")
    #expect(rows[1].state == "1")
  }

  @Test func tmuxSkipsMalformedLines() {
    let rows = ScreenSessionsParser.parseTmuxOutput("web 0\nbadline\nno\napi 1\n")
    #expect(rows.map(\.name) == ["web", "api"])
  }

  @Test func tmuxEmptyOutputYieldsNothing() {
    #expect(ScreenSessionsParser.parseTmuxOutput("").isEmpty)
  }

  // MARK: - screen `-ls` parsing

  @Test func screenParsesPidDotNameAndState() {
    let text = "\t26040.hermes-test\t(Detached)\n\t23539.swiftui-optimization\t(Attached)\n"
    let rows = ScreenSessionsParser.parseScreenOutput(text)
    #expect(rows.count == 2)
    #expect(rows[0].name == "26040.hermes-test")
    #expect(rows[0].pid == 26040)
    #expect(rows[0].state == "Detached")
    #expect(rows[0].kind == .screen)
    #expect(rows[1].name == "23539.swiftui-optimization")
    #expect(rows[1].state == "Attached")
  }

  @Test func screenSkipsMalformedLines() {
    // Lines that aren't "<pid>.<name> (<state>)" are ignored (headers, the
    // "No Sockets found" empty-state banner, stray text).
    let text = "There are screens on:\n\t26040.hermes-test\t(Detached)\nnot a session\n\tfoo (no state)\n"
    let rows = ScreenSessionsParser.parseScreenOutput(text)
    #expect(rows.count == 1)
    #expect(rows[0].name == "26040.hermes-test")
  }

  @Test func screenEmptyStateYieldsNothing() {
    #expect(ScreenSessionsParser.parseScreenOutput("No Sockets found in /tmp/uscreens/100-.\n").isEmpty)
  }

  // MARK: - Remote origin tagging (local vs remote)

  @Test func tmuxParseTagsRemoteOrigin() {
    let origin = ScreenRemoteOrigin(sshConfigID: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!, displayName: "prod")
    let rows = ScreenSessionsParser.parse(command: ScreenSessionsParser.tmuxListCommand, text: "web 0\napi 1\n", origin: origin)
    #expect(rows.count == 2)
    #expect(rows.allSatisfy { $0.isRemote })
    #expect(rows.allSatisfy { $0.remoteOrigin == origin })
    #expect(rows[0].name == "web")
    #expect(rows[0].kind == .tmux)
  }

  @Test func screenParseTagsRemoteOrigin() {
    let origin = ScreenRemoteOrigin(sshConfigID: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!, displayName: "staging")
    let rows = ScreenSessionsParser.parse(command: ScreenSessionsParser.screenListCommand, text: "\t26040.hermes-test\t(Detached)\n", origin: origin)
    #expect(rows.count == 1)
    #expect(rows[0].isRemote)
    #expect(rows[0].remoteOrigin == origin)
    #expect(rows[0].kind == .screen)
  }

  @Test func remoteOriginDistinguishesLocalVersusRemoteRows() {
    let origin = ScreenRemoteOrigin(sshConfigID: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!, displayName: "prod")
    let local = ScreenSessionInfo(name: "26040.hermes-test", pid: 26040, state: "Detached", kind: .screen)
    let remote = ScreenSessionInfo(name: "26040.hermes-test", pid: 26040, state: "Detached", kind: .screen, remoteOrigin: origin)

    #expect(local.isRemote == false)
    #expect(remote.isRemote == true)
    // Local row keeps the legacy "kind:name" identity; remote rows must
    // namespace by ssh config id so two hosts owning a same-named session
    // don't collide in the merged List.
    #expect(local.id == "screen:26040.hermes-test")
    #expect(remote.id == "screen:26040.hermes-test@11111111-1111-1111-1111-111111111111")
    // Distinct selection tags, and the local tag matches what it was before
    // remote origins existed (seed is name-only).
    #expect(local.tagID != remote.tagID)
    #expect(local.tagID == ScreenSessionInfo(name: "26040.hermes-test", pid: 26040, state: "Detached", kind: .screen).tagID)
    #expect(remote.tagID == ScreenSessionInfo(
      name: "26040.hermes-test", pid: 26040, state: "Detached", kind: .screen, remoteOrigin: origin).tagID)
  }

  @Test func differentHostsWithSameSessionNameDoNotCollide() {
    let a = ScreenRemoteOrigin(sshConfigID: UUID(uuidString: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa")!, displayName: "alpha")
    let b = ScreenRemoteOrigin(sshConfigID: UUID(uuidString: "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb")!, displayName: "beta")
    let ra = ScreenSessionInfo(name: "hermes-test", pid: 0, state: "0", kind: .tmux, remoteOrigin: a)
    let rb = ScreenSessionInfo(name: "hermes-test", pid: 0, state: "0", kind: .tmux, remoteOrigin: b)
    #expect(ra.id != rb.id)
    #expect(ra.tagID != rb.tagID)
  }

  // MARK: - Model helpers the Local section uses

  @Test func shortNameStripsScreenPidPrefixAndLeavesTmuxName() {
    #expect(ScreenSessionInfo(name: "26040.hermes-test", pid: 26040, state: "Detached", kind: .screen).shortName == "hermes-test")
    #expect(ScreenSessionInfo(name: "hermes-test", pid: 0, state: "0", kind: .tmux).shortName == "hermes-test")
  }

  @Test func isAttachedFromRawState() {
    // tmux: 1 = attached, 0 = detached.
    #expect(ScreenSessionsParser.parseTmuxOutput("sess 1")[0].isAttached)
    #expect(!ScreenSessionsParser.parseTmuxOutput("sess 0")[0].isAttached)
    // screen: "Attached" (case-insensitive) is attached; "Detached"/"Multi, detached" are not.
    #expect(ScreenSessionsParser.parseScreenOutput("\t23539.sess\t(Attached)\n")[0].isAttached)
    #expect(!ScreenSessionsParser.parseScreenOutput("\t23539.sess\t(Detached)\n")[0].isAttached)
    #expect(!ScreenSessionsParser.parseScreenOutput("\t23539.sess\t(Multi, detached)\n")[0].isAttached)
  }

  // MARK: - next-session-name uniquify

  @Test func nextSessionNameReturnsZshWhenFree() {
    #expect(ScreenSessionsParser.nextSessionName(existing: []) == "zsh")
    #expect(ScreenSessionsParser.nextSessionName(existing: ["web", "api"]) == "zsh")
  }

  @Test func nextSessionNameIncrementsPastTakenNames() {
    #expect(ScreenSessionsParser.nextSessionName(existing: ["zsh"]) == "zsh-1")
    #expect(ScreenSessionsParser.nextSessionName(existing: ["zsh", "zsh-1"]) == "zsh-2")
    #expect(ScreenSessionsParser.nextSessionName(existing: ["zsh", "zsh-1", "zsh-2", "zsh-3"]) == "zsh-4")
  }

  @Test func nextSessionNamePicksLowestGap() {
    // The algorithm walks up from 1, so it fills the lowest free slot.
    #expect(ScreenSessionsParser.nextSessionName(existing: ["zsh", "zsh-2"]) == "zsh-1")
  }
}
