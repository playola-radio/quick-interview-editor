import CustomDump
import Foundation
import Testing

@testable import PlayolaInterviewEditor

/// Pure decision and wording coverage for the first-launch relocation nudge. The actual
/// move is a thin side effect (guarded out of DEBUG/tests) and is not unit-tested.
struct InstallLocationTests {

  @Test func moveFailureMessageNamesTheCauseAndTheManualFix() {
    let error = CocoaError(.fileWriteNoPermission)
    expectNoDifference(
      InstallLocation.moveFailedMessage(for: error),
      "\(error.localizedDescription)\n\nYou can move Playola Interview Editor yourself by "
        + "dragging it into Applications in Finder. Auto-update works best once it lives there.")
  }

  @Test func relaunchFailureMessageNamesTheCauseAndHowToOpenTheMovedCopy() {
    let error = CocoaError(.fileReadNoSuchFile)
    expectNoDifference(
      InstallLocation.relaunchFailedMessage(for: error),
      "The app was moved to your Applications folder, but the moved copy couldn't be opened: "
        + "\(error.localizedDescription)\n\nQuit this copy, then open Playola Interview Editor "
        + "from your Applications folder.")
  }

  @Test func fromApplicationsFolderNoOffer() {
    expectNoDifference(
      InstallLocation.shouldOfferMoveToApplications(
        bundlePath: "/Applications/PlayolaInterviewEditor.app",
        isTranslocated: false),
      false)
  }

  @Test func fromDiskImageOffers() {
    expectNoDifference(
      InstallLocation.shouldOfferMoveToApplications(
        bundlePath: "/Volumes/PlayolaInterviewEditor/PlayolaInterviewEditor.app",
        isTranslocated: false),
      true)
  }

  @Test func translocatedOffers() {
    expectNoDifference(
      InstallLocation.shouldOfferMoveToApplications(
        bundlePath:
          "/private/var/folders/xy/AppTranslocation/ABC/d/PlayolaInterviewEditor.app",
        isTranslocated: true),
      true)
  }

  @Test func fromUserApplicationsNoOffer() {
    let home = NSHomeDirectory()
    expectNoDifference(
      InstallLocation.shouldOfferMoveToApplications(
        bundlePath: "\(home)/Applications/PlayolaInterviewEditor.app",
        isTranslocated: false),
      false)
  }
}
