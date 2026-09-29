import Foundation

/// Keeps the personal application and its mutable data separate from upstream builds.
nonisolated enum ForkIdentity {
    static let personalBundleIdentifier = "com.renatobeltrao.fluidvoice.personal"
    static let personalAppName = "FluidVoice Personal"

    static var isPersonalBuild: Bool {
        Bundle.main.bundleIdentifier == self.personalBundleIdentifier
    }

    static func appSupportFolderName(legacyName: String) -> String {
        self.isPersonalBuild ? self.personalAppName : legacyName
    }

    static var keychainServiceName: String {
        self.isPersonalBuild
            ? "\(self.personalBundleIdentifier).provider-api-keys"
            : "com.fluidvoice.provider-api-keys"
    }

    static var logFolderName: String {
        self.appSupportFolderName(legacyName: "Fluid")
    }

    static func applicationSupportURL(fileManager: FileManager = .default) -> URL? {
        fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent(self.appSupportFolderName(legacyName: "FluidVoice"), isDirectory: true)
    }
}
