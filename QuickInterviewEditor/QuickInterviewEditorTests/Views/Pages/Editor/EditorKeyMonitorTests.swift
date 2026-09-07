import AppKit
import CustomDump
import Testing

@testable import PlayolaInterviewEditor

@MainActor
struct EditorKeyMonitorTests {
  private func key(
    _ keyCode: UInt16, _ modifiers: NSEvent.ModifierFlags = [], characters: String? = nil
  ) -> EditorKey? {
    EditorKeyMonitor.Coordinator.editorKey(
      forKeyCode: keyCode, modifiers: modifiers, characters: characters)
  }

  @Test func shiftCommaAndPeriodStepSpeedDownAndUp() {
    expectNoDifference(key(43, .shift), .speedDown)  // Shift-, = <
    expectNoDifference(key(47, .shift), .speedUp)  // Shift-. = >
  }

  @Test func unshiftedCommaAndPeriodAreNotSpeedKeys() {
    expectNoDifference(key(43), nil)  // plain , must not change speed
    expectNoDifference(key(47), nil)  // plain . must not change speed
  }

  @Test func commandArrowsStillZoom() {
    expectNoDifference(key(123, .command), .zoomOut)  // ⌘←
    expectNoDifference(key(124, .command), .zoomIn)  // ⌘→
  }

  @Test func plainZZoomsToFit() {
    expectNoDifference(key(6, [], characters: "z"), .zoomFit)
  }

  @Test func plainDeleteMapsToRemoveSection() {
    expectNoDifference(key(51), .removeSection)  // ⌫
  }

  @Test func modifiedDeleteFallsThrough() {
    expectNoDifference(key(51, .command), nil)  // ⌘⌫
    expectNoDifference(key(51, .option), nil)  // ⌥⌫
  }

  @Test func plainEscapeMapsToEscape() {
    expectNoDifference(key(53), .escape)  // Esc
  }

  @Test func modifiedEscapeFallsThrough() {
    expectNoDifference(key(53, .command), nil)  // ⌘Esc
  }

  @Test func plainArrowsNudgeCutIn() {
    expectNoDifference(key(123), .nudgeCutInEarlier)  // ←
    expectNoDifference(key(124), .nudgeCutInLater)  // →
  }

  @Test func shiftArrowsNudgeCutOut() {
    expectNoDifference(key(123, .shift), .nudgeCutOutEarlier)  // ⇧←
    expectNoDifference(key(124, .shift), .nudgeCutOutLater)  // ⇧→
  }

  @Test func commandDigitsSwitchRightPanel() {
    expectNoDifference(key(18, .command, characters: "1"), .showClipsPanel)  // ⌘1
    expectNoDifference(key(19, .command, characters: "2"), .showSuggestionsPanel)  // ⌘2
    expectNoDifference(key(20, .command, characters: "3"), .showBothPanels)  // ⌘3
  }

  @Test func unmodifiedDigitsFallThrough() {
    expectNoDifference(key(18, characters: "1"), nil)
    expectNoDifference(key(19, characters: "2"), nil)
    expectNoDifference(key(20, characters: "3"), nil)
  }

  @Test func differentlyModifiedDigitsFallThrough() {
    expectNoDifference(key(18, .shift, characters: "1"), nil)
    expectNoDifference(key(19, .option, characters: "2"), nil)
    expectNoDifference(key(20, [.command, .shift], characters: "3"), nil)
  }
}
