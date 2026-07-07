import SwiftUI

struct SlicesPanelView: View {
  @Bindable var model: EditorModel

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack {
        Text("SLICES").font(.system(size: 11, weight: .semibold))
          .kerning(1).foregroundStyle(Color(white: 0.44))
        Text(model.sliceCountLabel).font(.system(size: 11))
          .foregroundStyle(Color(white: 0.34))
        Spacer()
        Button(model.addSliceLabel) { model.addSliceTapped() }
          .disabled(!model.canAddSlice)
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
            Task { for id in ids { await model.deleteSlice(id) } }
          }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .animation(.default, value: model.sliceRows.map(\.id))
      }
    }
    .padding(12)
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
        Spacer()
        Text(row.durationLabel).font(.system(size: 11))
          .foregroundStyle(Color(white: 0.54))
      }
      Text(row.rangeLabel).font(.system(size: 11).monospacedDigit())
        .foregroundStyle(Color(white: 0.44))
      Text(row.snippet).font(.system(size: 12.5))
        .foregroundStyle(Color(white: 0.6)).lineLimit(2)
      if row.isTight {
        Text(row.warningLabel).font(.system(size: 11))
          .foregroundStyle(Color(red: 0.89, green: 0.58, blue: 0.58))
      }
      HStack(spacing: 8) {
        Button(row.playButtonLabel) {
          Task { await model.playStopTapped(row.id) }
        }
        Button {
          Task { await model.deleteSlice(row.id) }
        } label: {
          Image(systemName: "xmark")
        }
        .buttonStyle(.plain).accessibilityLabel(model.deleteLabel)
      }
    }
    .padding(12)
    .background(Color(white: 0.08))
    .clipShape(RoundedRectangle(cornerRadius: 11))
  }
}
