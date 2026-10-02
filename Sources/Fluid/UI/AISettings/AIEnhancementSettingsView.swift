import SwiftUI

enum AIEnhancementConfigurationSection: String {
    case providers
    case advancedPrompts

    var sidebarItem: SidebarItem {
        switch self {
        case .providers:
            return .aiEnhancements
        case .advancedPrompts:
            return .cleanupStyles
        }
    }
}

extension SidebarItem {
    var aiEnhancementConfigurationSection: AIEnhancementConfigurationSection? {
        switch self {
        case .aiEnhancements:
            return .providers
        case .cleanupStyles:
            return .advancedPrompts
        default:
            return nil
        }
    }
}

struct AIEnhancementSettingsView: View {
    @ObservedObject var viewModel: AIEnhancementSettingsViewModel
    @ObservedObject var privateAIController: PrivateAISettingsController
    @ObservedObject var settings: SettingsStore
    @ObservedObject var promptTest: DictationPromptTestCoordinator
    let theme: AppTheme
    @Binding var selectedConfigurationSection: AIEnhancementConfigurationSection
    @Binding var activeShortcutRecordingTarget: ShortcutRecordingTarget?
    @Binding var shortcutRecordingMessage: String?
    @State var expandedProviderID: String? = nil
    @State var managedExternalProviderID: String?
    @State var showingRemoveProviderConfirmation = false
    @State var providerListFilter: AIProviderListFilter = .all
    @State var addProviderRequest: AddProviderRequest?
    /// Where the open Manage sheet was requested from, for its `Back to …` button.
    @State var managedProviderOrigin: ProviderSetupOrigin?
    @State var pendingProviderRemoval: PendingProviderRemoval?
    @State var managedProviderResult: ProviderActionResult?
    @State var speechKeyDraft = ""
    @State var serverURLDraft = ""
    @State var providerSearchText: String = ""
    @State var hoveredPromptCardKey: String? = nil
    @State var selectedPromptMode: SettingsStore.PromptMode = .dictate
    @State var hoveredPromptModeKey: String? = nil
    @State var hoveredPromptScopeKey: String? = nil
    @State var isPromptProfilesHelpPresented: Bool = false
    @State var showsAppSpecificStyles = false
    @State var promptEditorPrimarySelectionDraft: SettingsStore.DictationPromptSelection? = nil
    @State var promptEditorShortcutDraft: HotkeyShortcut? = nil
    @State var promptEditorOriginalConfiguration: SettingsStore.DictationPromptConfiguration? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if self.selectedConfigurationSection == .providers, self.settings.usesCombinedCloudDictation {
                VStack(alignment: .leading, spacing: 6) {
                    Label("OpenRouter handles dictation", systemImage: "waveform")
                        .font(.fluidSystem(size: 14, weight: .semibold))
                        .foregroundStyle(self.theme.palette.primaryText)
                    Text(
                        "OpenRouter dictation sends the audio and the selected Cleanup Style in one request, so the per-style AI provider is not used for dictation. "
                            + "The providers below are for Edit, Write, and other text AI actions while this mode is on."
                    )
                        .font(self.theme.typography.bodySmall)
                        .foregroundStyle(self.theme.palette.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(self.theme.palette.accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(self.theme.palette.accent.opacity(0.25), lineWidth: 1))
            }
            self.aiConfigurationCard
        }
            .onAppear {
                self.viewModel.onAppear()
                self.privateAIController.synchronizeSelection()
                self.privateAIController.refreshPrivateAILoadState()
                self.privateAIController.refreshPrivateAIModelUpdateStatus(self.privateAIController.selectedPrivateAIModel)
                self.openRequestedProviderSheet()
            }
            // Already on AI Providers: a provider request opens its sheet here.
            .onReceive(NotificationCenter.default.publisher(for: .appNavigationRequested)) { _ in
                self.openRequestedProviderSheet()
            }
            // Arriving from Cleanup Styles, whose editor sheet is still closing: macOS drops a sheet
            // presented while another dismisses, so the provider sheet opens a moment later.
            .onChange(of: self.selectedConfigurationSection) { _, section in
                guard section == .providers else { return }
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(400))
                    self.openRequestedProviderSheet()
                }
            }
            .onChange(of: self.viewModel.connectionStatus) { oldValue, newValue in
                if oldValue == .success && newValue != .success {
                    self.expandedProviderID = self.viewModel.selectedProviderID
                }
            }
            .onChange(of: self.viewModel.showKeychainPermissionAlert) { _, isPresented in
                guard isPresented else { return }
                self.viewModel.presentKeychainAccessAlert(message: self.viewModel.keychainPermissionMessage)
                self.viewModel.showKeychainPermissionAlert = false
            }
            .alert("Delete Prompt?", isPresented: self.$viewModel.showingDeletePromptConfirm) {
                Button("Delete", role: .destructive) {
                    self.viewModel.deletePendingPrompt()
                }
                Button("Cancel", role: .cancel) {
                    self.viewModel.clearPendingDeletePrompt()
                }
            } message: {
                if self.viewModel.pendingDeletePromptName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text("This cannot be undone.")
                } else {
                    Text("Delete “\(self.viewModel.pendingDeletePromptName)”? This cannot be undone.")
                }
            }
            .alert(
                "Couldn't Add App Override",
                isPresented: Binding(
                    get: { !self.viewModel.appPromptBindingErrorMessage.isEmpty },
                    set: { isPresented in
                        if !isPresented {
                            self.viewModel.appPromptBindingErrorMessage = ""
                        }
                    }
                )
            ) {
                Button("OK", role: .cancel) {
                    self.viewModel.appPromptBindingErrorMessage = ""
                }
            } message: {
                Text(self.viewModel.appPromptBindingErrorMessage)
            }
    }
}

