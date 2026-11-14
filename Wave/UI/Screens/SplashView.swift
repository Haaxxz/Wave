import SwiftUI

// MARK: - Splash

/// App launch splash: dark background, the Wave wordmark and animated teal
/// equaliser bars, centred. It is overlaid by `ContentView` for about a
/// second at launch and never navigates anywhere itself.
struct SplashView: View {
    @State private var animating = false

    private let barHeights: [CGFloat] = [0.45, 0.85, 1.0, 0.65, 0.35]
    private let barDurations: [Double] = [0.55, 0.75, 0.65, 0.8, 0.6]

    var body: some View {
        ZStack {
            Color(red: 0.03, green: 0.05, blue: 0.06)
                .ignoresSafeArea()

            VStack(spacing: 26) {
                Text("Wave")
                    .font(.system(size: 48, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)

                HStack(alignment: .bottom, spacing: 6) {
                    ForEach(0..<5, id: \.self) { index in
                        RoundedRectangle(cornerRadius: 3)
                            .fill(WaveColors.accent)
                            .frame(width: 7, height: 34 * (animating ? barHeights[index] : 0.25))
                            .animation(
                                .easeInOut(duration: barDurations[index])
                                    .repeatForever(autoreverses: true),
                                value: animating
                            )
                    }
                }
                .frame(height: 34)

                Text("Your music, your way")
                    .font(WaveFonts.body(14))
                    .foregroundStyle(.white.opacity(0.6))
            }
        }
        .onAppear { animating = true }
    }
}
