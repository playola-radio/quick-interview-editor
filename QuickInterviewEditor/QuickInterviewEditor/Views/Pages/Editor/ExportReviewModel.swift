import Dependencies
import Foundation
import Observation

@MainActor
@Observable
final class ExportReviewModel: ViewModel, Identifiable {
  // MARK: - Dependencies
  @ObservationIgnored @Dependency(\.exportCopy) var copyClient

  // MARK: - Shared State

  // MARK: - Initialization
  init(request: ExportCopyRequest, scratchDirectory: URL?) {
    self.request = request
    self.scratchDirectory = scratchDirectory
    super.init()
  }

  deinit {
    if let scratchDirectory { try? FileManager.default.removeItem(at: scratchDirectory) }
  }

  // MARK: - Properties
  private var request: ExportCopyRequest
  let scratchDirectory: URL?
  private(set) var mappings: [ExportNameMapping] = []
  private(set) var isCopying = false
  @ObservationIgnored var onExport: ([ExportNameMapping]) -> Void = { _ in }
  @ObservationIgnored var onReviewNames: () -> Void = {}

  // MARK: - View Helpers
  let title = "Review Export Filenames"
  let warning =
    "A file with this name already exists or is included twice. Check your clip names or starting numbers."
  let requestedLabel = "Clip filename"
  let proposedLabel = "Export filename"
  let reviewNamesLabel = "Review Names"
  let exportWithSuffixesLabel = "Export with Suffixes"
  let copiedTitle = "Already Exported"
  let helpText =
    "Only these filenames will change. Your clip names and starting numbers stay the same."
  var copied: [ExportCopiedFile] { request.copied }
  var copiedRows: [ExportCopiedRow] {
    copied.map { .init(id: $0.id, title: $0.url.lastPathComponent) }
  }
  var showsCopied: Bool { !copied.isEmpty }
  var total: Int { request.targets.count }
  var progressLabel: String { "\(copied.count) of \(total) exported" }
  var canApprove: Bool { !isCopying && !mappings.isEmpty }

  // MARK: - User Actions
  func reviewNamesTapped() {
    onReviewNames()
  }

  func exportWithSuffixesTapped() {
    guard canApprove else { return }
    onExport(mappings)
  }

  func copy(approved: [ExportNameMapping]?) async -> ExportCopyOutcome {
    isCopying = true
    defer { isCopying = false }
    request.approvedMappings = approved
    let outcome = await copyRenderedExports(request, client: copyClient)
    request.copied = outcome.copied
    mappings = outcome.reviewMappings ?? []
    return outcome
  }

  func cleanup() async {
    await Self.removeScratch(scratchDirectory)
  }

  // MARK: - Private Helpers
  private nonisolated static func removeScratch(_ directory: URL?) async {
    if let directory { try? FileManager.default.removeItem(at: directory) }
  }
}

struct ExportCopiedRow: Identifiable {
  var id: UUID
  var title: String
}
