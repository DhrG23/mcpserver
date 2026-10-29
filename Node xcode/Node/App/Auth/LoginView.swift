//
//  LoginView.swift
//  Node
//
//  Features/Auth/LoginView.swift
//  Sign in to, or create an account on, your own Node server.
//

import SwiftUI

struct LoginView: View {

    @EnvironmentObject private var appState: AppState
    @Environment(\.colorScheme) private var colorScheme

    @State private var mode: Mode = .signIn
    @State private var serverURL = ServerConfig.savedURL
    @State private var email = ""
    @State private var password = ""
    @State private var confirmPassword = ""
    @State private var inviteCode = ""
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var pendingCertificate: PendingCertificate?
    @FocusState private var focusedField: Field?

    /// A certificate the system doesn't trust, waiting for the user's decision.
    struct PendingCertificate: Identifiable {
        let host: String
        let fingerprint: String
        var id: String { host + fingerprint }
    }

    enum Mode { case signIn, createAccount }
    enum Field { case server, email, password, confirm, invite }

    /// Set to true to develop the UI without a running server.
    private let useMockServer = false

    private let minPasswordLength = 10

    private var isDark: Bool { colorScheme == .dark }
    private var isCreating: Bool { mode == .createAccount }

    private var canSubmit: Bool {
        guard !isLoading, email.contains("@") else { return false }
        guard useMockServer || ServerConfig.normalizedURL(serverURL) != nil else { return false }
        switch mode {
        case .signIn:
            return !password.isEmpty
        case .createAccount:
            return password.count >= minPasswordLength
                && password == confirmPassword
                && !inviteCode.isEmpty
        }
    }

    // MARK: - Body

    var body: some View {
        ZStack {
            background

            // The card scrolls if the window is short (Create Account has more fields),
            // and stays vertically centred when there is enough room.
            GeometryReader { geo in
                ScrollView {
                    card
                        .padding()
                        .frame(maxWidth: .infinity, minHeight: geo.size.height)
                }
                .scrollBounceBehavior(.basedOnSize)
            }
        }
        // Cross-platform: Color(.systemBackground) exists only on iOS
        .background(isDark ? Color.black : Color.white)
        .onAppear { focusedField = serverURL.isEmpty ? .server : .email }
        .alert(
            "Trust this server?",
            isPresented: Binding(
                get: { pendingCertificate != nil },
                set: { if !$0 { pendingCertificate = nil } }
            ),
            presenting: pendingCertificate
        ) { cert in
            Button("Trust & Continue") {
                ServerTrust.pin(cert.fingerprint, for: cert.host)
                pendingCertificate = nil
                Task { await submit() }
            }
            Button("Cancel", role: .cancel) { pendingCertificate = nil }
        } message: { cert in
            Text("\(cert.host) isn't using a certificate your device recognises (normal for a self-signed server).\n\nSHA-256 fingerprint:\n\(cert.fingerprint)\n\nOnly continue if this matches the fingerprint of your own server's certificate.")
        }
    }

    // MARK: - Background

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
            form
            modeSwitch
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
            Image(systemName: "point.3.connected.trianglepath.dotted")
                .font(.system(size: 44))
                .foregroundStyle(.tint)
            Text(isCreating ? "Create your account" : "Welcome to Node")
                .font(.title.bold())
            Text(isCreating ? "Set up access to your server" : "Sign in to continue")
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Form

    private var form: some View {
        VStack(spacing: 14) {

            TextField("Server address (e.g. https://192.168.1.20:8443)", text: $serverURL)
                .glassInput()
                .autocorrectionDisabled()
#if os(iOS)
                .keyboardType(.URL)
                .textInputAutocapitalization(.never)
                .textContentType(.URL)
#endif
                .focused($focusedField, equals: .server)
                .onSubmit { focusedField = .email }

            TextField("Email", text: $email)
                .glassInput()
                .autocorrectionDisabled()
#if os(iOS)
                .keyboardType(.emailAddress)
                .textInputAutocapitalization(.never)
                .textContentType(.emailAddress)
#endif
                .focused($focusedField, equals: .email)
                .onSubmit { focusedField = .password }

            SecureField(isCreating ? "Password (\(minPasswordLength)+ characters)" : "Password",
                        text: $password)
                .glassInput()
#if os(iOS)
                .textContentType(isCreating ? .newPassword : .password)
#endif
                .focused($focusedField, equals: .password)
                .onSubmit { isCreating ? (focusedField = .confirm) : submitIfPossible() }

            if isCreating {
                SecureField("Confirm password", text: $confirmPassword)
                    .glassInput()
                    .focused($focusedField, equals: .confirm)
                    .onSubmit { focusedField = .invite }

                if !confirmPassword.isEmpty && confirmPassword != password {
                    hint("Passwords don't match.", color: .orange)
                }

                SecureField("Invite code", text: $inviteCode)
                    .glassInput()
                    .focused($focusedField, equals: .invite)
                    .onSubmit { submitIfPossible() }

                hint("The invite code is set by whoever runs the server.", color: .secondary)
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            submitButton
        }
    }

    private func hint(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.footnote)
            .foregroundStyle(color)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var submitButton: some View {
        Button {
            Task { await submit() }
        } label: {
            Group {
                if isLoading {
                    ProgressView()
                        .tint(.primary)
                        .controlSize(.small)
                } else {
                    Text(isCreating ? "Create Account" : "Sign In")
                        .font(.headline)
                }
            }
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
        .keyboardShortcut(.defaultAction)
        .disabled(!canSubmit)
        .opacity(canSubmit || isLoading ? 1 : 0.5)
    }

    private var modeSwitch: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.2)) {
                mode = isCreating ? .signIn : .createAccount
                errorMessage = nil
                confirmPassword = ""
                inviteCode = ""
            }
        } label: {
            Text(isCreating ? "Already have an account? Sign in" : "New here? Create an account")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Actions

    private func submitIfPossible() {
        if canSubmit { Task { await submit() } }
    }

    @MainActor
    private func submit() async {
        errorMessage = nil
        isLoading = true
        defer { isLoading = false }

        do {
            let cleanEmail = email.trimmingCharacters(in: .whitespaces)

            let service: AuthService
            var baseURL: URL?
            if useMockServer {
                service = MockAuthService()
            } else {
                guard let url = ServerConfig.normalizedURL(serverURL) else {
                    throw AuthError.invalidServerURL
                }
                service = RemoteAuthService(baseURL: url)
                baseURL = url
            }

            let session: AuthSession
            switch mode {
            case .signIn:
                session = try await service.signIn(email: cleanEmail, password: password)
            case .createAccount:
                session = try await service.register(email: cleanEmail,
                                                     password: password,
                                                     inviteCode: inviteCode)
            }

            if let baseURL { ServerConfig.save(baseURL) }
            try appState.completeSignIn(session)

            // Don't keep secrets in memory longer than needed
            password = ""
            confirmPassword = ""
            inviteCode = ""
        } catch AuthError.untrustedCertificate(let host, let fingerprint) {
            pendingCertificate = PendingCertificate(host: host, fingerprint: fingerprint)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

#Preview("Sign In") {
    LoginView()
        .environmentObject(AppState())
}
