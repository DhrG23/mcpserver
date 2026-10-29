//
//  AccountView.swift
//  Node
//
//  Created by Veerjyot Singh on 28/09/26.
//


//
//  AccountView.swift
//  Node
//
//  Features/Account/AccountView.swift
//

import SwiftUI

struct AccountView: View {

    @EnvironmentObject private var appState: AppState

    @State private var showChangePIN = false
    @State private var showSignOutConfirm = false
    @State private var biometricError: String?

    private let biometric = BiometricAuth.availableKind

    // MARK: - Body

    var body: some View {
        NavigationStack {
            ZStack {
                GlassBackground()

                ScrollView {
                    VStack(spacing: 22) {
                        profileCard
                        securitySection
                        dataSharingSection
                        serverSection
                        signOutButton
                        footer
                    }
                    .frame(maxWidth: 480)
                    .padding()
                    .frame(maxWidth: .infinity)
                }
            }
            .navigationTitle("Account")
#if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
#endif
        }
        .sheet(isPresented: $showChangePIN) {
            ChangePINView()
                .environmentObject(appState)
        }
        .confirmationDialog("Sign out of Node?",
                            isPresented: $showSignOutConfirm,
                            titleVisibility: .visible) {
            Button("Sign out", role: .destructive) { signOut() }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("You'll need to sign in again, and your PIN will be removed from this device.")
        }
    }

    // MARK: - Profile

    private var profileCard: some View {
        VStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [.blue, .purple],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 84, height: 84)
                    .shadow(color: .purple.opacity(0.35), radius: 16, y: 8)

                Text(initial)
                    .font(.system(size: 36, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
            }

            Text(displayName)
                .font(.title2.bold())

            Label("Signed in", systemImage: "checkmark.seal.fill")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(28)
        .glassPanel(cornerRadius: 32)
    }

    private var displayName: String {
        appState.currentUserName.isEmpty ? "Node user" : appState.currentUserName
    }

    private var initial: String {
        let first = appState.currentUserName.prefix(1).uppercased()
        return first.isEmpty ? "N" : first
    }

    // MARK: - Security

    private var securitySection: some View {
        section("Security") {
            if biometric != .none {
                AccountRow(
                    icon: biometric.icon,
                    title: "Unlock with \(biometric.name)",
                    subtitle: "Skip typing your PIN"
                ) {
                    Toggle("", isOn: biometricBinding)
                        .labelsHidden()
                        .toggleStyle(.switch)
                }
                rowDivider
            }

            Button { showChangePIN = true } label: {
                AccountRow(icon: "key.fill", title: "Change PIN") {
                    chevron
                }
            }
            .buttonStyle(.plain)

            rowDivider

            Button { appState.lock() } label: {
                AccountRow(icon: "lock.fill",
                           title: "Lock Node now",
                           subtitle: "Ask for your PIN right away") {
                    chevron
                }
            }
            .buttonStyle(.plain)
        } footer: {
            if let biometricError {
                Text(biometricError)
                    .font(.footnote)
                    .foregroundStyle(.orange)
            }
        }
    }

    /// The toggle only turns on after the user proves biometrics work right now.
    private var biometricBinding: Binding<Bool> {
        Binding(
            get: { appState.biometricsEnabled },
            set: { newValue in Task { await updateBiometrics(newValue) } }
        )
    }

    @MainActor
    private func updateBiometrics(_ enable: Bool) async {
        biometricError = nil
        if enable {
            let ok = await BiometricAuth.authenticate(reason: "Turn on \(biometric.name) for Node")
            if ok {
                appState.setBiometricsEnabled(true)
            } else {
                biometricError = "\(biometric.name) wasn't confirmed, so it's still off."
            }
        } else {
            appState.setBiometricsEnabled(false)
        }
    }

    // MARK: - Data sharing

    /// The only way to reach the permission switches (Photos, Contacts, Calendar, ...).
    private var dataSharingSection: some View {
        section("Data sharing") {
            NavigationLink {
                DataSharingView()
            } label: {
                AccountRow(
                    icon: "hand.raised.fill",
                    title: "Data sharing",
                    subtitle: "Choose what Node reads and sends"
                ) {
                    chevron
                }
            }
            .buttonStyle(.plain)
        } footer: { }
    }

    // MARK: - Server

    private var serverSection: some View {
        section("Server") {
            AccountRow(
                icon: "server.rack",
                title: "Server address",
                subtitle: ServerConfig.savedURL.isEmpty ? "Not set" : ServerConfig.savedURL
            ) { }
        } footer: { }
    }

    // MARK: - Sign out

    private var signOutButton: some View {
        Button { showSignOutConfirm = true } label: {
            Text("Sign out")
                .font(.headline)
                .foregroundStyle(.red)
                .frame(maxWidth: .infinity)
                .frame(height: 52)
                .background {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(Color.red.opacity(0.08))
                        .overlay {
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .stroke(Color.red.opacity(0.35), lineWidth: 1)
                        }
                }
                .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private var footer: some View {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return Text("Node \(version) (\(build))")
            .font(.footnote)
            .foregroundStyle(.secondary)
            .padding(.top, 4)
    }

    /// Signs out on this device immediately, then tells the server to invalidate
    /// the session in the background (best effort; it expires on its own anyway).
    private func signOut() {
        let base = ServerConfig.normalizedURL(ServerConfig.savedURL)
        let token = KeychainManager.shared.loadString(KeychainKey.accessToken)
        appState.signOut()
        if let base, let token {
            Task { await Self.revokeServerSession(base: base, token: token) }
        }
    }

    private static func revokeServerSession(base: URL, token: String) async {
        var request = URLRequest(url: base.appendingPathComponent("auth/logout"))
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 5
        _ = try? await ServerTrust.session.data(for: request)
    }

    // MARK: - Building blocks

    private var chevron: some View {
        Image(systemName: "chevron.right")
            .font(.footnote.weight(.semibold))
            .foregroundStyle(.tertiary)
    }

    private var rowDivider: some View {
        Divider()
            .opacity(0.4)
            .padding(.leading, 58)
    }

    private func section<Content: View, Footer: View>(
        _ title: String,
        @ViewBuilder content: () -> Content,
        @ViewBuilder footer: () -> Footer
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased())
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.leading, 8)

            VStack(spacing: 0) { content() }
                .glassPanel(cornerRadius: 24, shadowed: false)

            footer()
                .padding(.leading, 8)
        }
    }
}

// MARK: - Row

private struct AccountRow<Trailing: View>: View {

    let icon: String
    let title: String
    var subtitle: String? = nil
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: icon)
                .font(.body.weight(.semibold))
                .foregroundStyle(.tint)
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                if let subtitle {
                    Text(subtitle)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .truncationMode(.middle)
                }
            }

            Spacer(minLength: 8)
            trailing()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(minHeight: 52)
        .contentShape(Rectangle())
    }
}

#Preview {
    let state = AppState()
    state.currentUserName = "Veerjyot Singh"
    return AccountView()
        .environmentObject(state)
}
