//
//  VA_Beach_Snow_Plow_JobsApp.swift
//  VA Beach Snow Plow Jobs
//
//  Created by Ronald Thayer Jr on 5/18/26.
//

import SwiftUI
import SwiftData

@main
struct VA_Beach_Snow_Plow_JobsApp: App {
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
