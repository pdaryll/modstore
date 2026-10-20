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
            ZStack {
                switch state {
                case .notInstalled:
                    capsuleButton(title: "INSTALL")
                case .updateAvailable:
                    capsuleButton(title: "UPDATE")
                case .installed:
                    capsuleButton(title: "OPEN")
                case .awaitingConfirmation:
                    ProgressView()
                        .progressViewStyle(CircularProgressViewStyle())
                        .frame(width: 28, height: 28)
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
            // Locks outer slot width so row text never shifts when state changes
            .frame(width: 78, height: 30, alignment: .center)
        }
        .buttonStyle(.plain)
    }

    private func capsuleButton(title: String) -> some View {
        Text(title)
            .font(.system(size: 13, weight: .bold))
            .foregroundColor(.blue)
            .frame(width: 78, height: 30)
            .background(Color.gray.opacity(0.16))
            .clipShape(Capsule())
    }
}