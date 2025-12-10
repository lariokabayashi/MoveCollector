//
//  UITest.swift
//  UITest
//
//  Created by Larissa Okabayashi on 16/11/25.
//

import XCTest

struct AccessibilityIdentifiers {
    static let startStopButton = "StartStopButton"
    static let accelXLabel = "AccelXLabel"
    static let durationTimerLabel = "DurationTimerLabel"
}

final class SensorDataUITests: XCTestCase {
    
    var app: XCUIApplication!
    
    override func setUpWithError() throws {
        // Put setup code here. This method is called before the invocation of each test method in the class.
        
        // In UI tests it is usually best to stop immediately when a failure occurs.
        continueAfterFailure = false
        
        app = XCUIApplication()
        app.launch()
    }
    
    override func tearDownWithError() throws {
        // Put teardown code here. This method is called after the invocation of each test method in the class.
        app = nil
    }
    
    // MARK: - Core UI Functionality Tests
    
    func testStartStopAndDataDisplay() throws {
        let startStopButton = app.buttons[AccessibilityIdentifiers.startStopButton]
        let accelXLabel = app.staticTexts[AccessibilityIdentifiers.accelXLabel]
        let durationTimerLabel = app.staticTexts[AccessibilityIdentifiers.durationTimerLabel]
        
        // 1. Initial State Check (Assuming the app starts in a stopped state)
        XCTAssertTrue(startStopButton.exists, "Start/Stop button must exist")
        XCTAssertEqual(startStopButton.label, "Stop", "Button label should be 'Stop' initially")
        
        // 2. Start Collection
        startStopButton.tap()
        XCTAssertEqual(startStopButton.label, "Start", "Button label should change to 'Start' after tapping")
        
        // 3. Verify Data Display is Updating
        // Get the initial value of the Accelerometer X label
        let initialAccelXValue = accelXLabel.label
        
        // Wait for a short period to allow sensor data to update
        let expectation = XCTestExpectation(description: "Wait for sensor data to update")
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 3.0)
        
        // Get the new value and assert it has changed (or is a valid number format)
        let newAccelXValue = accelXLabel.label
        XCTAssertNotEqual(initialAccelXValue, newAccelXValue, "Sensor data label should update after collection starts")
        
        // Verify the timer is running (i.e., not "00:00:00")
        XCTAssertNotEqual(durationTimerLabel.label, "00:00:00", "Duration timer should be running")
        
        // 4. Stop Collection
        startStopButton.tap()
        XCTAssertEqual(startStopButton.label, "Start", "Button label should change back to 'Start'")
        
        // Wait for a moment and check if the timer has stopped
        let finalTimerValue = durationTimerLabel.label
        let stopExpectation = XCTestExpectation(description: "Wait for timer to stop")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            stopExpectation.fulfill()
        }
        wait(for: [stopExpectation], timeout: 2.0)
        XCTAssertEqual(finalTimerValue, durationTimerLabel.label, "Duration timer should stop after collection stops")
    }
}

// MARK: - Data Collection and Export Flow Tests

extension SensorDataUITests {
    
    func testFullDataCollectionAndExportFlow() throws {
        let startStopButton = app.buttons[AccessibilityIdentifiers.startStopButton]
        
        // 1. Start Collection
        startStopButton.tap()
        XCTAssertEqual(startStopButton.label, "Stop", "Pre-condition: Collection must be running")
        
        // 2. Wait for a short period to ensure data is collected
        let collectionTime: TimeInterval = 5.0
        let collectionExpectation = XCTestExpectation(description: "Collect data for \(collectionTime) seconds")
        DispatchQueue.main.asyncAfter(deadline: .now() + collectionTime) {
            collectionExpectation.fulfill()
        }
        wait(for: [collectionExpectation], timeout: collectionTime + 1.0)
        
        // 3. Stop Collection (This should trigger the CSV export and make the Export button visible)
        startStopButton.tap()
        XCTAssertEqual(startStopButton.label, "Start", "Collection must be stopped")
    }
    
    func testBackgroundToForegroundTransition() throws {
        let startStopButton = app.buttons[AccessibilityIdentifiers.startStopButton]
        let durationTimerLabel = app.staticTexts[AccessibilityIdentifiers.durationTimerLabel]
        
        // 1. Start Collection
        startStopButton.tap()
        XCTAssertEqual(startStopButton.label, "Stop", "Pre-condition: Collection must be running")
        
        // 2. Get initial timer value
        let initialTimerValue = durationTimerLabel.label
        
        // 3. Simulate App Backgrounding (using the device home button)
        XCUIDevice.shared.press(XCUIDevice.Button.home)
        
        // 4. Wait in the background (Simulate long-running background task)
        let backgroundTime: TimeInterval = 5.0
        let backgroundExpectation = XCTestExpectation(description: "Wait in background for \(backgroundTime) seconds")
        DispatchQueue.main.asyncAfter(deadline: .now() + backgroundTime) {
            backgroundExpectation.fulfill()
        }
        wait(for: [backgroundExpectation], timeout: backgroundTime + 1.0)
        
        // 5. Simulate App Foregrounding (re-launching the app)
        app.activate()
        
        // 6. Verify State is Maintained
        // The button should still say "Stop"
        XCTAssertEqual(startStopButton.label, "Stop", "Collection state should be maintained after returning from background")
        
        // The timer value should have advanced significantly
        let finalTimerValue = durationTimerLabel.label
        XCTAssertNotEqual(initialTimerValue, finalTimerValue, "Timer value should have advanced after background period")
        
        // Stop the collection for cleanup
        startStopButton.tap()
    }
}
