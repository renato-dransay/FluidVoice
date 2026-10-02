//
//  SearchableModelPicker.swift
//  Fluid
//
//  A searchable picker for selecting AI models.
//  Uses a popover with search field for better UX.
//

import SwiftUI

/// One row of `SearchableModelPicker`: the stored ID, the name shown, an optional second line such as
/// "Default" or "No word timings", and whether the row can be chosen.
struct SearchableModelPickerItem: Identifiable, Equatable {
    let id: String
    let name: String
    var detail: String?
    var isEnabled = true

    /// The rows for `items` plus, first, the current selection when no row offers it, so a stored model
    /// that a catalog no longer lists stays visible as the selection instead of disappearing.
    static func including(selection: String, in items: [SearchableModelPickerItem], unlistedDetail: String = "No longer listed") -> [SearchableModelPickerItem] {
        guard !selection.isEmpty, !items.contains(where: { $0.id == selection }) else { return items }
        return [SearchableModelPickerItem(id: selection, name: selection, detail: unlistedDetail)] + items
    }

    /// The rows whose ID, name or second line contains `query`; every row for an empty query.
    static func filtered(_ items: [SearchableModelPickerItem], query: String) -> [SearchableModelPickerItem] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return items }
        return items.filter {
            $0.id.localizedCaseInsensitiveContains(query)
                || $0.name.localizedCaseInsensitiveContains(query)
                || ($0.detail?.localizedCaseInsensitiveContains(query) ?? false)
        }
    }
}

/// The one model picker used for text models (AI Providers, Rewrite) and speech models (Voice Engine's
/// Cloud tab and Live cloud sheet): a button that opens a searchable list with a checkmark on the choice.
struct SearchableModelPicker: View {
    @Environment(\.theme) private var theme
    let items: [SearchableModelPickerItem]
    @Binding var selectedModel: String
    var onRefresh: (() async -> Void)?
    var isRefreshing: Bool = false
    var refreshEnabled: Bool = true
    var selectionEnabled: Bool = true
    let displayName: (String) -> String
    let controlWidth: CGFloat
    let controlHeight: CGFloat?
    let popoverWidth: CGFloat
    let accessibilityIdentifier: String?
    /// The label VoiceOver reads for the button, such as "Speech model", when the visible title sits beside it.
    let accessibilityTitle: String?

    init(
        models: [String],
        selectedModel: Binding<String>,
        onRefresh: (() async -> Void)? = nil,
        isRefreshing: Bool = false,
        refreshEnabled: Bool = true,
        selectionEnabled: Bool = true,
        displayName: @escaping (String) -> String = ModelDisplayName.forID,
        controlWidth: CGFloat = 180,
        controlHeight: CGFloat? = nil
    ) {
        self.init(
            items: models.map { SearchableModelPickerItem(id: $0, name: displayName($0)) },
            selectedModel: selectedModel,
            onRefresh: onRefresh,
            isRefreshing: isRefreshing,
            refreshEnabled: refreshEnabled,
            selectionEnabled: selectionEnabled,
            displayName: displayName,
            controlWidth: controlWidth,
            controlHeight: controlHeight
        )
    }

    init(
        items: [SearchableModelPickerItem],
        selectedModel: Binding<String>,
        onRefresh: (() async -> Void)? = nil,
        isRefreshing: Bool = false,
        refreshEnabled: Bool = true,
        selectionEnabled: Bool = true,
        displayName: @escaping (String) -> String = ModelDisplayName.forID,
        controlWidth: CGFloat = 180,
        controlHeight: CGFloat? = nil,
        popoverWidth: CGFloat = 280,
        accessibilityIdentifier: String? = nil,
        accessibilityTitle: String? = nil
    ) {
        self.items = items
        self._selectedModel = selectedModel
        self.onRefresh = onRefresh
        self.isRefreshing = isRefreshing
        self.refreshEnabled = refreshEnabled
        self.selectionEnabled = selectionEnabled
        self.displayName = displayName
        self.controlWidth = controlWidth
        self.controlHeight = controlHeight
        self.popoverWidth = popoverWidth
        self.accessibilityIdentifier = accessibilityIdentifier
        self.accessibilityTitle = accessibilityTitle
    }

    @State private var searchText = ""
    @State private var isShowingPopover = false

    private var refreshButtonSize: CGFloat {
        self.controlHeight ?? 24
    }

    private var pickerControlWidth: CGFloat? {
        guard self.onRefresh != nil, self.controlHeight != nil else {
            return self.controlWidth
        }
        return max(self.controlWidth - self.refreshButtonSize - 8, 80)
    }

    private var filteredModels: [SearchableModelPickerItem] {
        SearchableModelPickerItem.filtered(self.items, query: self.searchText)
    }

    /// The selected row's name, or the display name of an ID no row offers.
    private var selectedName: String {
        self.items.first { $0.id == self.selectedModel }?.name ?? self.displayName(self.selectedModel)
    }

