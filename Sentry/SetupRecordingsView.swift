//
//  SetupRecordingsView.swift
//  Sentry
//
//  Created by 秋星桥 on 5/24/25.
//

import AppKit
import AVFoundation
import SwiftUI

class CameraManager: NSObject, ObservableObject {
    private let vm = SentryConfigurationManager.shared

    @Published var isAuthorized = false
    @Published var authorizationStatus: AVAuthorizationStatus = .notDetermined
    @Published var availableCameras: [AVCaptureDevice] = []
    @Published var selectedCamera: AVCaptureDevice?

    let captureSession = AVCaptureSession()
    private var videoDeviceInput: AVCaptureDeviceInput?

    override init() {
        super.init()
        checkPermission()
        discoverCameras()
    }

    func discoverCameras() {
        let discoverySession = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .externalUnknown],
            mediaType: .video,
            position: .unspecified
        )
        availableCameras = discoverySession.devices

        let persistedID = vm.cfg.sentryRecordingDevice
        if let persisted = availableCameras.first(where: { $0.uniqueID == persistedID }) {
            selectedCamera = persisted
        } else if let frontCamera = availableCameras.first(where: { $0.position == .front }) {
            selectedCamera = frontCamera
        } else {
            selectedCamera = availableCameras.first
        }
    }
    
    func checkPermission() {
        authorizationStatus = AVCaptureDevice.authorizationStatus(for: .video)
        isAuthorized = authorizationStatus == .authorized

        if isAuthorized { setupCamera() }
    }

    func requestPermission() {
        guard authorizationStatus == .notDetermined else {
            return
        }

        AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
            DispatchQueue.main.async {
                self?.authorizationStatus = granted ? .authorized : .denied
                self?.isAuthorized = granted

                if granted { self?.setupCamera() }
            }
        }
    }

    private func setupCamera() {
        guard let videoDevice = selectedCamera else { return }
        
        captureSession.beginConfiguration()

        // Remove existing input if any
        if let existingInput = videoDeviceInput {
            captureSession.removeInput(existingInput)
        }

        if captureSession.canSetSessionPreset(.medium) {
            captureSession.sessionPreset = .medium
        }

        guard let videoDeviceInput = try? AVCaptureDeviceInput(device: videoDevice),
              captureSession.canAddInput(videoDeviceInput)
        else {
            captureSession.commitConfiguration()
            return
        }

        captureSession.addInput(videoDeviceInput)
        self.videoDeviceInput = videoDeviceInput

        captureSession.commitConfiguration()

        DispatchQueue.global(qos: .background).async {
            self.captureSession.startRunning()
        }
    }
    
    func switchCamera(to device: AVCaptureDevice) {
        selectedCamera = device
        vm.cfg.sentryRecordingDevice = device.uniqueID
        
        // Only reconfigure if we're already authorized and running
        guard isAuthorized else { return }
        
        setupCamera()
    }

    deinit {
        captureSession.stopRunning()
    }
}

struct CameraPreviewView: NSViewRepresentable {
    let captureSession: AVCaptureSession

    func makeNSView(context _: Context) -> NSView {
        let view = NSView()

        let previewLayer = AVCaptureVideoPreviewLayer(session: captureSession)
        previewLayer.videoGravity = .resizeAspectFill

        view.layer = previewLayer
        view.wantsLayer = true

        return view
    }

    func updateNSView(_ nsView: NSView, context _: Context) {
        if let layer = nsView.layer as? AVCaptureVideoPreviewLayer {
            layer.session = captureSession
        }
    }
}

struct SetupRecordingsView: View {
    @StateObject var vm = SentryConfigurationManager.shared
    @StateObject private var cameraManager = CameraManager()

    var body: some View {
        FormView(title: "Setup Recordings", leftBottom: {
            Button("Open Saved Clips") {
                try? FileManager.default.createDirectory(
                    atPath: videoClipDir.path,
                    withIntermediateDirectories: true
                )
                // select the directory
                NSWorkspace.shared.selectFile(
                    nil,
                    inFileViewerRootedAtPath: videoClipDir.path
                )
            }
        }) {
            VStack(alignment: .leading, spacing: 8) {
                Text("You can enable camera recording when Sentry is activated.")
                    .fixedSize(horizontal: false, vertical: true)
                Divider()
                Toggle(isOn: $vm.cfg.sentryRecordingEnabled) {
                    Text("Enable Camera Recording")
                }

                if cameraManager.isAuthorized {
                    CameraPreviewView(captureSession: cameraManager.captureSession)
                        .background(.black)
                        .frame(height: 150)
                        .cornerRadius(8)
                    
                    if cameraManager.availableCameras.count > 1 {
                        Picker("Camera", selection: Binding(
                            get: { cameraManager.selectedCamera },
                            set: { newCamera in
                                if let camera = newCamera {
                                    cameraManager.switchCamera(to: camera)
                                }
                            }
                        )) {
                            ForEach(cameraManager.availableCameras, id: \.uniqueID) { camera in
                                Text(camera.localizedName).tag(camera as AVCaptureDevice?)
                            }
                        }
                        .pickerStyle(.menu)
                    }
                } else {
                    Rectangle()
                        .foregroundStyle(.black)
                        .frame(height: 150)
                        .overlay {
                            VStack {
                                Image(systemName: "camera.fill")
                                    .font(.largeTitle)
                                    .foregroundStyle(.white)
                                Text(cameraManager.authorizationStatus == .denied ? "Camera Access Denied" : "Requesting Camera Access...")
                                    .foregroundStyle(.white)
                                    .font(.caption)
                            }
                        }
                        .cornerRadius(8)
                }
                Text("Please remember to respect the privacy of others.")
                    .underline()
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onAppear { cameraManager.requestPermission() }
    }
}

#Preview {
    SetupRecordingsView()
}
