import CustomDump
import Foundation
import Testing

@testable import PlayolaInterviewEditor

/// Pure decision coverage for the first-launch relocation nudge. The actual move
/// is a thin side effect (guarded out of DEBUG/tests) and is not unit-tested.
struct InstallLocationTests {

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