    var body: some View {
        HStack(spacing: 8) {
            // Model button that opens popover
            Button(action: { self.isShowingPopover.toggle() }) {
                HStack(spacing: 6) {
                    Text(self.selectedModel.isEmpty ? "Select Model" : self.selectedName)
                        .font(.fluidSystem(size: 12, weight: .semibold))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .foregroundStyle(self.selectedModel.isEmpty ? .secondary : self.theme.palette.primaryText)
                    Spacer(minLength: 6)
                    FluidDropdownChevron()
                }
                .searchablePickerControlChrome(
                    width: self.pickerControlWidth,
                    height: self.controlHeight
                )
            }
            .buttonStyle(.plain)
            .disabled(!self.selectionEnabled)
            .opacity(self.selectionEnabled ? 1 : 0.55)
            .modifier(PickerAccessibility(
                identifier: self.accessibilityIdentifier,
                title: self.accessibilityTitle,
                value: self.selectedModel.isEmpty ? "Select Model" : self.selectedName
            ))
            .popover(isPresented: self.$isShowingPopover, arrowEdge: .bottom) {
                VStack(spacing: 0) {
                    // Search field
                    HStack {
                        Image(systemName: "magnifyingglass")
                            .foregroundStyle(.secondary)
                        TextField("Search models...", text: self.$searchText)
                            .textFieldStyle(.plain)
                    }
                    .searchablePickerSearchFieldChrome()

                    Divider()

                    VStack(spacing: 0) {
                        if self.items.isEmpty {
                            VStack(spacing: 8) {
                                Image(systemName: "tray")
                                    .font(.fluidSystem(.title2))
                                    .foregroundStyle(.secondary)
                                Text("No models")
                                    .font(.fluidSystem(.caption))
                                    .foregroundStyle(.secondary)
                                Text("Click refresh to fetch from API")
                                    .font(.fluidSystem(.caption2))
                                    .foregroundStyle(.tertiary)
                            }
                            .frame(height: 100)
                            .frame(maxWidth: .infinity)
                        } else {
                            ScrollView {
                                LazyVStack(alignment: .leading, spacing: 0) {
                                    if self.filteredModels.isEmpty {
                                        Text("No models match '\(self.searchText)'")
                                            .font(.fluidSystem(.caption))
                                            .foregroundStyle(.secondary)
                                            .padding()
                                            .frame(maxWidth: .infinity, alignment: .center)
                                    } else {
                                        ForEach(self.filteredModels.prefix(100)) { item in
                                            Button(action: {
                                                self.selectedModel = item.id
                                                self.searchText = ""
                                                self.isShowingPopover = false
                                            }) {
                                                HStack {
                                                    VStack(alignment: .leading, spacing: 1) {
                                                        Text(item.name)
                                                            .lineLimit(1)
                                                        if let detail = item.detail {
                                                            Text(detail)
                                                                .font(.fluidSystem(.caption2))
                                                                .foregroundStyle(.secondary)
                                                                .lineLimit(1)
                                                        }
                                                    }
                                                    Spacer()
                                                    if item.id == self.selectedModel {
                                                        Image(systemName: "checkmark")
                                                            .foregroundStyle(self.theme.palette.accent)
                                                    }
                                                }
                                                .padding(.horizontal, 10)
                                                .padding(.vertical, 6)
                                                .contentShape(Rectangle())
                                                .opacity(item.isEnabled ? 1 : 0.45)
                                            }
                                            .buttonStyle(.plain)
                                            .disabled(!item.isEnabled)
                                            .accessibilityLabel(item.detail.map { "\(item.name), \($0)" } ?? item.name)
                                            .searchablePickerSelectedRowBackground(isSelected: item.id == self.selectedModel)
                                        }
                                    }
                                }
                            }
                            .frame(maxHeight: 250)

                            if self.filteredModels.count > 100 {
                                Divider()
                                Text("\(self.filteredModels.count - 100) more (use search)")
                                    .font(.fluidSystem(.caption2))
                                    .foregroundStyle(.secondary)
                                    .padding(6)
                            }
                        }
                    }
                    .id(self.searchText.isEmpty)
                }
                .frame(width: self.popoverWidth)
            }

            // Refresh button
            if let onRefresh = onRefresh {
                if self.controlHeight == nil {
                    Button(action: {
                        Task { await onRefresh() }
                    }) {
                        if self.isRefreshing {
                            ProgressView()
                                .scaleEffect(0.6)
                                .frame(width: 16, height: 16)
                        } else {
                            Image(systemName: "arrow.clockwise")
                        }
                    }
                    .buttonStyle(.borderless)
                    .disabled(self.isRefreshing || !self.refreshEnabled)
                    .opacity(self.refreshEnabled ? 1 : 0.45)
                    .help("Refresh model list")
                } else {
                    Button(action: {
                        Task { await onRefresh() }
                    }) {
                        ZStack {
                            if self.isRefreshing {
                                ProgressView()
                                    .scaleEffect(0.6)
                                    .frame(width: 16, height: 16)
                            } else {
                                Image(systemName: "arrow.clockwise")
                                    .font(.fluidSystem(size: 12, weight: .semibold))
                            }
                        }
                        .frame(width: self.refreshButtonSize, height: self.refreshButtonSize)
                    }
                    .fluidCompactButton(isReady: false)
                    .disabled(self.isRefreshing || !self.refreshEnabled)
                    .opacity(self.refreshEnabled ? 1 : 0.45)
                    .help("Refresh model list")
                }
            }
        }
    }
}

/// Sets an accessibility identifier, and a label with the selection as its value, only when the caller
/// named them, so callers without them keep the button's own text.
private struct PickerAccessibility: ViewModifier {
    let identifier: String?
    let title: String?
    let value: String

    @ViewBuilder
    func body(content: Content) -> some View {
        if let identifier, let title {
            content.accessibilityIdentifier(identifier).accessibilityLabel(title).accessibilityValue(self.value)
        } else if let identifier {
            content.accessibilityIdentifier(identifier)
        } else if let title {
            content.accessibilityLabel(title).accessibilityValue(self.value)
        } else {
            content
        }
    }
}

#Preview {
    SearchableModelPicker(
        models: ["gpt-4.1", "gpt-4o", "gpt-3.5-turbo", "claude-3-opus", "claude-3-sonnet"],
        selectedModel: .constant("gpt-4.1"),
        onRefresh: { try? await Task.sleep(nanoseconds: 1_000_000_000) },
        isRefreshing: false
    )
    .padding()
}
