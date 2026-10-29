//
//  PINSetupView.swift
//  Node
//
//  Created by Veerjyot Singh on 28/09/26.
//

import SwiftUI

struct PINSetupView: View {

    @EnvironmentObject private var appState: AppState
    @Environment(\.colorScheme) private var colorScheme

    @State private var pin = ""
    @State private var firstPIN = ""
    @State private var stage: Stage = .create
    @State private var message: String?
    @State private var useBiometrics = true
    @FocusState private var focused: Bool

    enum Stage { case create, confirm }

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
        .onAppear { focused = true }
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
            Image(systemName: "lock.shield.fill")
                .font(.system(size: 44))
                .foregroundStyle(.tint)

            Text(stage == .create ? "Create a PIN" : "Confirm your PIN")
                .font(.title.bold())

            Text("\(PINManager.pinLength) digits. You'll use it to unlock Node.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            stepIndicator
                .padding(.top, 4)
        }
    }

    /// Two small bars showing step 1 of 2 / step 2 of 2.
    private var stepIndicator: some View {
        HStack(spacing: 8) {
            ForEach(0..<2, id: \.self) { index in
                let reached = index <= (stage == .create ? 0 : 1)
                Capsule()
                    .fill(reached ? Color.accentColor : Color.primary.opacity(0.2))
                    .frame(width: 28, height: 4)
            }
        }
        .animation(.easeInOut(duration: 0.25), value: stage)
    }

    // MARK: - PIN entry

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

            if biometric != .none {
                biometricRow
            }
        }
    }

    private var biometricRow: some View {
        HStack(spacing: 12) {
            Image(systemName: biometric.icon)
                .font(.title3)
                .foregroundStyle(.tint)

            Text("Unlock with \(biometric.name)")
                .font(.callout)

            Spacer(minLength: 8)

            Toggle("", isOn: $useBiometrics)
                .labelsHidden()
                .toggleStyle(.switch)
        }
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

    // MARK: - Logic (unchanged)

    private func handle(_ value: String) {
        let digits = PINManager.sanitize(value)
        if digits != value { pin = digits; return }
        guard digits.count == PINManager.pinLength else { return }

        switch stage {
        case .create:
            if PINManager.isWeak(digits) {
                message = "That PIN is too easy to guess. Try another."
                pin = ""
                return
            }
            message = nil
            firstPIN = digits
            pin = ""
            stage = .confirm

        case .confirm:
            guard digits == firstPIN else {
                message = "PINs didn't match. Start again."
                firstPIN = ""
                pin = ""
                stage = .create
                return
            }
            do {
                try PINManager.shared.setPIN(digits)
                appState.setBiometricsEnabled(useBiometrics && biometric != .none)
                appState.needsPINSetup = false
            } catch {
                message = "Couldn't save your PIN. Please try again."
                pin = ""
            }
        }
    }
}

#Preview {
    PINSetupView()
        .environmentObject(AppState())
}
