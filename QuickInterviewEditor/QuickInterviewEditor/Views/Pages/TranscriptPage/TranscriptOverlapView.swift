import SwiftUI

struct TranscriptOverlapView: View {
  @Bindable var model: TranscriptOverlapModel
  @FocusState private var focusedID: TranscriptObjectID?

  var body: some View {
    ScrollViewReader { proxy in
      ScrollView {
        VStack(alignment: .leading, spacing: 4) {
          ForEach(model.candidates) { object in
            Button {
              model.choose(object.id)
            } label: {
              HStack {
                VStack(alignment: .leading) {
                  Text(object.name).lineLimit(2)
                  Text(model.detail(object)).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if model.selectedID == object.id { Image(systemName: "checkmark") }
              }
              .padding(8)
              .frame(maxWidth: .infinity, alignment: .leading)
              .background(model.focusedID == object.id ? Color.accentColor.opacity(0.2) : .clear)
              .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .focused($focusedID, equals: object.id)
            .accessibilityLabel("\(object.name), \(model.detail(object))")
            .accessibilityAddTraits(model.selectedID == object.id ? .isSelected : [])
            .onHover { model.preview($0 ? object.id : nil) }
            .id(object.id)
          }
        }.padding(8)
      }
      .onAppear { focusedID = model.focusedID }
      .onChange(of: focusedID) { _, id in
        if let id {
          model.focusedID = id
          model.preview(id)
        }
      }
      .onChange(of: model.focusedID) { _, id in
        focusedID = id
        if let id { proxy.scrollTo(id) }
      }
    }
    .frame(width: 280, height: min(320, CGFloat(model.candidates.count) * 64 + 16))
  }
}
