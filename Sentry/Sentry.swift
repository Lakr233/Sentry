//
//  Sentry.swift
//  Sentry
//
//  Created by 秋星桥 on 5/24/25.
//

import AppKit
import AVFAudio
import AVFoundation
import AVKit
import Foundation
import SkyLightWindow
import SwiftUI

class Sentry: NSObject, ObservableObject {
    // MARK: - FOR VIEWS

    // updated from isCurrentlyAlarming
    @Published var isAlrming: Bool = false

    // MARK: - Configuration & Callbacks

    let configuration: SentryConfiguration
    let onAlarmingActivaty: (_ reason: String) -> Void

    // MARK: - Status Management

    enum Status {
        case run
        case tearingDown
        case stop
    }

    private var status: Status = .stop
    private var windowController: NSWindowController?

    // MARK: - Device State Tracking

    private var lastLidState: Bool?
    private var lastNetworkState: Bool?
    private var lastPowerState: Bool?
    private var initialSpeakerVolume: Float = 0.0

    // MARK: - Alarm System

    private var isCurrentlyAlarming: Bool = false {
        didSet { DispatchQueue.main.async { self.isAlrming = self.isCurrentlyAlarming } }
    }

    private var audioPlayer: AVAudioPlayer?
    private var volumeTimer: Timer?
    private var notificationPosted: Bool = false

    // MARK: - Recording System

    private var captureSession: AVCaptureSession?
    private var videoFileOutput: AVCaptureMovieFileOutput?
    private var currentRecordingURL: URL?
    private var recordingStartTime: Date?

    // MARK: - Initialization

    init(configuration: SentryConfiguration, onAlarmingActivaty: @escaping (_ reason: String) -> Void) {
        self.configuration = configuration
        self.onAlarmingActivaty = onAlarmingActivaty
        super.init()
    }

    // MARK: - Public Methods

    func run() {
        assert(status == .stop, "Sentry is already running")
        status = .run
        assert(Thread.isMainThread)
        windowController = SkyLightOperator.shared.delegateView(
            AnyView(SentryView(sentry: self)),
            toScreen: .main!
        )
        if configuration.sentryRecordingEnabled {
            startRecording()
        }
        initialSpeakerVolume = AlarmEngine.readSystemVolume() ?? 0
        Thread {
            while self.status == .run {
                sleep(1)
                self.executeOnce()
            }
        }
        .start()
    }

