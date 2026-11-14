import SwiftUI

// MARK: - Error state

/// A centred error state with a message and a retry button.
struct ErrorStateView: View {
    var message: String
    var onRetry: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 36))
                .foregroundStyle(WaveColors.secondaryLabel)
            Text(message)
                .font(WaveFonts.body())
                .foregroundStyle(WaveColors.secondaryLabel)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            Button(action: onRetry) {
                Text("Try again")
                    .font(WaveFonts.headline())
                    .padding(.horizontal, 22)
                    .padding(.vertical, 10)
                    .background(WaveColors.accent, in: Capsule())
                    .foregroundStyle(.white)
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 48)
    }
}
