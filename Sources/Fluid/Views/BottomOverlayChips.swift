import SwiftUI

/// Sizing for the controls that sit in the dictation overlay's control row.
///
/// Every chip in the row (language, prompt, mode, actions) reads its metrics from here,
/// so the controls stay the same height and weight as each other and scale with the
/// overlay size instead of being tuned one by one.
struct OverlayChipMetrics: Equatable {
    let fontSize: CGFloat
    let iconSize: CGFloat
    let horizontalPadding: CGFloat
    let verticalPadding: CGFloat
    let spacing: CGFloat
    let maxLabelWidth: CGFloat

    /// Height of a chip with a single text line, used to size icon-only chips to match.
    var height: CGFloat {
        ceil(self.fontSize * 1.25) + self.verticalPadding * 2
    }

    // JUDGMENT: Font steps follow the overlay's own transcription font steps
    // (10/11/13/15), one point smaller so chips stay secondary to the text.
    static func forSize(_ size: SettingsStore.OverlaySize) -> OverlayChipMetrics {
        switch size {
        case .pill:
            return OverlayChipMetrics(fontSize: 9, iconSize: 9, horizontalPadding: 6, verticalPadding: 3, spacing: 3, maxLabelWidth: 120)
        case .small:
            return OverlayChipMetrics(fontSize: 10, iconSize: 10, horizontalPadding: 7, verticalPadding: 4, spacing: 4, maxLabelWidth: 96)
        case .medium:
            return OverlayChipMetrics(fontSize: 11, iconSize: 10, horizontalPadding: 8, verticalPadding: 5, spacing: 4, maxLabelWidth: 84)
        case .large:
            return OverlayChipMetrics(fontSize: 13, iconSize: 12, horizontalPadding: 11, verticalPadding: 6, spacing: 5, maxLabelWidth: 170)
        }
    }
}

/// Capsule surface shared by every overlay control, so a control reads as a control
/// before the pointer reaches it.
struct OverlayChipSurface: ViewModifier {
    let metrics: OverlayChipMetrics
    var isHovered = false
    var isPressed = false
    var isDisabled = false

    private var fillOpacity: Double {
        if self.isDisabled {
            return 0.04
        }
        if self.isPressed {
            return 0.18
        }
        return self.isHovered ? 0.14 : 0.08
    }

    func body(content: Content) -> some View {
        content
            .foregroundStyle(Color.white.opacity(self.isDisabled ? 0.45 : 0.88))
            .padding(.horizontal, self.metrics.horizontalPadding)
            .padding(.vertical, self.metrics.verticalPadding)
            .background(Capsule(style: .continuous).fill(Color.white.opacity(self.fillOpacity)))
            .overlay(Capsule(style: .continuous).strokeBorder(Color.white.opacity(self.isHovered ? 0.24 : 0.14), lineWidth: 1))
            .contentShape(Capsule(style: .continuous))
    }
}

extension View {
    func overlayChipSurface(
        _ metrics: OverlayChipMetrics,
        isHovered: Bool = false,
        isPressed: Bool = false,
        isDisabled: Bool = false
    ) -> some View {
        modifier(OverlayChipSurface(metrics: metrics, isHovered: isHovered, isPressed: isPressed, isDisabled: isDisabled))
    }
}

/// Icon, label and disclosure chevron laid out for an overlay chip.
///
/// Long labels truncate through layout at `maxLabelWidth`, never by cutting the string,
/// so the chip keeps its shape and the full name stays available to help and VoiceOver.
struct OverlayChipLabel: View {
    let metrics: OverlayChipMetrics
    var systemImage: String?
    let text: String
    var badge: String?
    var showsChevron = true

    var body: some View {
        HStack(spacing: self.metrics.spacing) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.fluidSystem(size: self.metrics.iconSize, weight: .semibold))
                    .opacity(0.8)
            }
            Text(self.text)
                .font(.fluidSystem(size: self.metrics.fontSize, weight: .semibold))
                .lineLimit(1)
                .truncationMode(.tail)
                .modifier(OverlayChipWidthCap(maxWidth: self.metrics.maxLabelWidth))
            if let badge {
                Text(badge)
                    .font(.fluidSystem(size: max(self.metrics.fontSize - 2, 8), weight: .bold))
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(Color.white.opacity(0.16)))
            }
            if self.showsChevron {
                Image(systemName: "chevron.down")
                    .font(.fluidSystem(size: max(self.metrics.fontSize - 3, 7), weight: .bold))
                    .opacity(0.55)
            }
        }
        .fixedSize(horizontal: true, vertical: false)
    }
}

/// Caps a label's width while reporting the width the truncated text actually uses.
///
/// `.frame(maxWidth:)` reports the cap itself once text truncates, which leaves a gap
/// between the ellipsis and the chevron; this layout hugs the truncated text instead.
private struct OverlayChipWidthCap: ViewModifier {
    let maxWidth: CGFloat

    func body(content: Content) -> some View {
        WidthCapLayout(maxWidth: self.maxWidth) { content }
    }
}

private struct WidthCapLayout: Layout {
    let maxWidth: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache _: inout ()) -> CGSize {
        guard let child = subviews.first else { return .zero }
        let width = min(proposal.width ?? .infinity, self.maxWidth)
        return child.sizeThatFits(ProposedViewSize(width: width, height: proposal.height))
    }

    func placeSubviews(in bounds: CGRect, proposal _: ProposedViewSize, subviews: Subviews, cache _: inout ()) {
        subviews.first?.place(
            at: CGPoint(x: bounds.minX, y: bounds.midY),
            anchor: .leading,
            proposal: ProposedViewSize(width: bounds.width, height: bounds.height)
        )
    }
}

/// Button style for SwiftUI `Menu` chips (the cloud language selector) so they match
/// the tap-gesture chips in the same row.
struct OverlayChipButtonStyle: ButtonStyle {
    let metrics: OverlayChipMetrics

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .overlayChipSurface(self.metrics, isPressed: configuration.isPressed)
    }
}
