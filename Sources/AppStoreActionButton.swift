import SwiftUI

struct AppStoreActionButton: View {
    let state: InstallState
    var alignment: Alignment = .center
    var onAction: () -> Void
    var onCancel: () -> Void

    private var isCircular: Bool {
        switch state {
        case .awaitingConfirmation, .downloading:
            return true
        default:
            return false
        }
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
            if case .downloading = state {
                onCancel()
            } else if !isCircular {
                onAction()
            }
        }) {
            ZStack(alignment: alignment) {
                // Invisible anchor so surrounding text never shifts
                Color.clear
                    .frame(width: 78, height: 30)

                // Morphing container that shrinks from 78x30 pill -> 28x28 circle
                ZStack {
                    // Pill Background (fades out as it shrinks into a circle)
                    Capsule()
                        .fill(Color.gray.opacity(isCircular ? 0.0 : 0.16))

                    // Pill Label (scales down & fades out when morphing to circle)
                    Text(buttonTitle)
                        .font(.system(size: 13, weight: .bold))
                        .foregroundColor(.blue)
                        .scaleEffect(isCircular ? 0.55 : 1.0)
                        .opacity(isCircular ? 0.0 : 1.0)

                    // Circular Ring States (fades in as pill shrinks to 28x28)
                    ZStack {
                        if case .awaitingConfirmation = state {
                            AppStoreSpinningRing()
                                .transition(.opacity)
                        } else if case .downloading(let progress) = state {
                            ZStack {
                                Circle()
                                    .stroke(Color.gray.opacity(0.25), lineWidth: 2.5)
                                Circle()
                                    .trim(from: 0, to: CGFloat(max(0.05, progress)))
                                    .stroke(Color.blue, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                                    .rotationEffect(.degrees(-90))
                                    .animation(.linear(duration: 0.2), value: progress)
                                RoundedRectangle(cornerRadius: 2)
                                    .fill(Color.blue)
                                    .frame(width: 8.5, height: 8.5)
                            }
                            .transition(.opacity)
                        }
                    }
                    .frame(width: 24, height: 24)
                    .scaleEffect(isCircular ? 1.0 : 0.55)
                    .opacity(isCircular ? 1.0 : 0.0)
                }
                .frame(width: isCircular ? 28 : 78, height: isCircular ? 28 : 30)
            }
            .frame(width: 78, height: 30, alignment: alignment)
            .contentShape(Rectangle())
            .animation(.spring(response: 0.32, dampingFraction: 0.82), value: state)
        }
        .buttonStyle(.plain)
    }
}

// Thin grey spinning circle ring matching Apple's App Store indeterminate loader
private struct AppStoreSpinningRing: View {
    @State private var isAnimating = false

    var body: some View {
        Circle()
            .trim(from: 0.0, to: 0.78)
            .stroke(
                Color.gray.opacity(0.55),
                style: StrokeStyle(lineWidth: 2.5, lineCap: .round)
            )
            .rotationEffect(.degrees(isAnimating ? 360 : 0))
            .onAppear {
                withAnimation(.linear(duration: 0.8).repeatForever(autoreverses: false)) {
                    isAnimating = true
                }
            }
    }
}