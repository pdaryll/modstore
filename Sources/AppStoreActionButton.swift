import SwiftUI

struct AppStoreActionButton: View {
    let state: InstallState
    var alignment: Alignment = .center
    var onAction: () -> Void
    var onCancel: () -> Void

    private let pillWidth: CGFloat = 82
    private let height: CGFloat = 30
    // Balanced neutral shade shared by both the button background and the loading ring
    private let sharedNeutralColor = Color.primary.opacity(0.18)

    @State private var currentWidth: CGFloat = 82
    @State private var textOpacity: Double = 1.0
    @State private var ringVisible: Bool = false
    @State private var displayedTitle: String = "INSTALL"
    @State private var morphTask: Task<Void, Never>?

    private func isCircularState(_ s: InstallState) -> Bool {
        switch s {
        case .awaitingConfirmation, .downloading:
            return true
        default:
            return false
        }
    }

    private func titleForState(_ s: InstallState) -> String {
        switch s {
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

    private var isDownloading: Bool {
        if case .downloading = state { return true }
        return false
    }

    private var downloadProgress: Double {
        if case .downloading(let progress) = state { return progress }
        return 0.0
    }

    var body: some View {
        Button(action: {
            if isDownloading {
                onCancel()
            } else if !isCircularState(state) {
                onAction()
            }
        }) {
            ZStack(alignment: alignment) {
                Color.clear
                    .frame(width: pillWidth, height: height)

                ZStack {
                    Capsule()
                        .fill(sharedNeutralColor.opacity(ringVisible ? 0.0 : 1.0))

                    Text(displayedTitle)
                        .font(.system(size: 13, weight: .bold))
                        .foregroundColor(.blue)
                        .opacity(textOpacity)
                        .scaleEffect(textOpacity > 0.5 ? 1.0 : 0.75)

                    UnifiedAppStoreRing(
                        isSpinning: state == .awaitingConfirmation,
                        isDownloading: isDownloading,
                        progress: downloadProgress,
                        ringColor: sharedNeutralColor
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
            displayedTitle = titleForState(state)
            syncImmediately(to: isCircularState(state))
        }
        .onChange(of: state) { newState in
            let wasCircular = ringVisible || currentWidth < pillWidth
            let nowCircular = isCircularState(newState)

            if !nowCircular {
                displayedTitle = titleForState(newState)
            }

            if wasCircular != nowCircular {
                runStagedMorph(toCircular: nowCircular, targetTitle: titleForState(newState))
            }
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

    private func runStagedMorph(toCircular: Bool, targetTitle: String) {
        morphTask?.cancel()
        morphTask = Task { @MainActor in
            if toCircular {
                withAnimation(.easeOut(duration: 0.12)) {
                    textOpacity = 0.0
                }
                withAnimation(.spring(response: 0.34, dampingFraction: 0.84)) {
                    currentWidth = height
                }
                try? await Task.sleep(nanoseconds: 200_000_000)
                guard !Task.isCancelled else { return }

                withAnimation(.easeInOut(duration: 0.16)) {
                    ringVisible = true
                }
            } else {
                displayedTitle = targetTitle

                withAnimation(.easeInOut(duration: 0.14)) {
                    ringVisible = false
                }
                try? await Task.sleep(nanoseconds: 110_000_000)
                guard !Task.isCancelled else { return }

                withAnimation(.spring(response: 0.34, dampingFraction: 0.82)) {
                    currentWidth = pillWidth
                }
                try? await Task.sleep(nanoseconds: 120_000_000)
                guard !Task.isCancelled else { return }

                withAnimation(.easeOut(duration: 0.14)) {
                    textOpacity = 1.0
                }
            }
        }
    }
}

private struct UnifiedAppStoreRing: View {
    let isSpinning: Bool
    let isDownloading: Bool
    let progress: Double
    let ringColor: Color

    private let strokeWidth: CGFloat = 2.8

    var body: some View {
        ZStack {
            // Full circle track during active download (same neutral color as button)
            Circle()
                .strokeBorder(ringColor.opacity(isDownloading ? 1.0 : 0.35), lineWidth: strokeWidth)

            // Spinning arc while waiting for confirmation (exact same neutral color as button)
            TimelineView(.animation(minimumInterval: 1.0 / 60.0, paused: !isSpinning)) { context in
                let angle = (context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 0.75) / 0.75) * 360.0
                Circle()
                    .trim(from: 0.0, to: 0.72)
                    .stroke(
                        ringColor,
                        style: StrokeStyle(lineWidth: strokeWidth, lineCap: .round)
                    )
                    .padding(strokeWidth / 2)
                    .rotationEffect(.degrees(angle))
            }
            .opacity(isDownloading ? 0.0 : 1.0)
            .animation(.easeInOut(duration: 0.18), value: isDownloading)

            // Blue progress arc + stop square
            Circle()
                .trim(from: 0.0, to: isDownloading ? CGFloat(max(0.05, progress)) : 0.0)
                .stroke(
                    Color.blue,
                    style: StrokeStyle(lineWidth: strokeWidth, lineCap: .round)
                )
                .padding(strokeWidth / 2)
                .rotationEffect(.degrees(-90))
                .opacity(isDownloading ? 1.0 : 0.0)
                .animation(.linear(duration: 0.2), value: progress)
                .animation(.easeInOut(duration: 0.18), value: isDownloading)

            RoundedRectangle(cornerRadius: 2)
                .fill(Color.blue)
                .frame(width: 9, height: 9)
                .scaleEffect(isDownloading ? 1.0 : 0.4)
                .opacity(isDownloading ? 1.0 : 0.0)
                .animation(.spring(response: 0.25, dampingFraction: 0.8), value: isDownloading)
        }
    }
}