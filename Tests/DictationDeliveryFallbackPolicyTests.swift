import Foundation

@main
enum DictationDeliveryFallbackPolicyTests {
    private struct Case {
        let name: String
        let restoreSucceeded: Bool
        let returnToStartingField: Bool
        let focusedPID: pid_t?
        let notEditable: Bool
        let expected: pid_t?
    }

    static func main() {
        let own: pid_t = 42
        let cases: [Case] = [
            .init(name: "restore succeeded keeps the captured target", restoreSucceeded: true, returnToStartingField: false, focusedPID: 200, notEditable: false, expected: nil),
            .init(name: "failed restore follows the caret in another app", restoreSucceeded: false, returnToStartingField: false, focusedPID: 200, notEditable: false, expected: 200),
            .init(name: "return-to-start setting never follows the caret", restoreSucceeded: false, returnToStartingField: true, focusedPID: 200, notEditable: false, expected: nil),
            .init(name: "FluidVoice's own window is not a destination", restoreSucceeded: false, returnToStartingField: false, focusedPID: own, notEditable: false, expected: nil),
            .init(name: "unknown focus is not a destination", restoreSucceeded: false, returnToStartingField: false, focusedPID: nil, notEditable: false, expected: nil),
            .init(name: "invalid pid is not a destination", restoreSucceeded: false, returnToStartingField: false, focusedPID: 0, notEditable: false, expected: nil),
            .init(name: "a button is not a destination", restoreSucceeded: false, returnToStartingField: false, focusedPID: 200, notEditable: true, expected: nil),
        ]
        var failures = 0
        for test in cases {
            let result = DictationDeliveryFallbackPolicy.currentCaretPID(
                restoreSucceeded: test.restoreSucceeded,
                returnToStartingField: test.returnToStartingField,
                focusedPID: test.focusedPID,
                ownPID: own,
                focusedElementIsCertainlyNotEditable: test.notEditable
            )
            if result != test.expected {
                failures += 1
                print("FAIL \(test.name): expected \(String(describing: test.expected)), got \(String(describing: result))")
            } else {
                print("PASS \(test.name)")
            }
        }
        if failures > 0 {
            print("\(failures) failure(s)")
            exit(1)
        }
        print("All \(cases.count) cases passed")
    }
}
