//
//  LockView.swift
//  Node
//
//  Created by Veerjyot Singh on 28/09/26.
//

import SwiftUI

struct LockView: View {

    @EnvironmentObject private var appState: AppState
    @Environment(\.colorScheme) private var colorScheme

    @State private var pin = ""
    @State private var message: String?
    @FocusState private var focused: Bool

    private let biometric = BiometricAuth.availableKind

    private var isDark: Bool { colorScheme == .dark }

    // MARK: - Body

    var body: some View {
        ZStack {
            background
            card.padding()
        }
        // Cross-platform: Color(.systemBackground) exists only on iOS
        .background(isDark ? Color.black : Color.white)
        .task {
            focused = true
            if appState.biometricsEnabled { await tryBiometrics() }
        }
    }

    // MARK: - Background (same as LoginView)

    private var background: some View {
        ZStack {
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

    // MARK: - Glass card

    private var card: some View {
        VStack(spacing: 24) {
            header
            entry
            signOutButton
        }
        .padding(32)
        .frame(maxWidth: 420)
        .background {
            RoundedRectangle(cornerRadius: 32, style: .continuous)
                .fill(.ultraThinMaterial)

            RoundedRectangle(cornerRadius: 32, style: .continuous)
                .fill(Color.white.opacity(isDark ? 0.08 : 0.18))

            RoundedRectangle(cornerRadius: 32, style: .continuous)
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
        .shadow(color: .black.opacity(isDark ? 0.45 : 0.18), radius: 40, y: 20)
    }

    private var header: some View {
        VStack(spacing: 8) {
            Image(systemName: "lock.fill")
                .font(.system(size: 44))
                .foregroundStyle(.tint)

            Text("Node is locked")
                .font(.title.bold())

            Text("Enter your PIN to continue")
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - PIN entry + biometrics

    private var entry: some View {
        VStack(spacing: 14) {
            SecureField("PIN", text: $pin)
                .glassInput()
                .multilineTextAlignment(.center)
                .font(.title3)
                .focused($focused)
#if os(iOS)
                .keyboardType(.numberPad)
#endif
                .onChange(of: pin) { _, newValue in handle(newValue) }

            if let message {
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
            }

            if appState.biometricsEnabled && biometric != .none {
                biometricButton
            }
        }
    }

    private var biometricButton: some View {
        Button {
            Task { await tryBiometrics() }
        } label: {
            Label("Unlock with \(biometric.name)", systemImage: biometric.icon)
                .font(.headline)
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity)
                .frame(height: 52)
                .background {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(.clear)
                        .overlay {
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .stroke(.primary.opacity(0.25), lineWidth: 1)
                        }
                }
                .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private var signOutButton: some View {
        Button("Sign out", role: .destructive) { appState.signOut() }
            .buttonStyle(.plain)
            .font(.callout)
            .foregroundStyle(.secondary)
    }

    // MARK: - Logic (unchanged)

    private func handle(_ value: String) {
        let digits = PINManager.sanitize(value)
        if digits != value { pin = digits; return }
        guard digits.count == PINManager.pinLength else { return }

        switch PINManager.shared.verify(digits) {
        case .success:
            appState.unlock()
        case .wrong(let left):
            message = "Incorrect PIN. \(left) attempt\(left == 1 ? "" : "s") left."
            pin = ""
        case .lockedOut:
            appState.signOut()      // too many failures: full sign-in required
        }
    }

    @MainActor
    private func tryBiometrics() async {
        if await BiometricAuth.authenticate(reason: "Unlock Node") {
            appState.unlock()
        }
    }
}

#Preview {
    LockView()
        .environmentObject(AppState())
}
