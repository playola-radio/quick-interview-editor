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
}
