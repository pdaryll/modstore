import SwiftUI

struct AppStoreActionButton: View {
    let state: InstallState
    var onAction: () -> Void
    var onCancel: () -> Void

    var body: some View {
        Button(action: {
            if case .downloading = state {
                onCancel()
            } else {
                onAction()
            }
        }) {
            switch state {
            case .notInstalled:
                capsuleButton(title: "INSTALL", isPrimary: true)
            case .updateAvailable:
                capsuleButton(title: "UPDATE", isPrimary: true)
            case .installed:
                capsuleButton(title: "OPEN", isPrimary: false)
            case .awaitingConfirmation:
                ProgressView()
                    .progressViewStyle(CircularProgressViewStyle())
                    .frame(width: 30, height: 30)
            case .downloading(let progress):
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
                        .frame(width: 9, height: 9)
                }
                .frame(width: 28, height: 28)
            }
        }
        .buttonStyle(.plain)
    }

    private func capsuleButton(title: String, isPrimary: Bool) -> some View {
        Text(title)
            .font(.system(size: 13, weight: .bold))
            .foregroundColor(isPrimary ? .blue : .secondary)
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
            .background(Color.gray.opacity(0.16))
            .clipShape(Capsule())
    }
}