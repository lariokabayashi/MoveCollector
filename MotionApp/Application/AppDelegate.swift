import UIKit
import BackgroundTasks
import CoreData
import SwiftUI

@available(iOS 26.0, *)
class AppDelegate: UIResponder, UIApplicationDelegate, ObservableObject {
    private let appConstants = AppConstants()
    private let locationManager = LocationManager()
    private let scheduler = BGTaskScheduler.shared
    private var submitted = false
    
    private var currentTask: BGContinuedProcessingTask?
    
    private var isUserStopped = false
    
    var persistentContainer = PersistenceController.shared.container
    lazy var sensorManager: SensorManagerViewModel = {
           let manager = SensorManagerViewModel(context: PersistenceController.shared.container.viewContext)
           manager.appDelegate = self
           return manager
       }()
    
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        requestNotificationPermission()
        locationManager.startCollection()
        registerBackgroundCollection()
        submitBackgroundCollection()
        return true
    }
    
    private func requestNotificationPermission() {
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound, .badge]) { granted, error in
            if let error = error {
                print("Notification permission error: \(error.localizedDescription)")
            } else {
                print("Notification permission granted: \(granted)")
            }
        }
    }
    
    private func registerBackgroundCollection() {
        if submitted { return }
        submitted = true
        
        scheduler.register(forTaskWithIdentifier: appConstants.backgroundTaskIdentifier, using: nil) { task in
            guard let task = task as? BGContinuedProcessingTask else { return }
            self.handleBackgroundCollection(task)
        }
    }
    
    func submitBackgroundCollection() {
        let identifier = appConstants.backgroundTaskIdentifier

        // Check for existing requests
        scheduler.getPendingTaskRequests { requests in
            if requests.contains(where: { $0.identifier == identifier }) {
                notify("Background task already scheduled. Skipping new submission.")
                return
            }

            let request = BGContinuedProcessingTaskRequest(
                identifier: identifier,
                title: "Sensor Data Collection",
                subtitle: "Collecting environmental metrics..."
            )

            request.strategy = .fail

            do {
                try self.scheduler.submit(request)
                notify("Submitted \(request.identifier) at \(Date())")
            } catch {
                notify("Submission failed: \(error.localizedDescription)")
            }
        }
    }
    
    private func handleBackgroundCollection(_ task: BGContinuedProcessingTask){
        notify("Background data collection started.")
        currentTask = task
        isUserStopped = false
        var wasExpired = false
        
        // Expiration = system ended early
        task.expirationHandler = { [weak self] in
            guard let self else { return }
            notify("Background task expired, system ended it")
            wasExpired = true
            self.sensorManager.stopCollection()
            task.setTaskCompleted(success: false)
            self.currentTask = nil
            scheduler.cancelAllTaskRequests()
            BGContinuedProcessingTask.cancelPreviousPerformRequests(withTarget: appConstants.backgroundTaskIdentifier)
        }
        
        // Start collecting data
        sensorManager.startCollection()
        
        // Keep updating progress just to keep iOS aware the task is alive
        let progress = task.progress
        progress.totalUnitCount = appConstants.totalTime // 30 min
        DispatchQueue.global(qos: .background).async {
            while !self.isUserStopped && !wasExpired && !progress.isFinished {
                progress.completedUnitCount += 1
                task.updateTitle("Collecting Data", subtitle: "Running...")
                sleep(1)
            }
        }
    }
    
    func stopBackgroundCollection() {
        guard let task = currentTask else {
            notify("No background task running.")
            return
        }

        notify("Stopping background collection manually.")
        locationManager.stopCollection()
        isUserStopped = true
        task.setTaskCompleted(success: isUserStopped)
        sensorManager.stopCollection()
        currentTask = nil
        scheduler.cancelAllTaskRequests()
        BGContinuedProcessingTask.cancelPreviousPerformRequests(withTarget: appConstants.backgroundTaskIdentifier)
    }
}
    
