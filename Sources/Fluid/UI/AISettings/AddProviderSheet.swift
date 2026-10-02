import SwiftUI

/// The one Add a provider sheet, for text, cloud transcription and live providers.
struct AddProviderSheet<Logo: View>: View {
    private enum Step: Equatable {
        case grid
        case form
        /// After a successful Add opened from another screen: the way back.
        case connected(name: String, providerID: String)
    }

    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme
    @ObservedObject var viewModel: AIEnhancementSettingsViewModel
    let request: AddProviderRequest
    @ViewBuilder let logo: (String, String) -> Logo
    /// Leaves for the origin after the provider with this ID was connected.
    let goBack: (ProviderSetupOrigin, String) -> Void
    @State private var draft = ProviderSetupDraft()
    @State private var step: Step = .grid
    @State private var didOpenRequestedProvider = false
    @State private var saveResult: ProviderActionResult?
    @State private var modelFetchTask: Task<Void, Never>?
    @State private var modelFetchID: UUID?
    @State private var modelFetchError: String?
    @State private var showingManualModel = false

    private var providers: [ProviderDescriptor] {
        AIProviderCatalog.addableProviders(
            capability: self.request.capability,
            connectedProviderIDs: Set(self.viewModel.cachedAddedProviderItems.map(\.id))
        )
    }

    private var isSpeechOnlyDraft: Bool {
        AIProviderCatalog.isSpeechOnly(self.draft.providerID)
    }

