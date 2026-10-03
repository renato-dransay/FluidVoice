//
//  AISettingsView+ProviderManagement.swift
//  fluid
//
//  The AI Providers rows and the Manage sheet: Connection, Models and Used for.
//

import SwiftUI

extension AIEnhancementSettingsView {
    // MARK: - Rows

    func providerRow(_ provider: AIEnhancementSettingsViewModel.ProviderItemData) -> some View {
        let capabilities = AIProviderCatalog.capabilities(for: provider.id)
        let isBusy = self.viewModel.isFetchingModels || self.viewModel.isTestingConnection
        return HStack(spacing: self.theme.metrics.spacing.md) {
            self.providerLogoView(for: ProviderItem(id: provider.id, name: provider.name, isBuiltIn: provider.isBuiltIn))
                .frame(width: 30, height: 30)
            VStack(alignment: .leading, spacing: 4) {
                Text(provider.name).font(self.theme.typography.bodySmallStrong)
                HStack(spacing: 6) {
                    ForEach(ProviderCapability.ordered(capabilities), id: \.self) { capability in
                        self.providerTag(capability.title, color: self.theme.palette.secondaryText)
                    }
                    if self.viewModel.hasSeparateSpeechKey(provider.id) {
                        self.providerTag("Two keys", color: .orange)
                            .help("Voice Engine uses a different key for this provider. Open Manage to use one key everywhere.")
                    }
                }
            }
            Spacer()
            ProviderStatusBadge(status: self.viewModel.providerStatus(for: provider.id))
            if capabilities.contains(.text) {
                ProviderDefaultButton(
                    isCurrent: DictationDefaultProvider.isDefaultTextProvider(provider.id, selectedProviderID: self.settings.selectedProviderID),
                    isEnabled: self.viewModel.canUseProviderWithoutVerification(provider.id) && !isBusy,
                    purpose: self.settings.usesCombinedCloudDictation ? .textActions : .dictation,
                    isVerified: self.viewModel.connectionStatus(for: provider.id) == .success
                ) {
                    Task { await self.viewModel.makeDefaultTextProvider(provider.id) }
                }
            }
            Button("Manage") { self.openProviderManager(provider.id, origin: nil) }
                .fluidGlassAction()
                .disabled(isBusy)
                .accessibilityIdentifier("ai-provider-manage-\(provider.id)")
        }
        .padding(self.theme.metrics.spacing.lg)
        .background(self.theme.palette.cardBackground, in: RoundedRectangle(cornerRadius: self.theme.metrics.corners.lg, style: .continuous))
        .accessibilityIdentifier("ai-provider-row-\(provider.id)")
    }

