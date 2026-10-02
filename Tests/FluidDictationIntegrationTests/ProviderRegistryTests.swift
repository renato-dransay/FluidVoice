@testable import FluidVoice_Debug
import Foundation
import XCTest

@MainActor
final class ProviderRegistryTests: XCTestCase {
    private let speechOnlyIDs = ["soniox", "deepgram", "elevenlabs", "speechmatics", "gladia"]

    func testLiveIDsMapToRegistryIDsAndBack() {
        let expected: [LiveTranscriptionProviderID: String] = [
            .openAI: "openai", .assemblyAI: "assemblyai", .elevenLabs: "elevenlabs", .soniox: "soniox",
            .deepgram: "deepgram", .mistral: "mistral", .speechmatics: "speechmatics", .gladia: "gladia",
        ]
        XCTAssertEqual(LiveTranscriptionProviderID.allCases.count, 8)
        for live in LiveTranscriptionProviderID.allCases {
            let id = ProviderRegistry.providerID(for: live)
            XCTAssertEqual(id, expected[live], "\(live)")
            XCTAssertEqual(ProviderRegistry.liveProviderID(for: id), live, id)
            XCTAssertEqual(id, id.lowercased())
            XCTAssertTrue(ProviderRegistry.descriptor(for: id)?.capabilities.contains(.liveTranscription) == true, id)
        }
        XCTAssertNil(ProviderRegistry.liveProviderID(for: "anthropic"))
        XCTAssertNil(ProviderRegistry.liveProviderID(for: "openAI"))
    }

    /// The end state of REG-2: every live vendor also transcribes Cloud recordings, and Mistral and
    /// AssemblyAI also serve text.
    func testCapabilitiesMatchTheCodeThatHasShipped() {
        func capabilities(_ id: String) -> Set<ProviderCapability> { ProviderRegistry.descriptor(for: id)?.capabilities ?? [] }
        XCTAssertEqual(capabilities("openai"), [.text, .liveTranscription])
        for id in ["anthropic", "xai", "groq", "cerebras", "google", "ollama", "lmstudio"] {
            XCTAssertEqual(capabilities(id), [.text], id)
        }
        XCTAssertEqual(capabilities("openrouter"), [.text, .cloudTranscription])
        for id in ["mistral", "assemblyai"] {
            XCTAssertEqual(capabilities(id), [.text, .cloudTranscription, .liveTranscription], id)
        }
        for id in self.speechOnlyIDs {
            XCTAssertEqual(capabilities(id), [.cloudTranscription, .liveTranscription], id)
        }
        XCTAssertEqual(
            ProviderRegistry.providers(with: .cloudTranscription).map(\.id),
            ["openrouter", "mistral", "assemblyai", "soniox", "deepgram", "elevenlabs", "speechmatics", "gladia"]
        )
        XCTAssertEqual(Set(ProviderRegistry.all.map(\.id)).count, ProviderRegistry.all.count)
        XCTAssertFalse(ProviderRegistry.descriptor(for: "ollama")?.requiresAPIKey ?? true)
        XCTAssertFalse(ProviderRegistry.descriptor(for: "lmstudio")?.requiresAPIKey ?? true)
        XCTAssertTrue(ProviderRegistry.all.filter { !["ollama", "lmstudio"].contains($0.id) }.allSatisfy(\.requiresAPIKey))
    }

    func testEveryTextProviderIsBuiltInAndEveryBuiltInIsRegistered() {
        let textIDs = Set(ProviderRegistry.providers(with: .text).map(\.id))
        let builtIn = Set(ModelRepository.builtInProviderIDs).subtracting([PrivateAIProviderFeature.shared.providerID])
        XCTAssertEqual(textIDs, builtIn)
    }

    func testKeyAndUsageLinksComeFromTheExistingCatalogs() {
        for descriptor in ProviderRegistry.all {
            if let live = ProviderRegistry.liveProviderID(for: descriptor.id) {
                XCTAssertEqual(descriptor.usageURL, LiveTranscriptionCatalog.info(for: live).usageURL, descriptor.id)
            }
            if let website = ModelRepository.providerWebsiteURL(for: descriptor.id) {
                XCTAssertEqual(descriptor.keyURL, URL(string: website.url), descriptor.id)
            } else if let live = ProviderRegistry.liveProviderID(for: descriptor.id) {
                XCTAssertEqual(descriptor.keyURL, LiveTranscriptionCatalog.info(for: live).keyURL, descriptor.id)
            }
            XCTAssertNotNil(descriptor.keyURL, descriptor.id)
        }
    }

