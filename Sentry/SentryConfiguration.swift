//
//  SentryConfiguration.swift
//  Sentry
//
//  Created by 秋星桥 on 5/24/25.
//

import Foundation
import SwiftUI

class SentryConfigurationManager: ObservableObject {
    static let shared = SentryConfigurationManager()
    private init() {}

    @PublishedPersist(key: "sentry.config", defaultValue: .init())
    var cfg: SentryConfiguration

    @Published var sleepHoldServiceIdentifier: String = ""
    @Published var sleepHoldServiceLastUpdate: Date = .init()

    var hasTriggerEnabled: Bool {
        false
            || cfg.sentryTriggersLidEnabled
            || cfg.sentryTriggersInternetEnabled
            || cfg.sentryTriggersPowerEnabled
    }

    var hasNotificationEnabled: Bool {
        false
            || cfg.sentryAlarmsNotificationType != .none
            || cfg.sentryAlarmsSoundsEnabled
    }

    var hasRecordingEnabled: Bool {
        false
            || cfg.sentryRecordingEnabled
    }

    var canActivate: Bool {
        hasTriggerEnabled && hasNotificationEnabled
    }

    func communicateWithSleepHoldServiceIfNeeded() {
        if sleepHoldServiceIdentifier.isEmpty {
            // try to connect every 3 sec
            defer { sleepHoldServiceLastUpdate = .init() }
            DispatchQueue.global().async {
                self.sleepHoldConnect()
            }
        } else {
            // for each 10 sec, post extend
            if Date().timeIntervalSince(sleepHoldServiceLastUpdate) > 10 {
                defer { sleepHoldServiceLastUpdate = .init() }
                DispatchQueue.global().async {
                    self.sleepHoldExtend()
                }
            }
        }
    }

    private func sleepHoldConnect() {
        guard sleepHoldServiceIdentifier.isEmpty else { return }
        var request = URLRequest(
            url: URL(string: "http://127.0.0.1:8180/service/session/create")!,
            cachePolicy: .reloadIgnoringLocalAndRemoteCacheData,
            timeoutInterval: 3
        )
        request.httpMethod = "POST"
        let task = URLSession.shared.dataTask(with: request) { data, _, _ in
            guard let data else { return }
            let dic = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any]
            guard let sessionId = dic?["sessionId"] as? String else { return }
            DispatchQueue.main.async {
                print("[*] sleep hold service connected with sessionId: \(sessionId)")
                self.sleepHoldServiceIdentifier = sessionId
                self.sleepHoldServiceLastUpdate = .init()
            }
        }
        task.resume()
    }

    private func sleepHoldExtend() {
        guard !sleepHoldServiceIdentifier.isEmpty,
              sleepHoldServiceIdentifier != "---"
        else { return }
        var request = URLRequest(
            url: URL(string: "http://127.0.0.1:8180/service/session/extend")!,
            cachePolicy: .reloadIgnoringLocalAndRemoteCacheData,
            timeoutInterval: 3
        )
        request.httpMethod = "POST"
        struct ExtendRequest: Codable {
            let sessionId: String
        }
        let extendRequest = ExtendRequest(sessionId: sleepHoldServiceIdentifier)
        request.httpBody = try! JSONEncoder().encode(extendRequest)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let task = URLSession.shared.dataTask(with: request) { _, response, _ in
            guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
                // pass, the session may be terminated
                return
            }
            DispatchQueue.main.async {
                print("[*] sleep hold session extended successfully")
                self.sleepHoldServiceLastUpdate = .init()
            }
        }
        task.resume()
    }

    func disconnectFromSleepHold() {
        guard !sleepHoldServiceIdentifier.isEmpty,
              sleepHoldServiceIdentifier != "---"
        else { return }
        let sid = sleepHoldServiceIdentifier
        // just revoke the session, afterwards hold extend will fail
        var request = URLRequest(
            url: URL(string: "http://127.0.0.1:8180/service/session/terminate")!,
            cachePolicy: .reloadIgnoringLocalAndRemoteCacheData,
            timeoutInterval: 3
        )
        request.httpMethod = "POST"
        struct TerminateRequest: Codable {
            let sessionId: String
        }
        let terminateRequest = TerminateRequest(sessionId: sid)
        request.httpBody = try! JSONEncoder().encode(terminateRequest)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let task = URLSession.shared.dataTask(with: request) { _, response, _ in
            guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
                // pass, the session may be terminated
                return
            }
            DispatchQueue.main.async {
                print("[*] sleep hold service disconnected successfully")
                self.sleepHoldServiceIdentifier = "---"
                self.sleepHoldServiceLastUpdate = .init()
            }
        }
        task.resume()
    }
}

struct SentryConfiguration: Codable, Equatable, Hashable {
    var sentryTriggersLidEnabled: Bool = false
    var sentryTriggersInternetEnabled: Bool = false
    var sentryTriggersPowerEnabled: Bool = false

    var sentryAlarmsSoundsEnabled: Bool = false

    var sentryAlarmsNotificationType: NotificationType = .none
    enum NotificationType: String, Codable, Equatable, Hashable {
        case none
        case bark
    }

    var sentryNotificationConfigBark: NotificationConfiguration_Bark = .init()
    struct NotificationConfiguration_Bark: Codable, Equatable, Hashable {
        var endpoint: String = "https://"
    }

    var sentryRecordingEnabled: Bool = false
    var sentryRecordingDevice: String? = nil
}
