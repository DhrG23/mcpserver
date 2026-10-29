//
//  MainView.swift
//  Node
//
//  Created by Veerjyot Singh on 27/09/26.
//

// Root view. Decides what to show:
//   0) PermissionsOnboardingView — first launch only (until completed or skipped)
//   1) LoginView                 — not signed in to the server
//   2) LockView                  — signed in but locked (PIN / Face ID / Touch ID)
//   3) PINSetupView              — signed in, no PIN chosen yet
//   4) TabView                   — Chat · Devices · Core · Account

import SwiftUI

struct MainView: View {

    @EnvironmentObject private var appState: AppState
    @Environment(\.scenePhase) private var scenePhase

    /// Set to true once the first-launch permissions slideshow has been completed or skipped.
    @AppStorage("onboarding.permissionsDone") private var onboardingDone = false

    var body: some View {
        // One container, so the modifiers below apply to whatever is currently shown.
        Group {
            if !onboardingDone {
                PermissionsOnboardingView { onboardingDone = true }
            } else {
                authGate
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { appState.lock() }
        }
        #if os(iOS)
        // The app-switcher snapshot is taken as the app goes inactive, before .background,
        // so cover the content as soon as it stops being active.
        .overlay {
            if appState.isAuthenticated && !appState.isLocked && scenePhase != .active {
                PrivacyCover()
            }
        }
        #endif // os(iOS)
    }

    // MARK: - Auth gate

    /// Login → lock → PIN setup → tabs. Without a token the Chat tab would only show "You're not signed in",
    /// so the tabs are reachable only through this gate.
    @ViewBuilder
    private var authGate: some View {
        if !appState.isAuthenticated {
            LoginView()
        } else if appState.isLocked {
            LockView()
        } else if appState.needsPINSetup {
            PINSetupView()
        } else {
            tabs
        }
    }

    // MARK: - Tabs

    private var tabs: some View {
        TabView(selection: $appState.selectedTab) {
            ChatView()
                .tabItem { tabLabel(for: .chat) }
                .tag(AppState.Tab.chat)

            DevicesView()
                .tabItem { tabLabel(for: .devices) }
                .tag(AppState.Tab.devices)

            CoreView()
                .tabItem { tabLabel(for: .core) }
                .tag(AppState.Tab.core)

            AccountView()
                .tabItem { tabLabel(for: .account) }
                .tag(AppState.Tab.account)
        }
    }

    private func tabLabel(for tab: AppState.Tab) -> some View {
        Label(tab.title, systemImage: tab.icon)
    }
}

/// Opaque cover shown while the app is inactive so nothing sensitive appears in the app switcher.
private struct PrivacyCover: View {
    var body: some View {
        ZStack {
            GlassBackground()
            Image(systemName: "lock.fill")
                .font(.system(size: 44))
                .foregroundStyle(.secondary)
        }
        .transition(.identity)
    }
}

// MARK: - Previews
// Adding AppState manually, as NodeApp is not run for previews. The onboarding flag is set so the
// previews show the screens they are named after instead of the first-launch slideshow.

#Preview("Logged Out") {
    UserDefaults.standard.set(true, forKey: "onboarding.permissionsDone")
    return MainView().environmentObject(AppState())
}

#Preview("Logged In") {
    UserDefaults.standard.set(true, forKey: "onboarding.permissionsDone")
    let state = AppState()
    state.isAuthenticated = true
    state.isLocked = false
    state.needsPINSetup = false
    state.currentUserName = "Preview User"
    return MainView()
        .environmentObject(state)
}