    func testProviderKeyIsTheBareIDForEveryRegistryProvider() {
        for descriptor in ProviderRegistry.all {
            XCTAssertEqual(ProviderRegistry.providerKey(for: descriptor.id), descriptor.id)
            XCTAssertEqual(ModelRepository.shared.providerKey(for: descriptor.id), descriptor.id)
            XCTAssertEqual(ModelRepository.shared.providerKeys(for: descriptor.id), [descriptor.id])
            XCTAssertEqual(ModelRepository.shared.normalizedStoredProviderKey(descriptor.id), descriptor.id)
            XCTAssertEqual(ModelRepository.shared.normalizedStoredProviderKey(descriptor.id.uppercased()), descriptor.id)
            XCTAssertEqual(DictationAIPostProcessingGate.providerKey(for: descriptor.id), descriptor.id)
        }
    }

    func testProviderKeyPrefixesAnyOtherIDOnce() {
        XCTAssertEqual(ProviderRegistry.providerKey(for: "local-server"), "custom:local-server")
        XCTAssertEqual(ProviderRegistry.providerKey(for: " local-server "), "custom:local-server")
        XCTAssertEqual(ProviderRegistry.providerKey(for: "custom:local-server"), "custom:local-server")
        XCTAssertEqual(ProviderRegistry.providerKey(for: ""), "")
        XCTAssertEqual(ProviderRegistry.providerKey(for: "fluid", isBuiltIn: { $0 == "fluid" }), "fluid")
        XCTAssertEqual(ModelRepository.shared.providerKey(for: "local-server"), "custom:local-server")
        XCTAssertEqual(Set(ModelRepository.shared.providerKeys(for: "local-server")), ["custom:local-server", "local-server"])
        XCTAssertEqual(ModelRepository.shared.normalizedStoredProviderKey("Local-Server"), "custom:Local-Server")
        XCTAssertEqual(ProviderRegistry.savedProviderID(fromProviderKey: "custom:local-server"), "local-server")
        XCTAssertEqual(ProviderRegistry.savedProviderID(fromProviderKey: "openai"), "openai")
    }

    /// The custom prefix is built in one place only, so the bare-ID rule cannot drift.
    func testNoOtherSourceBuildsTheCustomPrefix() throws {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/Fluid", isDirectory: true)
        let enumerator = try XCTUnwrap(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
        var offenders: [String] = []
        var scanned = 0
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            scanned += 1
            guard url.lastPathComponent != "ProviderRegistry.swift" else { continue }
            let text = try String(contentsOf: url, encoding: .utf8)
            if text.contains("\"custom:") { offenders.append(url.lastPathComponent) }
        }
        XCTAssertGreaterThan(scanned, 100)
        XCTAssertEqual(offenders, [])
    }

    func testSpeechOnlyProvidersNeverBecomeTextProviders() {
        let builtInList = ModelRepository.shared.builtInProvidersList().map(\.id)
        for id in self.speechOnlyIDs {
            XCTAssertFalse(builtInList.contains(id), id)
            XCTAssertFalse(ModelRepository.builtInProviderIDs.contains(id), id)
            XCTAssertFalse(ModelRepository.shared.isBuiltIn(id), id)
        }
    }

    /// Every provider the registry offers for Cloud transcription has a client and a model catalog (CLD-4).
    func testEveryCloudTranscriptionProviderHasAClientAndACatalog() {
        for descriptor in ProviderRegistry.providers(with: .cloudTranscription) {
            let client = CloudTranscriptionClients.client(for: descriptor.id)
            XCTAssertNotNil(client, descriptor.id)
            XCTAssertEqual(client?.providerID, descriptor.id)
            XCTAssertEqual(client?.providerName, descriptor.name)
            XCTAssertFalse(CloudTranscriptionCatalog.models(for: descriptor.id).isEmpty, descriptor.id)
        }
        XCTAssertEqual(
            Set(CloudTranscriptionClients.providerIDs),
            Set(ProviderRegistry.providers(with: .cloudTranscription).map(\.id)),
            "A client ships together with the registry capability"
        )
    }
}
