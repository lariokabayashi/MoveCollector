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

/// Labels reais do botão (UI em português). O estado deriva de
/// `sensorManager.isRecording`: "Iniciar coleta" quando parado, "Parar coleta"
/// quando gravando.
private enum ButtonLabel {
    static let start = "Iniciar coleta"
    static let stop = "Parar coleta"
}

final class SensorDataUITests: XCTestCase {
    
    var app: XCUIApplication!
    
    override func setUpWithError() throws {
        // In UI tests it is usually best to stop immediately when a failure occurs.
        continueAfterFailure = false
        
        app = XCUIApplication()
        app.launchArguments += ["-skipOnboarding"]
        app.launch()
    }
    
    override func tearDownWithError() throws {
        app = nil
    }

    // MARK: - Helpers

    /// Espera o `label` de um elemento ficar igual a `expected`. Necessário porque
    /// o botão só troca quando a BGTask realmente sobe (isRecording vira true),
    /// o que pode ter uma pequena latência após o toque.
    @discardableResult
    private func waitForLabel(_ element: XCUIElement,
                              toEqual expected: String,
                              timeout: TimeInterval = 5.0) -> Bool {
        let predicate = NSPredicate(format: "label == %@", expected)
        let exp = XCTNSPredicateExpectation(predicate: predicate, object: element)
        return XCTWaiter().wait(for: [exp], timeout: timeout) == .completed
    }

    private func sleep(_ seconds: TimeInterval) {
        let exp = XCTestExpectation(description: "sleep \(seconds)s")
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { exp.fulfill() }
        wait(for: [exp], timeout: seconds + 1.0)
    }

    // MARK: - Core UI Functionality Tests
    
    func testStartStopAndDataDisplay() throws {
        let startStopButton = app.buttons[AccessibilityIdentifiers.startStopButton]
        let accelXLabel = app.staticTexts[AccessibilityIdentifiers.accelXLabel]
        let durationTimerLabel = app.staticTexts[AccessibilityIdentifiers.durationTimerLabel]
        
        // 1. Estado inicial: app NÃO inicia coleta sozinho no launch.
        XCTAssertTrue(startStopButton.waitForExistence(timeout: 5.0), "Start/Stop button must exist")
        XCTAssertEqual(startStopButton.label, ButtonLabel.start, "Button should start in stopped state")
        
        // 2. Inicia a coleta.
        startStopButton.tap()
        XCTAssertTrue(waitForLabel(startStopButton, toEqual: ButtonLabel.stop),
                      "Button label should change to '\(ButtonLabel.stop)' once collection starts")
        
        // 3. Verifica que os dados de sensor estão atualizando.
        let initialAccelXValue = accelXLabel.label
        sleep(2.0)
        let newAccelXValue = accelXLabel.label
        XCTAssertNotEqual(initialAccelXValue, newAccelXValue, "Sensor data label should update after collection starts")
        
        // 4. Verifica que o contador de duração está correndo (≠ "0.00 s").
        XCTAssertNotEqual(durationTimerLabel.label, "0.00 s", "Duration timer should be running")
        
        // 5. Para a coleta.
        startStopButton.tap()
        XCTAssertTrue(waitForLabel(startStopButton, toEqual: ButtonLabel.start),
                      "Button label should change back to '\(ButtonLabel.start)'")
        
        // 6. Verifica que o contador congelou após parar.
        let finalTimerValue = durationTimerLabel.label
        sleep(1.0)
        XCTAssertEqual(finalTimerValue, durationTimerLabel.label, "Duration timer should freeze after collection stops")
    }
}

// MARK: - Data Collection and Export Flow Tests

extension SensorDataUITests {
    
    func testFullDataCollectionAndExportFlow() throws {
        let startStopButton = app.buttons[AccessibilityIdentifiers.startStopButton]
        
        // 1. Inicia a coleta.
        startStopButton.tap()
        XCTAssertTrue(waitForLabel(startStopButton, toEqual: ButtonLabel.stop),
                      "Pre-condition: collection must be running")
        
        // 2. Coleta por alguns segundos.
        sleep(5.0)
        
        // 3. Para a coleta (dispara o export do CSV e exibe o botão Exportar).
        startStopButton.tap()
        XCTAssertTrue(waitForLabel(startStopButton, toEqual: ButtonLabel.start),
                      "Collection must be stopped")
    }
    
    func testBackgroundToForegroundTransition() throws {
        let startStopButton = app.buttons[AccessibilityIdentifiers.startStopButton]
        let durationTimerLabel = app.staticTexts[AccessibilityIdentifiers.durationTimerLabel]
        
        // 1. Inicia a coleta.
        startStopButton.tap()
        XCTAssertTrue(waitForLabel(startStopButton, toEqual: ButtonLabel.stop),
                      "Pre-condition: collection must be running")
        
        // 2. Captura o valor inicial do contador.
        let initialTimerValue = durationTimerLabel.label
        
        // 3. Manda o app para background (botão home).
        XCUIDevice.shared.press(XCUIDevice.Button.home)
        
        // 4. Aguarda em background (simula tarefa longa).
        sleep(5.0)
        
        // 5. Traz o app de volta para foreground.
        app.activate()
        
        // 6. O estado da coleta deve ser mantido.
        XCTAssertEqual(startStopButton.label, ButtonLabel.stop,
                       "Collection state should be maintained after returning from background")
        
        // 7. O contador deve ter avançado.
        let finalTimerValue = durationTimerLabel.label
        XCTAssertNotEqual(initialTimerValue, finalTimerValue, "Timer value should have advanced after background period")
        
        // 8. Para a coleta (cleanup).
        startStopButton.tap()
    }
}

