import Foundation

@main
enum DictationStopOverlayPolicyTests {
    private struct Case {
        let name: String
        let input: DictationStopOverlayPolicy.Input
        let hides: Bool
    }

    static func main() {
        let plainLocal = DictationStopOverlayPolicy.Input(
            isNormalRoute: true,
            isRewrite: false,
            isCommand: false,
            isPromptTestActive: false,
            usesAIOnStop: false,
            spokenSendEnabled: false,
            usesCloudTranscription: false
        )
        var plainCloud = plainLocal
        plainCloud.usesCloudTranscription = true
        var styledLocal = plainLocal
        styledLocal.usesAIOnStop = true
        var spokenSendLocal = plainLocal
        spokenSendLocal.spokenSendEnabled = true
        var rewrite = plainLocal
        rewrite.isRewrite = true
        var command = plainLocal
        command.isCommand = true
        var promptTest = plainLocal
        promptTest.isPromptTestActive = true
        var sandboxRoute = plainLocal
        sandboxRoute.isNormalRoute = false

        let cases: [Case] = [
            .init(name: "plain local dictation hides at stop", input: plainLocal, hides: true),
            .init(name: "plain cloud dictation keeps the overlay", input: plainCloud, hides: false),
            .init(name: "styled local dictation keeps the overlay", input: styledLocal, hides: false),
            .init(name: "spoken send keeps the overlay", input: spokenSendLocal, hides: false),
            .init(name: "rewrite keeps the overlay", input: rewrite, hides: false),
            .init(name: "command keeps the overlay", input: command, hides: false),
            .init(name: "prompt test keeps the overlay", input: promptTest, hides: false),
            .init(name: "non-normal route keeps the overlay", input: sandboxRoute, hides: false),
        ]
        var failures = 0
        for test in cases {
            let hides = DictationStopOverlayPolicy.shouldHideOverlayOnStop(test.input)
            if hides != test.hides {
                failures += 1
                print("FAIL \(test.name): expected hides=\(test.hides), got \(hides)")
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
