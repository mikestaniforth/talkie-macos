import SwiftUI
import AppKit

/// Scalar presentation data lets the actual HUD be rendered with synthetic
/// states without creating the app model, opening history or using a microphone.
struct RecordingHUDPresentation: Equatable {
    enum Activity: Equatable { case recording, testing, starting, transcribing, receipt }
    var activity: Activity
    var elapsed: TimeInterval = 0
    var level: Double = 0
    var label: String = ""
    var detail: String = ""
    var symbolName: String = "waveform"
    var isWarning = false
    var canCopy = false
}

struct RecordingHUDSurface: View {
    let presentation: RecordingHUDPresentation
    var onStop: () -> Void = {}
    var onCopy: () -> Void = {}
    var onDismiss: () -> Void = {}
    var onOpenLibrary: () -> Void = {}
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var elapsed: String {
        let seconds = max(0, Int(presentation.elapsed))
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }

    var body: some View {
        HStack(spacing: 9) {
            switch presentation.activity {
            case .recording, .testing:
                Image(systemName: "mic.fill").font(.system(size: 12, weight: .medium))
                    .foregroundStyle(presentation.isWarning ? Color.orange : Color.red).frame(width: 14)
                    .accessibilityLabel(presentation.isWarning ? "Recording microphone. Audio needs review." : "Recording microphone")
                inputLevel
                Spacer(minLength: 2)
                Text(presentation.activity == .testing ? "Mic test" : elapsed)
                    .font(.system(size: 12, weight: .medium)).monospacedDigit().foregroundStyle(Color.primary.opacity(0.75))
                    .accessibilityLabel(presentation.activity == .testing ? "Microphone test" : "Recording time \(elapsed)")
                iconButton("stop.fill", label: "Finish recording", action: onStop)
            case .starting, .transcribing:
                ProgressView().controlSize(.small).frame(width: 14, height: 14)
                Text(presentation.activity == .starting ? "Getting ready…" : "Transcribing…")
                    .font(.system(size: 12, weight: .medium)).lineLimit(1)
                    .accessibilityLabel(presentation.detail)
                Spacer(minLength: 0)
            case .receipt:
                Button(action: onOpenLibrary) {
                    HStack(spacing: 7) {
                        Image(systemName: presentation.symbolName).font(.system(size: 12))
                            .foregroundStyle(presentation.isWarning ? Color.orange : Color.secondary)
                        Text(presentation.label).font(.system(size: 12, weight: .medium))
                            .lineLimit(1).truncationMode(.tail)
                    }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                }.buttonStyle(.plain).help(presentation.detail + " Open Library.")
                    .accessibilityLabel(presentation.detail + " Open Library.")
                if presentation.canCopy { iconButton("doc.on.doc", label: "Copy dictation", action: onCopy) }
                iconButton("xmark", label: "Dismiss recording status", action: onDismiss)
            }
        }
        .padding(.horizontal, 12).frame(width: 212, height: 44)
        .modifier(RecordingHUDGlass())
        .padding(8)
        .help(presentation.detail)
        .accessibilityElement(children: .contain).accessibilityLabel("Talkie dictation")
        .transaction { if reduceMotion { $0.disablesAnimations = true } }
    }

    private var inputLevel: some View {
        HStack(spacing: 3) {
            ForEach(0..<8) { index in
                Capsule().fill(Double(index) / 8 < min(1, max(0, presentation.level))
                               ? Color.primary.opacity(0.75) : Color.primary.opacity(0.12))
                    .frame(width: 2, height: 14)
            }
        }
        .accessibilityElement(children: .ignore).accessibilityLabel("Microphone input level")
        .accessibilityValue("\(Int(min(1, max(0, presentation.level)) * 100)) percent")
    }

    private func iconButton(_ symbol: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: symbol == "stop.fill" ? 10 : 11, weight: .medium))
                .frame(width: 28, height: 28).contentShape(Circle())
        }
        .buttonStyle(.plain).help(label).accessibilityLabel(label)
    }
}

private struct RecordingHUDGlass: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    @ViewBuilder func body(content: Content) -> some View {
        if reduceTransparency || contrast == .increased {
            content.background(Color(nsColor: .windowBackgroundColor), in: Capsule())
                .overlay(Capsule().strokeBorder(Color(nsColor: .separatorColor), lineWidth: contrast == .increased ? 1 : 0.5))
        } else if #available(macOS 26.0, *) {
            content.glassEffect(.regular, in: Capsule())
        } else {
            content.background(.regularMaterial, in: Capsule())
        }
    }
}
