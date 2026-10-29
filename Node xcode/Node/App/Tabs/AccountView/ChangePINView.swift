//
//  ChangePINView.swift
//  Node
//
//  Created by Veerjyot Singh on 04/10/26.
//


//
//  ChangePINView.swift
//  Node
//
//  Created by Veerjyot Singh on 28/09/26.
//


//
//  ChangePINView.swift
//  Node
//
//  Features/Account/ChangePINView.swift
//  Presented as a sheet from the Account tab.
//  Flow: enter current PIN -> choose new PIN -> confirm new PIN.
//

import SwiftUI

struct ChangePINView: View {

    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var pin = ""
    @State private var newPIN = ""
    @State private var stage: Stage = .current
    @State private var message: String?
    @FocusState private var focused: Bool

    enum Stage: Int { case current = 0, new, confirm }

    // MARK: - Body

    var body: some View {
        ZStack {
            GlassBackground()
            card.padding()
        }
#if os(macOS)
        .frame(minWidth: 460, minHeight: 540)
#endif
        .onAppear { focused = true }
    }

    private var card: some View {
        VStack(spacing: 24) {
            header

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
            }

            Button("Cancel") { dismiss() }
                .buttonStyle(.plain)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .padding(32)
        .frame(maxWidth: 420)
        .glassPanel(cornerRadius: 32)
    }

    private var header: some View {
        VStack(spacing: 8) {
            Image(systemName: "key.fill")
                .font(.system(size: 44))
                .foregroundStyle(.tint)

            Text(title)
                .font(.title.bold())

            Text(subtitle)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            HStack(spacing: 8) {
                ForEach(0..<3, id: \.self) { index in
                    Capsule()
                        .fill(index <= stage.rawValue ? Color.accentColor : Color.primary.opacity(0.2))
                        .frame(width: 28, height: 4)
                }
            }
            .padding(.top, 4)
            .animation(.easeInOut(duration: 0.25), value: stage)
        }
    }

    private var title: String {
        switch stage {
        case .current: return "Enter current PIN"
        case .new:     return "Choose a new PIN"
        case .confirm: return "Confirm new PIN"
        }
    }

    private var subtitle: String {
        switch stage {
        case .current: return "We need to check it's you first."
        case .new:     return "\(PINManager.pinLength) digits."
        case .confirm: return "Enter the new PIN once more."
        }
    }

    // MARK: - Logic

    private func handle(_ value: String) {
        let digits = PINManager.sanitize(value)
        if digits != value { pin = digits; return }
        guard digits.count == PINManager.pinLength else { return }

        switch stage {

        case .current:
            switch PINManager.shared.verify(digits) {
            case .success:
                message = nil
                pin = ""
                stage = .new
            case .wrong(let left):
                message = "Incorrect PIN. \(left) attempt\(left == 1 ? "" : "s") left."
                pin = ""
            case .lockedOut:
                appState.signOut()      // too many failures: full sign-in required
                dismiss()
            }

        case .new:
            if PINManager.isWeak(digits) {
                message = "That PIN is too easy to guess. Try another."
                pin = ""
                return
            }
            message = nil
            newPIN = digits
            pin = ""
            stage = .confirm

        case .confirm:
            guard digits == newPIN else {
                message = "PINs didn't match. Choose your new PIN again."
                newPIN = ""
                pin = ""
                stage = .new
                return
            }
            do {
                try PINManager.shared.setPIN(digits)
                dismiss()
            } catch {
                message = "Couldn't save your PIN. Please try again."
                pin = ""
            }
        }
    }
}

#Preview {
    ChangePINView()
        .environmentObject(AppState())
}