    private var canAdd: Bool {
        if self.isSpeechOnlyDraft {
            return !self.draft.apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        return self.modelFetchID == nil && self.draft.isValid && !self.viewModel.isTestingConnection && !self.viewModel.isFetchingModels
    }

    var body: some View {
        FluidGlassControlGroup {
            VStack(alignment: .leading, spacing: self.theme.metrics.spacing.lg) {
                self.header
                Divider()
                switch self.step {
                case .grid:
                    self.grid
                    self.reassurance
                case .form:
                    self.form
                case let .connected(name, providerID):
                    self.connected(name: name, providerID: providerID)
                }
            }
        }
        .padding(28)
        .frame(width: 720, height: 650)
        .background(self.theme.palette.windowBackground)
        .onAppear(perform: self.openRequestedProvider)
        .onChange(of: self.draft.connectionIdentity) { _, _ in
            self.cancelModelFetch()
            self.modelFetchError = nil
        }
        .onDisappear { self.cancelModelFetch() }
    }

    private var header: some View {
        HStack {
            if self.step == .form, !self.draft.providerID.isEmpty {
                self.logo(self.draft.providerID, self.draft.name)
            } else {
                Image(systemName: "square.stack.3d.up")
                    .font(.fluidSystem(size: 26)).foregroundStyle(FluidBrandColors.blue)
                    .frame(width: 48, height: 48)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text(self.step == .form ? self.draft.name : "Add a provider").font(self.theme.typography.title)
                Text(self.subtitle)
                    .font(self.theme.typography.body).foregroundStyle(self.theme.palette.secondaryText)
            }
            Spacer()
            if case .connected = self.step {
                EmptyView()
            } else {
                Button("Cancel") { self.dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .fluidGlassAction()
            }
        }
    }

    private var subtitle: String {
        switch self.step {
        case .form: "Add connection details to get started."
        case .connected: "Ready to use."
        case .grid:
            switch self.request.capability {
            case .text: "Providers for Cleanup Styles, Command Mode and Edit."
            case .cloudTranscription: "Providers that transcribe a recording after you stop."
            case .liveTranscription: "Providers that transcribe while you speak."
            case nil: "Your preferred models. Connected to FluidVoice."
            }
        }
    }

    private var reassurance: some View {
        Label("Adding a provider won’t change your current dictation setup.", systemImage: "info.circle")
            .font(self.theme.typography.caption).foregroundStyle(self.theme.palette.secondaryText)
    }

    // MARK: - Grid

    private var grid: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("Choose a provider").font(self.theme.typography.bodyStrong)
                if self.providers.isEmpty, !AIProviderCatalog.offersCustomProvider(for: self.request.capability) {
                    Text("Every provider of this kind is already connected.")
                        .font(self.theme.typography.bodySmall).foregroundStyle(self.theme.palette.secondaryText)
                }
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                    ForEach(self.providers) { provider in
                        Button {
                            self.choose(provider)
                        } label: {
                            HStack(spacing: 14) {
                                self.logo(provider.id, provider.name).accessibilityHidden(true)
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(provider.name).font(self.theme.typography.bodyStrong)
                                    Text(AIProviderCatalog.capabilitySummary(for: provider.id))
                                        .font(self.theme.typography.caption).foregroundStyle(self.theme.palette.secondaryText)
                                }
                                Spacer()
                                Image(systemName: "chevron.right").accessibilityHidden(true)
                            }
                            .padding(16).frame(maxWidth: .infinity, minHeight: 76, alignment: .leading)
                            .contentShape(RoundedRectangle(cornerRadius: 16))
                        }
                        .buttonStyle(ProviderChoiceStyle())
                        .accessibilityIdentifier("add-provider-\(provider.id)")
                    }
                    if AIProviderCatalog.offersCustomProvider(for: self.request.capability) {
                        Button {
                            self.draft = ProviderSetupDraft(name: "Custom Provider")
                            self.saveResult = nil
                            self.step = .form
                        } label: {
                            HStack(spacing: 14) {
                                Image(systemName: "server.rack").font(.fluidSystem(size: 24))
                                    .foregroundStyle(FluidBrandColors.blue).frame(width: 38, height: 38)
                                VStack(alignment: .leading, spacing: 5) {
                                    Text("Custom Provider").font(self.theme.typography.bodyStrong)
                                    Text("Your service or server")
                                        .font(self.theme.typography.caption).foregroundStyle(self.theme.palette.secondaryText)
                                }
                                Spacer()
                                Image(systemName: "plus").foregroundStyle(FluidBrandColors.blue)
                            }.padding(16).contentShape(RoundedRectangle(cornerRadius: 16))
                        }
                        .buttonStyle(ProviderChoiceStyle())
                        .accessibilityIdentifier("add-provider-custom")
                    }
                }
            }
        }
    }

    private func choose(_ provider: ProviderDescriptor) {
        self.draft = ProviderSetupDraft(
            providerID: provider.id,
            name: provider.name,
            baseURL: AIProviderCatalog.isSpeechOnly(provider.id) ? "" : ModelRepository.shared.defaultBaseURL(for: provider.id)
        )
        self.saveResult = nil
        self.showingManualModel = false
        self.step = .form
    }

    /// NAV-2: a request for a provider that is not connected opens its form directly, skipping the grid.
    private func openRequestedProvider() {
        guard !self.didOpenRequestedProvider else { return }
        self.didOpenRequestedProvider = true
        guard let providerID = self.request.providerID,
              let provider = self.providers.first(where: { $0.id == providerID })
        else { return }
        self.choose(provider)
    }

    // MARK: - Form

    private var form: some View {
        VStack(alignment: .leading, spacing: self.theme.metrics.spacing.lg) {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    FluidManagementGroup(title: "Connection details") {
                        if self.draft.providerID.isEmpty {
                            self.field("Name") { TextField("Custom Provider", text: self.$draft.name) }
                            self.field("Server URL") { TextField("https://your-server.com/v1", text: self.$draft.baseURL) }
                        }
                        ProviderAPIKeyField(
                            text: self.$draft.apiKey,
                            hasSavedKey: false,
                            isOptional: !self.draft.requiresAPIKey,
                            link: AIProviderCatalog.keyLink(for: self.draft.providerID),
                            onFocus: { self.viewModel.ensureKeychainAccessForAPIKeyEdit() }
                        )
                    }
                    if !self.isSpeechOnlyDraft {
                        self.modelSection
                    }
                    self.reassurance
                }
            }
            .textFieldStyle(.roundedBorder)
            if let saveResult = self.saveResult {
                ProviderActionResultLabel(result: saveResult)
            }
            Spacer()
            HStack {
                Button("Back") {
                    self.cancelModelFetch()
                    self.step = .grid
                    self.saveResult = nil
                    self.showingManualModel = false
                }
                .fluidGlassAction()
                Spacer()
                Button("Add provider", action: self.add)
                    .keyboardShortcut(.defaultAction)
                    .fluidGlassAction(prominent: true)
                    .disabled(!self.canAdd)
                    .accessibilityIdentifier("add-provider-confirm")
            }
        }
    }

    /// Saves the key (and, for a text provider, its record and models). Makes no network request.
    private func add() {
        let name = self.draft.trimmedName.isEmpty ? self.draft.name : self.draft.trimmedName
        if self.isSpeechOnlyDraft {
            let result = self.viewModel.saveSpeechProviderKey(self.draft.apiKey, for: self.draft.providerID)
            guard case .success = result else {
                self.saveResult = result
                return
            }
        } else if !self.viewModel.addProvider(self.draft) {
            self.saveResult = .failure("Couldn’t save this provider. Check Keychain access and try again.")
            return
        }
        if self.request.origin != nil {
            self.step = .connected(name: name, providerID: self.draft.providerID)
        } else {
            self.dismiss()
        }
    }

    private func connected(name: String, providerID: String) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            Label("\(name) is connected.", systemImage: "checkmark.circle.fill")
                .font(self.theme.typography.bodyStrong)
                .foregroundStyle(Color.fluidGreen)
            Spacer()
            HStack {
                Spacer()
                if let origin = self.request.origin {
                    Button("Back to \(origin.title)") {
                        self.dismiss()
                        self.goBack(origin, providerID)
                    }
                    .fluidGlassAction(prominent: true)
                    .accessibilityIdentifier("add-provider-back")
                }
                Button("Done") { self.dismiss() }
                    .keyboardShortcut(.defaultAction)
                    .fluidGlassAction()
            }
        }
    }

    private var modelSection: some View {
        FluidManagementGroup(title: "Model") {
            HStack(spacing: 8) {
                SearchableModelPicker(
                    models: self.draft.fetchedModels,
                    selectedModel: Binding(
                        get: { self.draft.model },
                        set: { self.draft.selectFetchedModel($0) }
                    ),
                    selectionEnabled: !self.draft.fetchedModels.isEmpty,
                    controlWidth: 430,
                    controlHeight: 36
                )
                Button(action: self.fetchModels) {
                    if self.modelFetchID != nil {
                        ProgressView().controlSize(.small).frame(width: 16, height: 16)
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }
                }
                .fluidGlassAction()
                .disabled(!self.draft.isValid || self.modelFetchID != nil)
                .help("Load models from this provider")
                .accessibilityLabel("Load models")
                Button { self.showingManualModel.toggle() } label: {
                    Image(systemName: "plus")
                }
                .fluidGlassAction()
                .help("Enter a model ID manually")
                .accessibilityLabel("Enter model ID manually")
            }
            if self.showingManualModel {
                self.field("Model ID") { TextField("Enter a model ID", text: self.$draft.model) }
            }
            Text(self.draft.requiresAPIKey && self.draft.apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? "Enter your API key, then load models with the reload button."
                : "Load models with the reload button, or use + to enter a model ID.")
                .font(self.theme.typography.caption).foregroundStyle(self.theme.palette.secondaryText)
            if let error = self.modelFetchError {
                Text(error).font(self.theme.typography.caption).foregroundStyle(.red)
                    .textSelection(.enabled)
            }
        }
    }

    private func cancelModelFetch() {
        self.modelFetchTask?.cancel()
        self.modelFetchTask = nil
        self.modelFetchID = nil
    }

    private func fetchModels() {
        guard self.draft.isValid, self.modelFetchID == nil else { return }
        let snapshot = self.draft
        let requestID = UUID()
        self.modelFetchID = requestID
        self.modelFetchError = nil
        self.modelFetchTask = Task { @MainActor in
            defer {
                if self.modelFetchID == requestID {
                    self.modelFetchID = nil
                    self.modelFetchTask = nil
                }
            }
            do {
                let models = try await ModelRepository.shared.fetchModels(
                    for: snapshot.providerID,
                    baseURL: snapshot.trimmedBaseURL,
                    apiKey: snapshot.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
                )
                guard !Task.isCancelled, self.modelFetchID == requestID,
                      self.draft.connectionIdentity == snapshot.connectionIdentity else { return }
                self.draft.applyFetchedModels(models, for: snapshot.connectionIdentity)
                if models.isEmpty { self.modelFetchError = "No models returned. Load a model on your server and retry, or enter its ID with +." }
            } catch {
                guard !Task.isCancelled, self.modelFetchID == requestID,
                      self.draft.connectionIdentity == snapshot.connectionIdentity else { return }
                self.modelFetchError = error.localizedDescription
            }
        }
    }

    private func field<Control: View>(_ title: String, @ViewBuilder control: () -> Control) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(self.theme.typography.bodyStrong)
            control().textFieldStyle(.roundedBorder).controlSize(.large).accessibilityLabel(title)
        }
    }
}

private struct ProviderChoiceStyle: ButtonStyle {
    @Environment(\.theme) private var theme
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.foregroundStyle(self.theme.palette.primaryText)
            .background(
                configuration.isPressed ? FluidBrandColors.blue.opacity(0.12) : self.theme.palette.cardBackground,
                in: RoundedRectangle(cornerRadius: 16, style: .continuous)
            )
    }
}
