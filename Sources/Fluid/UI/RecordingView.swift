//
//  RecordingView.swift
//  fluid
//
//  Recording controls and configuration view
//

import AVFoundation
import SwiftUI

struct RecordingView: View {
    @EnvironmentObject var appServices: AppServices
    private var asr: ASRService { self.appServices.asr }
    @Environment(\.theme) private var theme
    @ObservedObject private var settings = SettingsStore.shared
    @Binding var appear: Bool

    let stopAndProcessTranscription: () async -> Void
    let startRecording: () -> Void

    private var isReadyToRecord: Bool {
        if self.settings.storedLiveProvider != nil { return self.settings.usesLiveCloudDictation }
        return self.settings.usesCloudTranscription
            ? !self.settings.openRouterTranscriptionAPIKey.isEmpty
            : self.asr.isAsrReady
    }

    private var notReadyText: String {
        if let message = self.settings.missingLiveKeyMessage { return message }
        return self.settings.usesCloudTranscription ? "OpenRouter key required" : "Model not ready"
    }

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: 14) {
                // Hero Header Card
                ThemedCard(style: .standard) {
                    VStack(spacing: 12) {
                        HStack {
                            Image(systemName: "waveform.circle.fill")
                                .font(.fluidSystem(size: 32))
                                .foregroundStyle(.white)

                            VStack(alignment: .leading, spacing: 4) {
                                Text("Voice Dictation")
                                    .font(.fluidSystem(.title2))
                                    .fontWeight(.bold)
                                Text("AI-powered speech recognition")
                                    .font(.fluidSystem(.subheadline))
                                    .foregroundStyle(.secondary)
                            }

                            Spacer()
                        }

                        // Status and Recording Control
                        VStack(spacing: 10) {
                            // Status indicator
                            HStack {
                                Circle()
                                    .fill(self.asr.isRunning ? .red : self.isReadyToRecord ? Color.fluidGreen : .secondary)
                                    .frame(width: 8, height: 8)

                                Text(self.asr.isRunning ? "Recording..." : self.isReadyToRecord ? "Ready to record" : self.notReadyText)
                                    .font(.fluidSystem(.subheadline))
                                    .foregroundStyle(self.asr.isRunning ? .red : self.isReadyToRecord ? Color.fluidGreen : .secondary)
                            }

                            // Recording Control (Single Toggle Button)
                            Button(action: {
                                if self.asr.isRunning {
                                    Task {
                                        await self.stopAndProcessTranscription()
                                    }
                                } else {
                                    self.startRecording()
                                }
                            }) {
                                HStack {
                                    Image(systemName: self.asr.isRunning ? "stop.fill" : "mic.fill")
                                        .font(.fluidSystem(size: 16, weight: .semibold))
                                    Text(self.asr.isRunning ? "Stop Recording" : "Start Recording")
                                }
                                .frame(maxWidth: .infinity)
                            }
                            .fluidButton(.primary, size: .large, isRecording: self.asr.isRunning)
                            .buttonHoverEffect()
                            .scaleEffect(self.asr.isRunning ? 1.05 : 1.0)
                            .animation(.spring(response: 0.3), value: self.asr.isRunning)
                            .disabled((!self.isReadyToRecord || self.asr.activeExclusiveActivity != nil) && !self.asr.isRunning)
                        }
                    }
                    .padding(14)
                }
                .modifier(CardAppearAnimation(delay: 0.1, appear: self.$appear))
            }
            .padding(14)
        }
    }
}