    func stop() {
        guard status == .run else { return }
        status = .tearingDown
        stopRecording()
        unlockAlarm()
        SentryConfigurationManager.shared.disconnectFromSleepHold()
        AlarmEngine.setSystemVolume(initialSpeakerVolume)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.3
            windowController?.window?.contentView?.animator().alphaValue = 0
        } completionHandler: {
            self.windowController?.close()
            self.status = .stop
            self.resetStates()
        }
    }

    func unlockAlarm() {
        guard isCurrentlyAlarming else { return }
        isCurrentlyAlarming = false
        stopAlarm()
    }

    // MARK: - Private Methods - State Management

    private func resetStates() {
        lastLidState = nil
        lastNetworkState = nil
        lastPowerState = nil
        isCurrentlyAlarming = false
        stopAlarm()
        stopRecording()
    }

    // MARK: - Private Methods - Monitoring

    private func executeOnce() {
        guard !isCurrentlyAlarming else { return }

        SentryConfigurationManager.shared.communicateWithSleepHoldServiceIfNeeded()

        if configuration.sentryTriggersLidEnabled {
            checkLidState()
        }
        if configuration.sentryTriggersInternetEnabled {
            checkNetworkState()
        }
        if configuration.sentryTriggersPowerEnabled {
            checkPowerState()
        }
    }

    private func checkLidState() {
        guard let currentLidState = DeviceCheck.isMacLidClosed() else { return }

        if lastLidState == nil {
            lastLidState = currentLidState
            return
        }

        if let lastState = lastLidState, !lastState, currentLidState {
            triggerAlarm(reason: String(localized: "Mac Lid Closed"))
        }

        lastLidState = currentLidState
    }

    private func checkNetworkState() {
        let currentNetworkState = DeviceCheck.isConnectedToWirelessNetwork()

        if lastNetworkState == nil {
            lastNetworkState = currentNetworkState
            return
        }

        if let lastState = lastNetworkState, lastState, !currentNetworkState {
            triggerAlarm(reason: String(localized: "Network Disconnected"))
        }

        lastNetworkState = currentNetworkState
    }

    private func checkPowerState() {
        let currentPowerState = DeviceCheck.isConnectedToPower()

        if lastPowerState == nil {
            lastPowerState = currentPowerState
            return
        }

        if let lastState = lastPowerState, lastState, !currentPowerState {
            triggerAlarm(reason: String(localized: "Power Disconnected"))
        }

        lastPowerState = currentPowerState
    }

    // MARK: - Private Methods - Alarm System

    private func triggerAlarm(reason: String) {
        guard !isCurrentlyAlarming else { return }
        isCurrentlyAlarming = true
        DispatchQueue.main.async {
            self.onAlarmingActivaty(reason)
        }
        executeAlarmActions(reason: reason)
    }

    private func executeAlarmActions(reason: String) {
        if configuration.sentryAlarmsSoundsEnabled {
            playAlarmSound()
        }

        switch configuration.sentryAlarmsNotificationType {
        case .bark:
            sendBarkNotification(message: reason)
        case .none:
            break
        }
    }

    private func playAlarmSound() {
        guard let soundURL = Bundle.main.url(forResource: "alarm", withExtension: "mp3") else {
            assertionFailure()
            return
        }

        do {
            let audioPlayer = try AVAudioPlayer(contentsOf: soundURL)
            self.audioPlayer = audioPlayer
            audioPlayer.numberOfLoops = -1 // 无限循环
            audioPlayer.volume = 0.1 // 开始时 10% 音量
            audioPlayer.currentDevice = "BuiltInSpeakerDevice"
            audioPlayer.play()

            startVolumeTimer()
        } catch {
            print("[-] failed to play alarm sound: \(error)")
        }
    }

    private func startVolumeTimer() {
        volumeTimer?.invalidate()
        var currentStep = 0
        let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] timer in
            guard let self, isCurrentlyAlarming else {
                timer.invalidate()
                return
            }
            AlarmEngine.setSystemVolume(1)

            currentStep += 1
            if currentStep <= 3 { return }

            let newVolume = min(1.0, 0.1 + Float(currentStep - 3) * 0.2)
            audioPlayer?.volume = newVolume

            print("[*] alarm sound volume: \(newVolume)")

            if newVolume >= 1.0 {
                timer.invalidate()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        volumeTimer = timer
    }

    private func stopAlarm() {
        volumeTimer?.invalidate()
        volumeTimer = nil
        audioPlayer?.stop()
        audioPlayer = nil
    }

    // MARK: - Private Methods - Notifications

    private func sendBarkNotification(message: String) {
        guard !notificationPosted else { return }
        guard configuration.sentryAlarmsNotificationType == .bark else { return }
        guard let initialURL = URL(string: configuration.sentryNotificationConfigBark.endpoint) else {
            return
        }
        let newURL = initialURL
            .appendingPathComponent(String(localized: "Sentry - Mac"))
            .appendingPathComponent(message)
        guard var comps = URLComponents(url: newURL, resolvingAgainstBaseURL: false) else { return }
        comps.queryItems = [
            .init(name: "level", value: "critical"),
            .init(name: "volume", value: "5"),
            .init(name: "group", value: String(localized: "Sentry - Mac")),
            .init(name: "isArchive", value: "1"),
            .init(name: "call", value: "1"),
            .init(name: "icon", value: "https://github.com/Lakr233/Sentry/blob/main/Sentry/Assets.xcassets/icon-512.imageset/icon-512@2x.png?raw=true"),
        ]
        let url = comps.url
        guard let url else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        URLSession.shared.dataTask(with: request) { _, _, error in
            if let error {
                print("[*] bark push error: \(error)")
            }
        }.resume()
    }

    // MARK: - Private Methods - Recording
    
    private func loadDevice(for deviceID: String?) -> AVCaptureDevice? {
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .externalUnknown],
            mediaType: .video,
            position: .unspecified
        )
        return discovery.devices.first(where: { $0.uniqueID == deviceID })
            ?? AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front)
    }

    private func startRecording() {
        print("[*] start recording camera...")

        guard captureSession == nil else { return }
        guard AVCaptureDevice.authorizationStatus(for: .video) == .authorized else {
            print("[*] camera permission not granted")
            return
        }
        captureSession = AVCaptureSession()
        guard let captureSession else { return }

        captureSession.beginConfiguration()

        if captureSession.canSetSessionPreset(.medium) {
            captureSession.sessionPreset = .medium
        }
        guard let videoDevice = loadDevice(for: configuration.sentryRecordingDevice),
              let videoDeviceInput = try? AVCaptureDeviceInput(device: videoDevice),
              captureSession.canAddInput(videoDeviceInput)
        else {
            print("[*] failed to add video input")
            captureSession.commitConfiguration()
            self.captureSession = nil
            return
        }

        captureSession.addInput(videoDeviceInput)
        videoFileOutput = AVCaptureMovieFileOutput()
        guard let videoFileOutput,
              captureSession.canAddOutput(videoFileOutput)
        else {
            print("[*] failed to add video output")
            captureSession.commitConfiguration()
            self.captureSession = nil
            return
        }

        captureSession.addOutput(videoFileOutput)
        captureSession.commitConfiguration()

        recordingStartTime = Date()
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let fileName = "Sentry_\(formatter.string(from: recordingStartTime!)).mov"
        currentRecordingURL = videoClipDir.appendingPathComponent(fileName)

        try? FileManager.default.createDirectory(
            at: videoClipDir,
            withIntermediateDirectories: true,
            attributes: nil
        )
        DispatchQueue.global(qos: .background).async {
            captureSession.startRunning()

            if let outputURL = self.currentRecordingURL {
                videoFileOutput.startRecording(to: outputURL, recordingDelegate: self)
                print("[*] recording started to: \(outputURL.path)")
            }
        }
    }

    private func stopRecording() {
        guard let captureSession else { return }

        print("[*] stop recording camera...")

        videoFileOutput?.stopRecording()

        DispatchQueue.global(qos: .background).async {
            captureSession.stopRunning()
        }

        self.captureSession = nil
        videoFileOutput = nil
        currentRecordingURL = nil
        recordingStartTime = nil
    }
}

// MARK: - AVCaptureFileOutputRecordingDelegate

extension Sentry: AVCaptureFileOutputRecordingDelegate {
    func fileOutput(_: AVCaptureFileOutput, didFinishRecordingTo outputFileURL: URL, from _: [AVCaptureConnection], error: Error?) {
        if let error {
            print("[*] recording finished with error: \(error)")
        } else {
            print("[*] recording finished successfully: \(outputFileURL.path)")
        }
    }
}
