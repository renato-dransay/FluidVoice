@testable import FluidVoice_Debug
import Foundation
import XCTest

extension XCTestCase {
    /// The test host shares the app's preferences domain, so a developer who dictates through
    /// OpenRouter or a Live cloud provider would otherwise run local-dictation tests on the cloud
    /// path. Pins local dictation for the current test and restores the stored value afterwards.
    func pinLocalSpeechExecutionSource() {
        let key = "SpeechExecutionSource"
        let defaults = UserDefaults.standard
        let stored = defaults.object(forKey: key)
        var preferences = CloudTranscriptionPreferences(defaults: defaults)
        preferences.source = .local
        self.addTeardownBlock {
            if let stored {
                defaults.set(stored, forKey: key)
            } else {
                defaults.removeObject(forKey: key)
            }
        }
    }
}
