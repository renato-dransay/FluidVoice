import SwiftUI

/// The grid of live providers, laid out like AI Providers' Add a provider sheet.
struct AddLiveProviderSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme
    let added: Set<LiveTranscriptionProviderID>
    let onAdd: (LiveTranscriptionProviderID) -> Void
    @State private var selection: LiveTranscriptionProviderID?

    var body: some View {
        FluidManagementSheet(
            title: "Add a live provider",
            subtitle: "Words appear while you speak.",
            symbol: "waveform",
            // The default height fits four rows of tiles and the Add button without scrolling.
            close: { self.dismiss() }
        ) {
            Text("Choose a provider").font(self.theme.typography.bodyStrong)
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                ForEach(LiveTranscriptionCatalog.all) { info in
                    self.tile(for: info)
                }
            }
            Label("Adding a provider won't change your current dictation setup.", systemImage: "info.circle")
                .font(self.theme.typography.caption).foregroundStyle(self.theme.palette.secondaryText)
            HStack {
                Spacer()
                Button("Add Provider") {
                    guard let selection = self.selection else { return }
                    self.onAdd(selection)
                }
                .keyboardShortcut(.defaultAction)
                .fluidGlassAction(prominent: true)
                .disabled(self.selection == nil)
                .accessibilityIdentifier("live-cloud-add-provider-confirm")
            }
        }
    }

    private func tile(for info: LiveTranscriptionProviderInfo) -> some View {
        let isAdded = self.added.contains(info.id)
        let isSelected = self.selection == info.id
        return Button {
            self.selection = info.id
        } label: {
            HStack(spacing: 14) {
                LiveProviderBadge(name: info.name)
                VStack(alignment: .leading, spacing: 5) {
                    Text(info.name).font(self.theme.typography.bodyStrong)
                    Text(isAdded ? "Added" : "Connect with an API key")
                        .font(self.theme.typography.caption).foregroundStyle(self.theme.palette.secondaryText)
                }
                Spacer()
                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(FluidBrandColors.blue)
                        .accessibilityHidden(true)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, minHeight: 76, alignment: .leading)
            .foregroundStyle(self.theme.palette.primaryText)
            .background(self.theme.palette.cardBackground, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(isSelected ? FluidBrandColors.blue : .clear, lineWidth: 2)
            )
            .contentShape(RoundedRectangle(cornerRadius: 16))
        }
        .buttonStyle(.plain)
        .disabled(isAdded)
        .opacity(isAdded ? 0.55 : 1)
        .accessibilityIdentifier("live-cloud-add-\(info.id.rawValue)")
    }
}
