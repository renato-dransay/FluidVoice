import Foundation

/// Turns provider updates into the text shown while speaking and the final text. Pure and
/// value-typed so every provider's assembly rules are tested without a socket.
nonisolated struct LiveTranscriptAssembler: Equatable, Sendable {
    private var order: [String] = []
    private var segments: [String: LiveTranscriptSegment] = [:]
    private var pending = ""
    private var generation = 0
    /// First audio millisecond of each connection, relative to the start of the recording.
    private var generationStart: [Int: Int] = [0: 0]

    mutating func apply(_ update: LiveTranscriptUpdate) {
        switch update {
        case .segment(let segment):
            let key = Self.key(self.generation, segment.id)
            if self.segments[key] == nil { self.order.append(key) }
            self.segments[key] = segment
        case .pending(let text):
            self.pending = text
        case .replaceAll(let text):
            let current = self.generation
            self.removeSegments { generation, _ in generation == current }
            let key = Self.key(current, "all")
            self.order.append(key)
            self.segments[key] = LiveTranscriptSegment(id: "all", text: text, isFinal: true, audioEndMilliseconds: nil)
            self.pending = ""
        case .reply, .ready, .finished, .failure:
            break
        }
    }

    var displayText: String {
        Self.join(self.order.compactMap { self.segments[$0]?.text } + [self.pending])
    }

    /// At finish every segment is final; a segment still provisional then is the provider's best text.
    var finalText: String {
        Self.join(self.order.compactMap { self.segments[$0]?.text })
    }

    /// Prepares for a new connection after a drop or a language change and returns the recording
    /// position, in milliseconds, whose audio the new connection must receive again.
    mutating func beginGeneration() -> Int {
        let current = self.generation
        let start = self.generationStart[current] ?? 0
        let finals = self.order.compactMap { key -> LiveTranscriptSegment? in
            guard Self.generation(of: key) == current, let segment = self.segments[key], segment.isFinal else { return nil }
            return segment
        }
        let ends = finals.compactMap(\.audioEndMilliseconds)
        let resume: Int
        if !finals.isEmpty, ends.count == finals.count, let last = ends.max() {
            resume = start + last
            self.removeSegments { generation, segment in generation == current && !segment.isFinal }
        } else {
            // No finals, or some carry no timing: no position after them is known, so replay this connection whole.
            resume = start
            self.removeSegments { generation, _ in generation == current }
        }
        self.pending = ""
        self.generation += 1
        self.generationStart[self.generation] = resume
        return resume
    }

    private mutating func removeSegments(where shouldRemove: (Int, LiveTranscriptSegment) -> Bool) {
        var kept: [String] = []
        for key in self.order {
            if let segment = self.segments[key], shouldRemove(Self.generation(of: key), segment) {
                self.segments[key] = nil
            } else {
                kept.append(key)
            }
        }
        self.order = kept
    }

    private static func key(_ generation: Int, _ id: String) -> String { "\(generation):\(id)" }

    private static func generation(of key: String) -> Int {
        Int(key.prefix { $0 != ":" }) ?? 0
    }

    /// Provider pieces either carry their own leading space (Soniox tokens) or none (Deepgram
    /// transcripts). Insert one space only where neither side has whitespace and the next piece
    /// does not start with punctuation.
    static func join(_ parts: [String]) -> String {
        var result = ""
        for part in parts where !part.isEmpty {
            if let last = result.last, let first = part.first,
               !last.isWhitespace, !first.isWhitespace, !first.isPunctuation {
                result.append(" ")
            }
            result.append(part)
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
