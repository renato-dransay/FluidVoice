import Foundation

/// The rows the shared `SearchableModelPicker` shows for speech models: Voice Engine's Cloud tab and the
/// Live cloud sheet. Each row names the model and, where it matters, says why it differs: the default, a
/// model without word timings, a model the key may not use, or a stored model a catalog no longer lists.
enum SpeechModelPickerItems {
    static let defaultDetail = "Default"
    static let noWordTimingsDetail = "No word timings"
    static let uncheckedWordTimingsDetail = "Word timings not checked"
    static let unavailableDetail = "Not offered for this key"
    static let unlistedDetail = "No longer listed"

    /// A Cloud provider's speech models from its catalog (CLD-4), default first.
    static func cloud(providerID: String, selected: String) -> [SearchableModelPickerItem] {
        let models = CloudTranscriptionCatalog.models(for: providerID)
        let defaultID = CloudTranscriptionCatalog.defaultModelID(for: providerID)
        let items = models.map { model in
            SearchableModelPickerItem(id: model.id, name: model.name, detail: self.detail(for: model, isDefault: model.id == defaultID))
        }
        return SearchableModelPickerItem.including(selection: selected, in: items, unlistedDetail: self.unlistedDetail)
    }

    /// OpenRouter's speech models. After a listing check (`validatedIDs` non-nil) a model the key cannot
    /// use stays visible but cannot be chosen.
    static func openRouterSpeech(models: [CloudTranscriptionModel], selected: String, validatedIDs: Set<String>?) -> [SearchableModelPickerItem] { // swiftlint:disable:this discouraged_optional_collection
        let items = models.map { model in
            let isAvailable = validatedIDs?.contains(model.id) ?? true
            return SearchableModelPickerItem(
                id: model.id,
                name: model.name,
                detail: isAvailable ? self.detail(for: model, isDefault: model.id == CloudTranscriptionModel.defaultDictationID) : self.unavailableDetail,
                isEnabled: isAvailable
            )
        }
        return SearchableModelPickerItem.including(selection: selected, in: items, unlistedDetail: self.unlistedDetail)
    }

    /// OpenRouter's style models, Automatic first. `automaticName` is the model Automatic resolves to.
    static func openRouterStyle(models: [CloudAudioDictationModel], automaticName: String, validatedIDs: Set<String>?) -> [SearchableModelPickerItem] { // swiftlint:disable:this discouraged_optional_collection
        let automatic = SearchableModelPickerItem(
            id: CloudAudioDictationModel.automaticID,
            name: "Automatic (\(automaticName))",
            detail: "Follows the OpenRouter model in AI Providers"
        )
        return [automatic] + models.map { model in
            let isAvailable = validatedIDs?.contains(model.id) ?? true
            return SearchableModelPickerItem(
                id: model.id,
                name: model.name,
                detail: isAvailable ? nil : self.unavailableDetail,
                isEnabled: isAvailable
            )
        }
    }

    /// A live provider's streaming models, default first.
    static func live(provider: LiveTranscriptionProviderID, selected: String) -> [SearchableModelPickerItem] {
        let info = LiveTranscriptionCatalog.info(for: provider)
        let items = info.models.map { model in
            SearchableModelPickerItem(
                id: model.id,
                name: model.name,
                detail: self.joined([model.id == info.defaultModelID ? self.defaultDetail : nil, model.note])
            )
        }
        return SearchableModelPickerItem.including(selection: selected, in: items, unlistedDetail: self.unlistedDetail)
    }

    private static func detail(for model: CloudTranscriptionModel, isDefault: Bool) -> String? {
        let timings: String? = switch model.wordTimingSupport {
        case .supported: nil
        case .unsupported: self.noWordTimingsDetail
        case .unverified: self.uncheckedWordTimingsDetail
        }
        return self.joined([isDefault ? self.defaultDetail : nil, model.note, timings])
    }

    private static func joined(_ parts: [String?]) -> String? {
        let parts = parts.compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}
