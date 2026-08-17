import CustomDump
import Foundation
import Testing

@testable import QuickInterviewEditor

/// Pure decision coverage for the first-launch relocation nudge. The actual move
/// is a thin side effect (guarded out of DEBUG/tests) and is not unit-tested.
struct InstallLocationTests {

  @Test func fromApplicationsFolderNoOffer() {
    expectNoDifference(
      InstallLocation.shouldOfferMoveToApplications(
        bundlePath: "/Applications/QuickInterviewEditor.app",
        isTranslocated: false),
      false)
  }

  @Test func fromDiskImageOffers() {
    expectNoDifference(
      InstallLocation.shouldOfferMoveToApplications(
        bundlePath: "/Volumes/QuickInterviewEditor/QuickInterviewEditor.app",
        isTranslocated: false),
      true)
  }

  @Test func translocatedOffers() {
    expectNoDifference(
      InstallLocation.shouldOfferMoveToApplications(
        bundlePath:
          "/private/var/folders/xy/AppTranslocation/ABC/d/QuickInterviewEditor.app",
        isTranslocated: true),
      true)
  }

  @Test func fromUserApplicationsNoOffer() {
    let home = NSHomeDirectory()
    expectNoDifference(
      InstallLocation.shouldOfferMoveToApplications(
        bundlePath: "\(home)/Applications/QuickInterviewEditor.app",
        isTranslocated: false),
      false)
  }
}
