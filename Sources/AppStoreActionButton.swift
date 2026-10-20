import SwiftUI

struct AppStoreActionButton: View {
    let state: InstallState
    var alignment: Alignment = .center
    var onAction: () -> Void
    var onCancel: () -> Void

    private let buttonWidth: CGFloat = 76
    private let uniformHeight: CGFloat = 28

    private var isCircular: Bool {
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

    private var buttonTitle: String {
        switch state {
        case .notInstalled:
            return "INSTALL"
        case .updateAvailable:
            return "UPDATE"
        case .installed:
            return "OPEN"
        default:
            return ""
        }
    }

    var body: some View {
        Button(action: {
            if isDownloading {
                onCancel()
            } else if !isCircular {
                onAction()
            }
        }) {
            ZStack(alignment: alignment) {
                // Fixed outer footprint so surrounding layout never shifts
                Color.clear
                    .frame(width: buttonWidth, height: uniformHeight)

                // Morphing container: always 28pt tall, width animates between 76pt and 28pt
                ZStack {
                    // Pill background
                    Capsule()
                        .fill(Color.gray.opacity(isCircular ? 0.0 : 0.16))

                    // Pill text
                    Text(buttonTitle)
                        .font(.system(size: 13, weight: .bold))
                        .foregroundColor(.blue)
                        .scaleEffect(isCircular ? 0.5 : 1.0)
                        .opacity(isCircular ? 0.0 : 1.0)

                    // Single unified 28x28 ring for both loading spinner and blue progress bar
                    UnifiedAppStoreRing(
                        isSpinning: state == .awaitingConfirmation,
                        isDownloading: isDownloading,
                        progress: downloadProgress
                    )
                    .frame(width: uniformHeight, height: uniformHeight)
                    .scaleEffect(isCircular ? 1.0 : 0.5)
                    .opacity(isCircular ? 1.0 : 0.0)
                }
                .frame(width: isCircular ? uniformHeight : buttonWidth, height: uniformHeight)
            }
            .frame(width: buttonWidth, height: uniformHeight, alignment: alignment)
            .contentShape(Rectangle())
            .animation(.spring(response: 0.3, dampingFraction: 0.84), value: state)
        }
        .buttonStyle(.plain)
    }
}

private struct UnifiedAppStoreRing: View {
    let isSpinning: Bool
    let isDownloading: Bool
    let progress: Double

    @State private var rotationDegrees: Double = 0

    var body: some View {
        ZStack {
            // Grey Ring: 0.75 trimmed spinning arc when waiting -> morphs into 1.0 full track when downloading
            Circle()
                .inset(by: 1.25)
                .trim(from: 0.0, to: isDownloading ? 1.0 : 0.75)
                .stroke(
                    Color.gray.opacity(isDownloading ? 0.25 : 0.55),
                    style: StrokeStyle(lineWidth: 2.5, lineCap: .round)
                )
                .rotationEffect(.degrees(isDownloading ? -90 : rotationDegrees))
                .animation(.easeInOut(duration: 0.25), value: isDownloading)

            // Blue Progress Arc + Stop Square (same exact 28x28 inset circle)
            Circle()
                .inset(by: 1.25)
                .trim(from: 0.0, to: isDownloading ? CGFloat(max(0.05, progress)) : 0.0)
                .stroke(
                    Color.blue,
                    style: StrokeStyle(lineWidth: 2.5, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
                .opacity(isDownloading ? 1.0 : 0.0)
                .animation(.linear(duration: 0.2), value: progress)
                .animation(.easeInOut(duration: 0.2), value: isDownloading)

            RoundedRectangle(cornerRadius: 2)
                .fill(Color.blue)
                .frame(width: 8.5, height: 8.5)
                .scaleEffect(isDownloading ? 1.0 : 0.4)
                .opacity(isDownloading ? 1.0 : 0.0)
                .animation(.spring(response: 0.25, dampingFraction: 0.8), value: isDownloading)
        }
        .onAppear {
            startRotation()
        }
        .onChange(of: isSpinning) { spinning in
            if spinning {
                startRotation()
            }
        }
    }

    private func startRotation() {
        rotationDegrees = 0
        withAnimation(.linear(duration: 0.8).repeatForever(autoreverses: false)) {
            rotationDegrees = 360
        }
    }
}