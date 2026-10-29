//
//  NodeApp.swift
//  MyApp
//
//  Created by Veerjyot Singh on 27/09/26.
//

//Iska kaam hai sirf AppState object ko banana aur Main View ko render karna

import SwiftUI

@main
struct NodeApp: App {

    @StateObject private var appState = AppState()

    var body: some Scene {
        WindowGroup {
            MainView()
                .environmentObject(appState)
                #if os(macOS)
                .frame(minWidth: 520, minHeight: 640)
                #endif
        }
        #if os(macOS)
        .windowResizability(.contentMinSize)
        #endif
    }
}


