//
//  GlassBackground.swift
//  Node
//
//  Created by Veerjyot Singh on 28/09/26.
//


//
//  GlassTheme.swift
//  Node
//
//  Shared/GlassTheme.swift
//  Reusable pieces of the frosted-glass look used across Node.
//
//  Used by the login, PIN, lock, account and Core screens.
//

import SwiftUI

// MARK: - Background

/// Gradient with two soft glows. Fill the whole screen with it behind your content.
struct GlassBackground: View {

    @Environment(\.colorScheme) private var colorScheme
    private var isDark: Bool { colorScheme == .dark }

    var body: some View {
        ZStack {
            // Cross-platform base (Color(.systemBackground) exists only on iOS)
            isDark ? Color.black : Color.white

            LinearGradient(
                colors: isDark
                    ? [Color.indigo.opacity(0.55), Color.purple.opacity(0.45), Color.blue.opacity(0.30)]
                    : [Color.blue.opacity(0.35), Color.purple.opacity(0.25), Color.cyan.opacity(0.20)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            Circle()
                .fill(Color.blue.opacity(isDark ? 0.30 : 0.25))
                .frame(width: 300)
                .blur(radius: 90)
                .offset(x: -150, y: -220)

            Circle()
                .fill(Color.purple.opacity(isDark ? 0.30 : 0.25))
                .frame(width: 300)
                .blur(radius: 90)
                .offset(x: 160, y: 200)
        }
        .ignoresSafeArea()
    }
}

// MARK: - Panel (cards and grouped sections)

struct GlassPanel: ViewModifier {

    @Environment(\.colorScheme) private var colorScheme
    var cornerRadius: CGFloat
    var shadowed: Bool

    func body(content: Content) -> some View {
        let isDark = colorScheme == .dark
        content
            .background {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(.ultraThinMaterial)

                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(Color.white.opacity(isDark ? 0.08 : 0.18))

                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(
                        LinearGradient(
                            colors: isDark
                                ? [.white.opacity(0.35), .white.opacity(0.08), .white.opacity(0.20)]
                                : [.white.opacity(0.65), .white.opacity(0.15), .white.opacity(0.35)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 1
                    )
            }
            .shadow(
                color: .black.opacity(shadowed ? (isDark ? 0.45 : 0.18) : 0),
                radius: shadowed ? 40 : 0,
                y: shadowed ? 20 : 0
            )
    }
}

extension View {

    /// Frosted-glass container. Use a large radius + shadow for a main card,
    /// or a smaller radius with `shadowed: false` for grouped rows.
    func glassPanel(cornerRadius: CGFloat = 32, shadowed: Bool = true) -> some View {
        modifier(GlassPanel(cornerRadius: cornerRadius, shadowed: shadowed))
    }

    /// Glass text-field look. `.textFieldStyle(.plain)` removes the default macOS
    /// bezel, which would otherwise draw a second border inside the glass.
    func glassInput() -> some View {
        self
            .textFieldStyle(.plain)
            .padding(.horizontal, 16)
            .frame(height: 52)
            .background {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(.ultraThinMaterial)
                    .overlay {
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .fill(.white.opacity(0.06))
                    }
                    .overlay {
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .stroke(.white.opacity(0.18), lineWidth: 1)
                    }
            }
    }
}