import AppKit
import CustomDump
import Testing

@testable import QuickInterviewEditor

@MainActor
struct SliceEditKeyMonitorTests {
  private func key(
    _ keyCode: UInt16, _ modifiers: NSEvent.ModifierFlags = [], characters: String? = nil
  ) -> SliceEditKeyMonitor.SliceEditKey? {
    SliceEditKeyMonitor.Coordinator.sliceEditKey(
      forKeyCode: keyCode, modifiers: modifiers, characters: characters)
  }

  @Test func plainBracketsAuditionTheCutEdges() {
    expectNoDifference(key(33), .auditionIn)  // [
    expectNoDifference(key(30), .auditionOut)  // ]
  }

  @Test func modifiedBracketsFallThrough() {
    expectNoDifference(key(33, .command), nil)  // ⌘[ (Logic's "previous section")
    expectNoDifference(key(30, .command), nil)  // ⌘]
    expectNoDifference(key(33, .option), nil)  // ⌥[
    expectNoDifference(key(30, .control), nil)  // ⌃]
  }

  @Test func plainSpaceIsTheTransport() {
    expectNoDifference(key(49), .space)
  }

  @Test func modifiedSpaceFallsThrough() {
    expectNoDifference(key(49, .command), nil)  // ⌘Space (Spotlight)
    expectNoDifference(key(49, .option), nil)  // ⌥Space
  }

  @Test func commandZUndoesAndCommandShiftZRedoes() {
    expectNoDifference(key(6, .command, characters: "z"), .undo)  // ⌘Z
    expectNoDifference(key(6, [.command, .shift], characters: "Z"), .redo)  // ⌘⇧Z
  }

  @Test func optionZFallsThrough() {
    expectNoDifference(key(6, .option, characters: "z"), nil)  // ⌥Z
  }

  @Test func zoomKeysStayInLockstepWithTheMainEditor() {
    expectNoDifference(key(123, .command), .zoom(.zoomOut))  // ⌘←
    expectNoDifference(key(124, .command), .zoom(.zoomIn))  // ⌘→
    expectNoDifference(key(6, [], characters: "z"), .zoom(.zoomFit))  // Z
  }

  @Test func plainDeleteMapsToRemoveSection() {
    expectNoDifference(key(51), .zoom(.removeSection))  // ⌫
  }
}
