import SwiftUI

struct SlicesPanelView: View {
  @Bindable var model: EditorModel

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack(spacing: 8) {
        Text("SLICES").font(.system(size: 11, weight: .semibold))
          .kerning(1).foregroundStyle(Color(white: 0.44))
        Text(model.sliceCountLabel).font(.system(size: 11))
          .foregroundStyle(Color(white: 0.34))
        Spacer()
        Button {
          Task { await model.undoTapped() }
        } label: {
          Image(systemName: "arrow.uturn.backward")
        }
        .disabled(!model.canUndo)
        .help(model.undoLabel).accessibilityLabel(model.undoLabel)
        Button {
          Task { await model.redoTapped() }
        } label: {
          Image(systemName: "arrow.uturn.forward")
        }
        .disabled(!model.canRedo)
        .help(model.redoLabel).accessibilityLabel(model.redoLabel)
      }
      HStack(spacing: 8) {
        Spacer()
        Button(model.exportAllLabel) { model.exportAllTapped() }
          .disabled(!model.canExportAll)
      }
      if model.showsExportStatus {
        ExportStatus(model: model)
      }
      if model.sliceRows.isEmpty {
        Text(model.emptyStateMessage)
          .font(.system(size: 12)).foregroundStyle(Color(white: 0.5))
          .frame(maxWidth: .infinity, alignment: .leading)
      } else {
        List {
          ForEach(model.sliceRows) { row in
            SliceCard(model: model, row: row)
              .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
              .listRowSeparator(.hidden)
              .listRowBackground(Color.clear)
          }
          .onMove { model.moveSlices(fromOffsets: $0, toOffset: $1) }
          .onDelete { indexSet in
            let ids = indexSet.map { model.sliceRows[$0].id }
            Task { await model.deleteSlices(ids) }
          }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .animation(.default, value: model.sliceRows.map(\.id))
      }
    }
    .padding(12)
    .frame(maxHeight: .infinity, alignment: .top)
  }
}

private struct SliceCard: View {
  @Bindable var model: EditorModel
  let row: SliceRowState
  @FocusState private var nameFocused: Bool
  @State private var nameHovering = false

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack {
        TextField(
          "",
          text: Binding(
            get: { model.slices[id: row.id]?.name ?? row.name },
            set: { model.renameSlice(row.id, to: $0) })
        )
        .textFieldStyle(.plain).font(.system(size: 14, weight: .semibold))
        .focused($nameFocused)
        .padding(.horizontal, 6).padding(.vertical, 3)
        .background(
          RoundedRectangle(cornerRadius: 5)
            .fill(Color.white.opacity(nameFocused ? 0.14 : (nameHovering ? 0.07 : 0)))
        )
        .onHover { nameHovering = $0 }
        .help("Click to rename")
        .accessibilityLabel("Slice name")
        Spacer()
        Text(row.durationLabel).font(.system(size: 11))
          .foregroundStyle(Color(white: 0.54))
      }
      // The range + snippet block is a plain-style button — activating it jumps the transcript
      // and waveform to the clip and is keyboard/VoiceOver-accessible. Kept off the rename field
      // and the action buttons so it never steals their taps.
      Button {
        model.sliceRevealTapped(row.id)
      } label: {
        VStack(alignment: .leading, spacing: 6) {
          Text(row.rangeLabel).font(.system(size: 11).monospacedDigit())
            .foregroundStyle(Color(white: 0.44))
          Text(row.snippet).font(.system(size: 12.5))
            .foregroundStyle(Color(white: 0.6)).lineLimit(2)
          if row.isTight {
            Text(row.warningLabel)
              .font(.system(size: 10, weight: .semibold)).tracking(0.3)
              .foregroundStyle(Color(red: 0.89, green: 0.58, blue: 0.58))
              .padding(.horizontal, 7).padding(.vertical, 2)
              .background(
                Capsule().fill(Color(red: 0.89, green: 0.58, blue: 0.58).opacity(0.16))
              )
              .help(row.warningHelp).accessibilityLabel(row.warningHelp)
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .accessibilityLabel(model.revealClipLabel)
      HStack(spacing: 8) {
        // A pure Play shortcut into the global transport (ruling F: no per-slice Stop — the
        // transport panel owns Pause/Stop). The row highlights below while this slice plays.
        Button(row.playButtonLabel) {
          Task { await model.playSliceTapped(row.id) }
        }
        // "Edit cuts" (fine-tune) is deferred with the rest of the boundary-editing UI, so it's
        // not offered on a clip in this flow. `sliceSelected` / the fine-tune model stay for
        // when it returns.
        Button(model.exportLabel) {
          model.exportSliceTapped(row.id)
        }
        .disabled(!model.canExportSlice)
        Spacer()
        Button {
          Task { await model.deleteSlice(row.id) }
        } label: {
          Image(systemName: "xmark")
        }
        .buttonStyle(.plain).accessibilityLabel(model.deleteLabel)
      }
    }
    .padding(12)
    // A subtle transport-accent tint marks the slice the one playhead is currently playing (the
    // per-slice Stop is gone; this is the row's "playing" indicator).
    .background(
      row.isPlaying ? Color(red: 0.96, green: 0.86, blue: 0.4).opacity(0.12) : Color(white: 0.08)
    )
    .clipShape(RoundedRectangle(cornerRadius: 11))
    .overlay(
      RoundedRectangle(cornerRadius: 11)
        .stroke(Color(red: 0.8, green: 0.4, blue: 0.4), lineWidth: row.isActive ? 1.5 : 0)
    )
  }
}

private struct ExportStatus: View {
  let model: EditorModel

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      HStack(spacing: 8) {
        Text(model.exportStatusMessage)
          .font(.system(size: 11.5)).foregroundStyle(Color(white: 0.6))
          .frame(maxWidth: .infinity, alignment: .leading)
        if model.showsCancelExport {
          Button(model.cancelExportLabel) { model.cancelExportTapped() }
            .font(.system(size: 11))
        }
      }
      if !model.exportTightWarning.isEmpty {
        Text(model.exportTightWarning).font(.system(size: 11))
          .foregroundStyle(Color(red: 0.89, green: 0.58, blue: 0.58))
      }
    }
  }
}
