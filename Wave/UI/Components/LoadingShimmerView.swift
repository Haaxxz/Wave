import SwiftUI

// MARK: - Loading shimmer

/// Placeholder rows shown while a list loads: grey rounded shapes that
/// gently pulse. `rows` controls how many placeholder rows are drawn.
struct LoadingShimmerView: View {
    var rows: Int = 8

    @State private var opacity: Double = 0.45

    var body: some View {
        VStack(spacing: 16) {
            ForEach(0..<rows, id: \.self) { _ in
                HStack(spacing: 12) {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color(.secondarySystemBackground))
                        .frame(width: 48, height: 48)
                    VStack(alignment: .leading, spacing: 7) {
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Color(.secondarySystemBackground))
                            .frame(width: 190, height: 12)
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Color(.secondarySystemBackground))
                            .frame(width: 130, height: 10)
                    }
                    Spacer()
                }
            }
        }
        .padding(.horizontal)
        .opacity(opacity)
        .onAppear {
            withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) {
                opacity = 1.0
            }
        }
    }
}

/// Placeholder cards shown while a horizontal section row loads.
struct LoadingCardRowView: View {
    var cards: Int = 4

    @State private var opacity: Double = 0.45

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 14) {
                ForEach(0..<cards, id: \.self) { _ in
                    VStack(alignment: .leading, spacing: 6) {
                        RoundedRectangle(cornerRadius: 10)
                            .fill(Color(.secondarySystemBackground))
                            .frame(width: 140, height: 140)
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Color(.secondarySystemBackground))
                            .frame(width: 110, height: 12)
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Color(.secondarySystemBackground))
                            .frame(width: 80, height: 10)
                    }
                }
            }
            .padding(.horizontal)
        }
        .opacity(opacity)
        .onAppear {
            withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) {
                opacity = 1.0
            }
        }
    }
}