/// A request to open the Add sheet: on the grid (optionally one capability) or on one provider's form.
struct AddProviderRequest: Identifiable, Equatable {
    let id = UUID()
    var capability: ProviderCapability?
    var providerID: String?
    var origin: ProviderSetupOrigin?
}

/// A `Remove key` or `Remove provider` waiting for its confirmation.
struct PendingProviderRemoval: Equatable {
    let providerID: String
    let removesProvider: Bool
    let impact: ProviderRemovalImpact
}

extension AIEnhancementSettingsView {
    /// Opens the sheet a navigation request asked for, once (NAV-2, NAV-3). Waits while another page
    /// of this view is shown; the section change brings it back here.
    func openRequestedProviderSheet() {
        guard self.selectedConfigurationSection == .providers,
              self.addProviderRequest == nil, self.managedExternalProviderID == nil,
              let destination = AppNavigationRouter.shared.consumeRequestedProviderSetup(),
              let route = ProviderSheetRoute.route(
                  for: destination,
                  connectedProviderIDs: Set(self.viewModel.cachedAddedProviderItems.map(\.id))
              )
        else { return }
        switch route {
        case let .manage(providerID, origin):
            self.openProviderManager(providerID, origin: origin)
        case let .add(capability, providerID, origin):
            self.addProviderRequest = AddProviderRequest(capability: capability, providerID: providerID, origin: origin)
        }
    }

    func openProviderManager(_ providerID: String, origin: ProviderSetupOrigin?) {
        // A provider without Text is never configured as the text provider.
        if !self.viewModel.isSpeechOnlyProvider(providerID) {
            self.viewModel.configureProvider(providerID)
            self.serverURLDraft = self.viewModel.openAIBaseURL
        }
        self.managedProviderOrigin = origin
        self.managedProviderResult = nil
        self.speechKeyDraft = ""
        self.managedExternalProviderID = providerID
    }

    /// `Back to …` and the `Used for` buttons: the sheet is closed by the caller first.
    func navigate(to destination: AppNavigationDestination) {
        AppNavigationRouter.shared.request(destination)
    }
}
