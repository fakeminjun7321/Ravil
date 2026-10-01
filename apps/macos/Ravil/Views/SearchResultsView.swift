import SwiftUI

struct SearchResultsView: View {
    let model: AppModel

    var body: some View {
        List(model.searchHits) { hit in
            Button { model.open(hit) } label: {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: symbol(for: hit.kind))
                        .foregroundStyle(.secondary)
                        .frame(width: 22)
                    VStack(alignment: .leading, spacing: 5) {
                        Text(hit.title).fontWeight(.medium)
                        Text(hit.excerpt).font(.subheadline).foregroundStyle(.secondary).lineLimit(3)
                    }
                    Spacer()
                }
                .padding(.vertical, 7)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .overlay {
            if model.searchHits.isEmpty {
                ContentUnavailableView.search(text: model.searchQuery)
            }
        }
    }

    private func symbol(for kind: SearchHit.Kind) -> String {
        switch kind {
        case .lecture: return "waveform"
        case .transcript: return "text.quote"
        case .material: return "doc.text"
        case .note: return "book.closed"
        }
    }
}
