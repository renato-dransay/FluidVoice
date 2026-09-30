import Foundation

/// After a cloud dictation the field captured at the stop hotkey may be gone:
/// the user clicked elsewhere while the request ran. When the app could not
/// restore that field and the user has asked dictation to follow the cursor,
/// the caret they have now is the destination, provided it is in another app
/// and is not a control that certainly refuses text.
enum DictationDeliveryFallbackPolicy {
    static func currentCaretPID(
        restoreSucceeded: Bool,
        returnToStartingField: Bool,
        focusedPID: pid_t?,
        ownPID: pid_t,
        focusedElementIsCertainlyNotEditable: Bool
    ) -> pid_t? {
        guard !restoreSucceeded, !returnToStartingField,
              let focusedPID, focusedPID > 0, focusedPID != ownPID,
              !focusedElementIsCertainlyNotEditable
        else { return nil }
        return focusedPID
    }
}
