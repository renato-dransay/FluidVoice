import Foundation

/// A widget choice is remembered per app and shortcut slot, separate from saved rules.
struct ForegroundAppOverride<Value> {
    private(set) var appID: String?
    private var choices: [String: [String: Value]] = [:]

    @discardableResult
    mutating func activate(_ appID: String?) -> Bool {
        guard let appID, !appID.isEmpty, appID != self.appID else { return false }
        self.appID = appID
        return true
    }

    @discardableResult
    mutating func select(_ value: Value, slot: String, appID: String) -> Bool {
        guard appID == self.appID else { return false }
        let key = Self.storageKey(appID)
        guard !key.isEmpty else { return false }
        self.choices[key, default: [:]][slot] = value
        return true
    }

    func choice(slot: String, appID: String?) -> Value? {
        guard let appID else { return nil }
        let key = Self.storageKey(appID)
        guard !key.isEmpty else { return nil }
        return self.choices[key]?[slot]
    }

    mutating func mergeAbsentChoices(_ incoming: [String: [String: Value]]) {
        for (appID, slots) in incoming {
            let key = Self.storageKey(appID)
            guard !key.isEmpty else { continue }
            var existing = self.choices[key] ?? [:]
            for (slot, value) in slots where existing[slot] == nil {
                existing[slot] = value
            }
            if !existing.isEmpty {
                self.choices[key] = existing
            }
        }
    }

    mutating func removeAllChoices() {
        self.choices.removeAll(keepingCapacity: true)
    }

    mutating func removeChoices(appID: String) {
        let key = Self.storageKey(appID)
        guard !key.isEmpty else { return }
        self.choices.removeValue(forKey: key)
    }

    mutating func removeChoice(slot: String, appID: String) {
        let key = Self.storageKey(appID)
        guard !key.isEmpty, var slots = self.choices[key] else { return }
        slots.removeValue(forKey: slot)
        if slots.isEmpty {
            self.choices.removeValue(forKey: key)
        } else {
            self.choices[key] = slots
        }
    }

    mutating func removeChoices(where shouldRemove: (Value) -> Bool) {
        for key in Array(self.choices.keys) {
            guard var slots = self.choices[key] else { continue }
            let before = slots.count
            slots = slots.filter { !shouldRemove($0.value) }
            if slots.isEmpty {
                self.choices.removeValue(forKey: key)
            } else if slots.count != before {
                self.choices[key] = slots
            }
        }
    }

    static func storageKey(_ appID: String) -> String {
        appID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}
