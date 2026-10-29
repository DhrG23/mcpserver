//
//  CoreTheme.swift
//  Node
//
//  Core/UI/CoreTheme.swift
//  Glass look + layout constants shared by the Core screen.
//

import SwiftUI

enum CoreLayout {
    /// Content never grows wider than this, so tiles don't stretch on a big Mac window.
    static let maxContentWidth: CGFloat = 860
    static let tileHeight: CGFloat = 156
    static let spacing: CGFloat = 14
    static let cornerRadius: CGFloat = 20

    /// Adaptive: the grid fits as many 150–220pt columns as the width allows.
    /// iPhone ≈ 2 columns, small Mac window ≈ 3, wide Mac window ≈ 5.
    static let columns = [
        GridItem(.adaptive(minimum: 150, maximum: 220), spacing: spacing, alignment: .top)
    ]
}

extension View {
    func glassTile(cornerRadius: CGFloat = CoreLayout.cornerRadius) -> some View {
        self
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(.ultraThinMaterial)
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(
                        LinearGradient(
                            colors: [Color.white.opacity(0.45), Color.white.opacity(0.08)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 1
                    )
            )
            .shadow(color: Color.black.opacity(0.10), radius: 10, y: 4)
    }
}
