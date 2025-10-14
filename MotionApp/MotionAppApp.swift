//
//  MotionAppApp.swift
//  MotionApp
//
//  Created by Larissa Okabayashi on 07/10/25.
//

import SwiftUI

@main
struct MotionAppApp: App {
    let persistenceController = PersistenceController.shared

    var body: some Scene {
        
        WindowGroup {
            ContentView(context: persistenceController.container.viewContext)
                .environment(\.managedObjectContext, persistenceController.container.viewContext)
        }
    }
}
