import Combine
import Foundation

extension SettingsStore {
    var meetingRecordingLanguageCode: String {
        self.meetingTranscriptionBackendID == .openRouterNemotron ? self.meetingCloudLanguageCode : "en"
    }

    var meetingCloudModelID: String {
        get { UserDefaults.standard.string(forKey: "MeetingCloudModelID") ?? CloudTranscriptionModel.defaultMeetingID }
        set {
            self.objectWillChange.send()
            UserDefaults.standard.set(newValue, forKey: "MeetingCloudModelID")
        }
    }

    var meetingCloudLanguageCode: String {
        get { UserDefaults.standard.string(forKey: "MeetingCloudLanguageCode") ?? MeetingCloudLanguage.automatic }
        set {
            self.objectWillChange.send()
            UserDefaults.standard.set(newValue, forKey: "MeetingCloudLanguageCode")
        }
    }

    func meetingFinalConfiguration(backendID: MeetingBackendID, recordedLanguageCode: String) -> MeetingFinalProcessingConfiguration {
        if backendID == .openRouterNemotron {
            return MeetingFinalProcessingConfiguration(
                asrProvider: .openRouter,
                asrModel: self.meetingCloudModelID,
                languageCode: self.meetingCloudLanguageCode
            )
        }
        return MeetingFinalProcessingConfiguration(languageCode: recordedLanguageCode == MeetingCloudLanguage.automatic ? "en" : recordedLanguageCode)
    }
}
