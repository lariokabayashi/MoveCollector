//
//  userNotification.swift
//  MotionApp
//
//  Created by Larissa Okabayashi on 08/11/25.
//

import UserNotifications

func notify(_ message: String) {
    let content = UNMutableNotificationContent()
    content.title = "BGTask Log"
    content.body = message
    let request = UNNotificationRequest(identifier: UUID().uuidString,
                                        content: content, trigger: nil)
    UNUserNotificationCenter.current().add(request)
}
