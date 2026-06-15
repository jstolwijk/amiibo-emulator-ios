//
//  Amiibo_EmulatorApp.swift
//  Amiibo Emulator
//
//  Created by Jesse Stolwijk on 15/06/2026.
//

import SwiftUI
import SwiftData

@main
struct Amiibo_EmulatorApp: App {
    var sharedModelContainer: ModelContainer = {
        let schema = Schema([
            Item.self,
        ])
        let modelConfiguration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)

        do {
            return try ModelContainer(for: schema, configurations: [modelConfiguration])
        } catch {
            fatalError("Could not create ModelContainer: \(error)")
        }
    }()

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .modelContainer(sharedModelContainer)
    }
}
