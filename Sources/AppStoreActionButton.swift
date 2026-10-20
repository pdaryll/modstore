import SwiftUI

struct AppStoreActionButton: View {
    let state: InstallState
    var alignment: Alignment = .center
    var onAction: () -> Void
    var onCancel: () -> Void

    private let pillWidth: CGFloat = 82
    private let height: CGFloat = 30

    @State private var currentWidth: CGFloat = 82
    @State private var textOpacity: Double = 1.0
    @State private var ringVisible: Bool = false
    @State private var displayedTitle: String = "INSTALL"
    @State private var morphTask: Task<Void, Never>?

    private var targetIsCircular: Bool {
        switch state {
        case .awaitingConfirmation, .downloading:
            return true
        default:
            return false
        }
    }

    private var isDownloading: Bool {
        if case .downloading = state { return true }
        return false
    }

    private var downloadProgress: Double {
        if case .downloading(let progress) = state { return progress }
        return 0.0
    }

    private var stateTitle: String {
        switch state {
        case .notInstalled:
            return "INSTALL"
        case .updateAvailable:
            return "UPDATE"
        case .installed:
            return "OPEN"
        default:
            return displayedTitle
        }
    }

    var body: some View {
        Button(action: {
            if isDownloading {
                onCancel()
            } else if !targetIsCircular {
                onAction()
            }
        }) {
            ZStack(alignment: alignment) {
                // Fixed 82x30 layout footprint so row text never shifts
                Color.clear
                    .frame(width: pillWidth, height: height)

                // Morphing container: always 30pt tall, width animates 82pt <-> 30pt
                ZStack {
                    // Pill background (shrinks into a 30x30 circle before fading into the ring)
                    Capsule()
                        .fill(Color.gray.opacity(ringVisible ? 0.0 : 0.16))

                    // Pill label
                    Text(displayedTitle)
                        .font(.system(size: 13, weight: .bold))
                        .foregroundColor(.blue)
                        .opacity(textOpacity)
                        .scaleEffect(textOpacity > 0.5 ? 1.0 : 0.75)

                    // 30x30 Ring (matches 30pt pill height edge-to-edge using strokeBorder)
                    UnifiedAppStoreRing(
                        isSpinning: state == .awaitingConfirmation,
                        isDownloading: isDownloading,
                        progress: downloadProgress
                    )
                    .frame(width: height, height: height)
                    .opacity(ringVisible ? 1.0 : 0.0)
                    .scaleEffect(ringVisible ? 1.0 : 0.82)
                }
                .frame(width: currentWidth, height: height)
            }
            .frame(width: pillWidth, height: height, alignment: alignment)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onAppear {
            if !targetIsCircular {
                displayedTitle = stateTitle
            }
            syncImmediately(to: targetIsCircular)
        }
        .onChange(of: stateTitle) { newTitle in
            if !targetIsCircular {
                withAnimation(.easeInOut(duration: 0.15)) {
                    displayedTitle = newTitle
                }
            }
        }
        .onChange(of: targetIsCircular) { isCirc in
            runStagedMorph(toCircular: isCirc)
        }
    }

    private func syncImmediately(to isCircular: Bool) {
        morphTask?.cancel()
        if isCircular {
            currentWidth = height
            textOpacity = 0.0
            ringVisible = true
        } else {
            currentWidth = pillWidth
            textOpacity = 1.0
            ringVisible = false
        }
    }

    private func runStagedMorph(toCircular: Bool) {
        morphTask?.cancel()
        morphTask = Task { @MainActor in
            if toCircular {
                // Stage 1: Fade out text quickly while shrinking button lengthwise (82pt -> 30pt circle)
                withAnimation(.easeOut(duration: 0.14)) {
                    textOpacity = 0.0
                }
                withAnimation(.spring(response: 0.38, dampingFraction: 0.84)) {
                    currentWidth = height
                }
                try? await Task.sleep(nanoseconds: 240_000_000)
                guard !Task.isCancelled else { return }

                // Stage 2: Crossfade the 30x30 circle into the spinning ring
                withAnimation(.easeInOut(duration: 0.2)) {
                    ringVisible = true
                }
            } else {
                displayedTitle = stateTitle

                // Stage 1: Crossfade the ring into a 30x30 solid capsule circle
                withAnimation(.easeInOut(duration: 0.18)) {
                    ringVisible = false
                }
                try? await Task.sleep(nanoseconds: 150_000_000)
                guard !Task.isCancelled else { return }

                // Stage 2: Stretch the 30x30 circle lengthwise into the 82x30 pill button
                withAnimation(.spring(response: 0.40, dampingFraction: 0.82)) {
                    currentWidth = pillWidth
                }
                try? await Task.sleep(nanoseconds: 160_000_000)
                guard !Task.isCancelled else { return }

                // Stage 3: Fade in the new button label ("OPEN" / "INSTALL" / "UPDATE")
                withAnimation(.easeOut(duration: 0.18)) {
                    textOpacity = 1.0
                }
            }
        }
    }
}

// Hardware-clocked 60/120fps ring that never stutters during state transitions
private struct UnifiedAppStoreRing: View {
    let isSpinning: Bool
    let isDownloading: Bool
    let progress: Double

    private let strokeWidth: CGFloat = 2.6

    var body: some View {
        ZStack {
            // Subtle full-circle track so the 30x30 outer height is always visually consistent
            Circle()
                .strokeBorder(Color.gray.opacity(isDownloading ? 0.24 : 0.14), lineWidth: strokeWidth)

            // Spinning Grey Arc (only visible while awaiting confirmation / deleting)
            TimelineView(.animation(minimumInterval: 1.0 / 60.0, paused: !isSpinning)) { context in
                let angle = (context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 0.8) / 0.8) * 360.0
                Circle()
                    .trim(from: 0.0, to: 0.72)
                    .stroke(
                        Color.gray.opacity(0.65),
                        style: StrokeStyle(lineWidth: strokeWidth, lineCap: .round)
                    )
                    .padding(strokeWidth / 2)
                    .rotationEffect(.degrees(angle))
            }
            .opacity(isDownloading ? 0.0 : 1.0)
            .animation(.easeInOut(duration: 0.2), value: isDownloading)

            // Blue Progress Arc + Stop Square (fades in smoothly at the exact same 30x30 bounds)
            Circle()
                .trim(from: 0.0, to: isDownloading ? CGFloat(max(0.05, progress)) : 0.0)
                .stroke(
                    Color.blue,
                    style: StrokeStyle(lineWidth: strokeWidth, lineCap: .round)
                )
                .padding(strokeWidth / 2)
                .rotationEffect(.degrees(-90))
                .opacity(isDownloading ? 1.0 : 0.0)
                .animation(.linear(duration: 0.22), value: progress)
                .animation(.easeInOut(duration: 0.22), value: isDownloading)

            RoundedRectangle(cornerRadius: 2)
                .fill(Color.blue)
                .frame(width: 9, height: 9)
                .scaleEffect(isDownloading ? 1.0 : 0.4)
                .opacity(isDownloading ? 1.0 : 0.0)
                .animation(.spring(response: 0.28, dampingFraction: 0.8), value: isDownloading)
        }
    }
}