    private func providerTag(_ title: String, color: Color) -> some View {
        Text(title)
            .font(self.theme.typography.caption)
            .foregroundStyle(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .overlay(Capsule().strokeBorder(color.opacity(0.4), lineWidth: 1))
    }

    // MARK: - Manage sheet

    /// Connection for every provider, Models for providers with Text, Used for for speech capabilities.
    @ViewBuilder
    func providerManagementContent(for providerID: String) -> some View {
        let capabilities = AIProviderCatalog.capabilities(for: providerID)
        self.providerConnectionGroup(for: providerID)
        if capabilities.contains(.text) {
            self.providerModelsGroup(for: providerID)
        }
        if capabilities.contains(.cloudTranscription) || capabilities.contains(.liveTranscription) {
            self.providerUsedForGroup(for: providerID, capabilities: capabilities)
        }
    }

    private func providerConnectionGroup(for providerID: String) -> some View {
        let isSpeechOnly = self.viewModel.isSpeechOnlyProvider(providerID)
        let isCustom = !isSpeechOnly && !ModelRepository.shared.isBuiltIn(providerID)
        let name = self.viewModel.providerName(for: providerID)
        let errorMessage = isSpeechOnly ? "" : self.viewModel.connectionErrorMessage(for: providerID)
        return FluidManagementGroup(title: "Connection") {
            if isCustom {
                self.managementField("Name") {
                    TextField("Custom Provider", text: Binding(
                        get: { self.viewModel.savedProviders.first(where: { $0.id == providerID })?.name ?? "" },
                        set: { self.viewModel.updateCustomProviderName($0, for: providerID) }
                    ))
                }
                self.managementField("Server URL") {
                    TextField("https://api.yourprovider.com/v1", text: Binding(
                        get: { self.viewModel.savedProviders.first(where: { $0.id == providerID })?.baseURL ?? self.viewModel.openAIBaseURL },
                        set: { self.viewModel.updateCustomProviderBaseURL($0, for: providerID) }
                    ))
                    .font(.fluidSystem(size: 13, design: .monospaced))
                }
            }
            if self.viewModel.hasSeparateSpeechKey(providerID) {
                self.twoKeysNotice(for: providerID, name: name)
            }
            RecordingStateReader { removalBlocker in
                ProviderAPIKeyField(
                    text: self.apiKeyBinding(for: providerID),
                    hasSavedKey: self.viewModel.hasStoredAPIKey(for: providerID),
                    isOptional: !AIProviderCatalog.requiresAPIKey(providerID),
                    link: AIProviderCatalog.keyLink(for: providerID),
                    removeKey: { self.requestProviderRemoval(providerID, removesProvider: false) },
                    isRemovalDisabled: removalBlocker != nil,
                    removalHelp: removalBlocker ?? "",
                    onFocus: { self.viewModel.ensureKeychainAccessForAPIKeyEdit() }
                )
            }
            HStack(spacing: 12) {
                self.verifyButton(for: providerID)
                ProviderStatusBadge(status: self.viewModel.providerStatus(for: providerID))
                Spacer()
            }
            if !errorMessage.isEmpty, self.viewModel.connectionStatus(for: providerID) == .failed {
                ProviderActionResultLabel(result: .failure(errorMessage))
            }
            if let result = self.managedProviderResult {
                ProviderActionResultLabel(result: result)
            }
            if !isSpeechOnly, !isCustom {
                self.advancedServerURL(for: providerID)
            }
            RecordingStateReader { removalBlocker in
                Button(role: .destructive) {
                    self.requestProviderRemoval(providerID, removesProvider: true)
                } label: {
                    Label("Remove provider", systemImage: "trash").font(self.theme.typography.bodyStrong)
                }
                .fluidGlassAction()
                .foregroundStyle(.red)
                .tint(.red)
                .disabled(removalBlocker != nil)
                .help(removalBlocker ?? "")
                .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
    }

    private func apiKeyBinding(for providerID: String) -> Binding<String> {
        if self.viewModel.isSpeechOnlyProvider(providerID) {
            return self.$speechKeyDraft
        }
        // Edits stay a draft until Done, Verify or a model refresh saves them; emptying removes nothing.
        return Binding(
            get: { self.viewModel.providerAPIKey(for: providerID) },
            set: { self.viewModel.updateProviderAPIKey($0, for: providerID) }
        )
    }

    @ViewBuilder
    private func verifyButton(for providerID: String) -> some View {
        if self.viewModel.isSpeechOnlyProvider(providerID) {
            let isVerifying = self.viewModel.speechCheckStates[providerID] == .verifying
            let hasKey = self.viewModel.hasStoredAPIKey(for: providerID)
                || !self.speechKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            Button("Verify", systemImage: "checkmark.shield") {
                Task { await self.verifySpeechProvider(providerID) }
            }
            .fluidGlassAction(prominent: true)
            .disabled(!hasKey || isVerifying)
            .help("Send a small request to check this key.")
        } else {
            let models = self.viewModel.availableModelsByProvider[self.viewModel.providerKey(for: providerID)] ?? []
            let hasModel = !self.viewModel.selectedModel(for: providerID).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            let canVerify = !models.isEmpty && hasModel && self.canReachTextProvider(providerID)
            Button("Verify", systemImage: "checkmark.shield") {
                Task { await self.viewModel.testAPIConnection() }
            }
            .fluidGlassAction(prominent: true)
            .disabled(!canVerify || self.viewModel.isTestingConnection)
            .help(canVerify
                ? "Send a small request to check this key and model."
                : (models.isEmpty ? "Refresh models to enable verification." : "Select a model to enable verification."))
        }
    }

    /// The server and key a model refresh or a check needs: a name for a custom provider, a server, and a
    /// key unless the server is local.
    private func canReachTextProvider(_ providerID: String) -> Bool {
        let baseURL = self.viewModel.openAIBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let isCustom = !ModelRepository.shared.isBuiltIn(providerID)
        let hasName = !isCustom
            || !(self.viewModel.savedProviders.first { $0.id == providerID }?.name ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let hasAPIKey = !self.viewModel.providerAPIKey(for: providerID).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return hasName && !baseURL.isEmpty && (self.viewModel.isLocalEndpoint(baseURL) || hasAPIKey)
    }

    private func verifySpeechProvider(_ providerID: String) async {
        // A typed key is saved before the check, as text providers' keys are.
        if !self.speechKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let saved = self.viewModel.saveSpeechProviderKey(self.speechKeyDraft, for: providerID)
            guard case .success = saved else {
                self.managedProviderResult = saved
                return
            }
            self.speechKeyDraft = ""
        }
        let result = await self.viewModel.verifySpeechProvider(providerID)
        // The sheet may have closed, or moved to another provider, while the check ran.
        guard self.managedExternalProviderID == providerID else { return }
        self.managedProviderResult = result
    }

    private func twoKeysNotice(for providerID: String, name: String) -> some View {
        // Without a key saved or typed here, "Use this key everywhere" would delete the only key.
        let hasKeyHere = self.viewModel.settings.hasProviderTextKey(providerID)
            || (!self.viewModel.isSpeechOnlyProvider(providerID)
                && !self.viewModel.providerAPIKey(for: providerID).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        return VStack(alignment: .leading, spacing: 10) {
            Label("Voice Engine uses a different \(name) key from the one saved here.", systemImage: "key")
                .font(self.theme.typography.bodySmall)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                if hasKeyHere {
                    self.useThisKeyEverywhereButton(for: providerID)
                }
                Button("Use the Voice Engine key everywhere") {
                    self.managedProviderResult = self.viewModel.useSpeechKeyEverywhere(for: providerID)
                }
                .fluidGlassAction()
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 10))
        .accessibilityIdentifier("ai-provider-two-keys")
    }

    private func useThisKeyEverywhereButton(for providerID: String) -> some View {
        Button("Use this key everywhere") {
            // An edited key is saved first; saving a new key already ends the second key.
            guard self.viewModel.isSpeechOnlyProvider(providerID)
                || self.viewModel.saveManagedProviderAPIKeyIfNeeded(providerID) else { return }
            self.managedProviderResult = self.viewModel.hasSeparateSpeechKey(providerID)
                ? self.viewModel.useTextKeyEverywhere(for: providerID)
                : .success("Voice Engine now uses the key saved here.")
        }
        .fluidGlassAction()
    }

    /// The legacy layout let a built-in provider's server be edited; it applies to this sheet's checks.
    private func advancedServerURL(for providerID: String) -> some View {
        DisclosureGroup("Advanced") {
            VStack(alignment: .leading, spacing: 8) {
                Text("Server URL").font(self.theme.typography.bodyStrong)
                HStack(spacing: 8) {
                    TextField(ModelRepository.shared.defaultBaseURL(for: providerID), text: self.$serverURLDraft)
                        .textFieldStyle(.roundedBorder)
                        .font(.fluidSystem(size: 13, design: .monospaced))
                        .accessibilityLabel("Server URL")
                    Button("Apply") {
                        self.viewModel.editProviderName = self.viewModel.providerName(for: providerID)
                        self.viewModel.editProviderBaseURL = self.serverURLDraft
                        self.viewModel.saveEditedProvider()
                        self.serverURLDraft = self.viewModel.openAIBaseURL
                    }
                    .fluidGlassAction()
                    .disabled(
                        self.serverURLDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            || self.serverURLDraft.trimmingCharacters(in: .whitespacesAndNewlines) == self.viewModel.openAIBaseURL
                    )
                }
                Text("Verify and Refresh models use this server while this sheet is open. Dictation, Command Mode and Edit use the provider's standard server.")
                    .font(self.theme.typography.caption)
                    .foregroundStyle(self.theme.palette.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.top, 8)
        }
    }

    private func providerModelsGroup(for providerID: String) -> some View {
        let models = self.viewModel.availableModelsByProvider[self.viewModel.providerKey(for: providerID)] ?? []
        let isRefreshing = self.viewModel.isFetchingModels && self.viewModel.selectedProviderID == providerID
        let canFetchModels = self.canReachTextProvider(providerID)
        return FluidManagementGroup(title: "Models") {
            HStack(spacing: 8) {
                SearchableModelPicker(
                    models: models,
                    selectedModel: self.modelBinding(for: providerID),
                    selectionEnabled: !models.isEmpty,
                    controlWidth: 720 - 56 - 40 - 2 * AISettingsLayout.providerRowControlHeight - 32,
                    controlHeight: AISettingsLayout.providerRowControlHeight
                )
                self.companionIconButton(
                    isRefreshing: isRefreshing,
                    disabled: isRefreshing || !canFetchModels,
                    opacity: canFetchModels ? 1 : 0.45,
                    help: "Refresh model list"
                ) {
                    Task { await self.viewModel.fetchModelsForCurrentProvider() }
                }
                self.companionIconButton(systemName: "plus", help: "Add model") {
                    self.viewModel.newModelName = ""
                    self.viewModel.showingAddModel.toggle()
                }
                .accessibilityLabel("Add model")
            }
            if self.viewModel.showingAddModel {
                self.addModelSection
            }
            if self.viewModel.isModelVerified(for: providerID) {
                Label("Model verified", systemImage: "checkmark.circle.fill")
                    .font(self.theme.typography.caption)
                    .foregroundStyle(Color.fluidGreen)
                    .help("Successfully checked \(ModelDisplayName.forID(self.viewModel.selectedModel(for: providerID))) with this server and API key.")
            }
            if let error = self.viewModel.fetchModelsError, !error.isEmpty {
                ProviderActionResultLabel(result: .failure(error))
            }
            let reasoning = self.viewModel.reasoningStateSummary(for: providerID)
            FluidManagementRow(title: "Reasoning", detail: reasoning.detail) {
                Button("Configure…", systemImage: "gearshape") { self.viewModel.openReasoningConfig() }
                    .fluidButton(.compact, size: .small)
                    .disabled(reasoning.detail.isEmpty)
                    .help(reasoning.detail.isEmpty ? "Choose a model first." : "")
            }
            if let note = reasoning.note {
                Text(note)
                    .font(self.theme.typography.caption)
                    .foregroundStyle(self.theme.palette.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if self.viewModel.showingReasoningConfig, self.viewModel.selectedProviderID == providerID {
                self.reasoningConfigSection
            }
        }
    }

    private func providerUsedForGroup(for providerID: String, capabilities: Set<ProviderCapability>) -> some View {
        FluidManagementGroup(title: "Used for") {
            if capabilities.contains(.cloudTranscription),
               let destination = AppNavigationDestination.usedFor(.cloudTranscription, providerID: providerID)
            {
                FluidManagementRow(title: "Cloud transcription", detail: "Choose its model in Voice Engine.") {
                    Button("Open Voice Engine") { self.leaveProviderManager(for: destination) }
                        .fluidGlassAction()
                }
            }
            if capabilities.contains(.liveTranscription),
               let destination = AppNavigationDestination.usedFor(.liveTranscription, providerID: providerID)
            {
                FluidManagementRow(title: "Live", detail: "Choose its model and test it in Voice Engine.") {
                    Button("Open Voice Engine") { self.leaveProviderManager(for: destination) }
                        .fluidGlassAction()
                }
            }
        }
    }

    private func leaveProviderManager(for destination: AppNavigationDestination) {
        guard self.closeExternalProviderManager() else { return }
        self.navigate(to: destination)
    }

    private func managementField<Control: View>(_ title: String, @ViewBuilder control: () -> Control) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(self.theme.typography.bodyStrong)
            control().textFieldStyle(.roundedBorder).controlSize(.large).accessibilityLabel(title)
        }
    }

    // MARK: - Removal (KEY-6)

    /// `Remove key` with nothing depending on the provider acts at once; everything else asks first.
    func requestProviderRemoval(_ providerID: String, removesProvider: Bool) {
        let removal = PendingProviderRemoval(
            providerID: providerID,
            removesProvider: removesProvider,
            impact: self.viewModel.removalImpact(for: providerID)
        )
        if !removesProvider, !removal.impact.needsConfirmation {
            self.performProviderRemoval(removal)
        } else {
            self.pendingProviderRemoval = removal
        }
    }

    func performProviderRemoval(_ removal: PendingProviderRemoval) {
        self.pendingProviderRemoval = nil
        let asr = AppServices.shared.asr
        guard !asr.blocksSpeechEngineChanges else {
            self.managedProviderResult = .failure(asr.speechEngineChangeBlockerMessage ?? "Finish the current recording first.")
            return
        }
        let providerID = removal.providerID
        self.speechKeyDraft = ""
        if !removal.removesProvider {
            self.managedProviderResult = self.viewModel.removeProviderAPIKey(for: providerID)
                ? .success("API key removed.")
                : .failure("Couldn't remove the key. Check Keychain access and try again.")
            return
        }
        if self.viewModel.isSpeechOnlyProvider(providerID) {
            guard self.viewModel.removeProviderAPIKey(for: providerID) else {
                self.managedProviderResult = .failure("Couldn't remove the provider. Check Keychain access and try again.")
                return
            }
        } else {
            guard self.viewModel.selectedProviderID == providerID, self.viewModel.deleteCurrentProvider() else {
                self.managedProviderResult = .failure("Couldn't remove the provider. Check Keychain access and try again.")
                return
            }
            self.expandedProviderID = nil
        }
        self.closeExternalProviderManager()
    }
}
