import Foundation

@testable import PlayolaInterviewEditor

/// Captures every call a `ProjectModel` makes to its `ProjectDocumentSink`, so phase/commit/
/// dirtiness behavior is asserted without a real document.
@MainActor
final class ProjectDocumentSinkRecorder {
  struct Commit: Equatable {
    var file: ProjectFile
    var plan: EditPlan?
    var audio: CanonicalAudioSource?
  }
  private(set) var commits: [Commit] = []
  private(set) var registerChangeCount = 0

  fileprivate func recordCommit(
    _ file: ProjectFile, _ plan: EditPlan?, _ audio: CanonicalAudioSource?
  ) {
    commits.append(Commit(file: file, plan: plan, audio: audio))
  }
  fileprivate func recordRegisterChange() {
    registerChangeCount += 1
  }
}

extension ProjectDocumentSink {
  /// A sink wired to a fresh recorder; the tests read the recorder to assert what was committed
  /// and how many changes were registered.
  @MainActor
  static func recorder() -> (sink: ProjectDocumentSink, record: ProjectDocumentSinkRecorder) {
    let record = ProjectDocumentSinkRecorder()
    let sink = ProjectDocumentSink(
      commit: { file, plan, audio in record.recordCommit(file, plan, audio) },
      registerChange: { record.recordRegisterChange() }
    )
    return (sink, record)
  }
}
