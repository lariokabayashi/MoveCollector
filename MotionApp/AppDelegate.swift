//
//  AppDelegate.swift
//  MotionApp
//
//  Created by Larissa Okabayashi on 15/10/25.
//

import UIKit
import BackgroundTasks

class AppDelegate: NSObject, UIApplicationDelegate {
    private let appConstants = AppConstants()
    
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {

        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: appConstants.backgroundTaskIdentifier,
            using: nil
        ) { task in
            // Handle the background task
            if let processingTask = task as? BGProcessingTask {
               
            }
        }
        scheduleBackgroundCollection()
        
        return true
    }
    
    func scheduleBackgroundCollection() {
        let request = BGProcessingTaskRequest(identifier: appConstants.backgroundTaskIdentifier)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 1 * 60)
        do {
            try BGTaskScheduler.shared.submit(request)
            print("background process scheduled")
        } catch {
            print("Couldn't schedule app process \(error.localizedDescription)")
        }
    }
    
    func cancelAllBackgroundTasks() {
        BGTaskScheduler.shared.cancelAllTaskRequests()
    }
    
}
