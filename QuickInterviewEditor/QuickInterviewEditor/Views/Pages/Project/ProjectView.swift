import SwiftUI
import UniformTypeIdentifiers

/// One project window: empty state, transcription progress, failure, or the editor. Every
/// string and every decision comes from `ProjectModel`.
struct ProjectView: View {
  @Bindable var model: ProjectModel

  var body: some View {
    content
      .frame(minWidth: 1040, minHeight: 680)
      .background(Color.black)
      .toolbar { saveStatusToolbar }
      .dropDestination(for: URL.self) { urls, _ in model.fileDropped(urls) }
      .fileImporter(
        isPresented: $model.isImporterPresented,
        allowedContentTypes: [.audio]
      ) { result in
        switch result {
        case .success(let url): model.filePicked(url)
        case .failure(let error): model.filePickFailed(error)
        }
      }
  }

  @ToolbarContentBuilder private var saveStatusToolbar: some ToolbarContent {
    if model.showsSaveStatus {
      ToolbarItem(placement: .automatic) {
        HStack(spacing: 6) {
          if model.isSaving {
            ProgressView().controlSize(.small)
          }
          Text(model.saveStatusLabel)
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }
    }
  }

  @ViewBuilder private var content: some View {
    if model.showsEmptyState {
      emptyState
    } else if model.showsProgress {
      progress
    } else if model.showsError {
      failure
    } else if let editor = model.editor {
      EditorView(model: editor)
    }
  }

  private var emptyState: some View {
    VStack(spacing: 12) {
      Text(model.emptyStateTitle).font(.system(size: 20, weight: .semibold))
        .foregroundStyle(Color(white: 0.85))
      Text(model.emptyStateSubtitle).foregroundStyle(Color(white: 0.5))
      Button(model.importButtonLabel) { model.importButtonTapped() }
        .padding(.top, 8)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  private var progress: some View {
    VStack(spacing: 14) {
      if model.isProgressDeterminate {
        ProgressView(value: model.determinateValue)
          .progressViewStyle(.linear)
          .frame(maxWidth: 320)
      } else {
        ProgressView()
      }
      Text(model.progressHeadline).foregroundStyle(Color(white: 0.7))
      Text(model.progressNote)
        .font(.caption)
        .multilineTextAlignment(.center)
        .foregroundStyle(Color(white: 0.5))
        .frame(maxWidth: 320)
      if let eta = model.etaMessage {
        Text(eta).font(.caption).foregroundStyle(Color(white: 0.5))
      }
      if model.showsCancel {
        Button(model.cancelButtonLabel) { model.cancelTranscriptionTapped() }
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  private var failure: some View {
    VStack(spacing: 14) {
      Text(model.errorMessage ?? "")
        .foregroundStyle(Color(red: 0.89, green: 0.58, blue: 0.58))
        .multilineTextAlignment(.center)
        .textSelection(.enabled)  // errors are copyable (select + Cmd-C)
        .padding(.horizontal, 24)
      Button(model.retryButtonLabel) { Task { await model.retryTapped() } }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }
}
