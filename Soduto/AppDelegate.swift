//
//  AppDelegate.swift
//  Soduto
//
//  Created by Giedrius Stanevičius on 2016-07-06.
//  Copyright © 2016 Soduto. All rights reserved.
//

import Cocoa
import Foundation
import os
import UserNotifications
import Sparkle
import MediaPlayer

@NSApplicationMain
class AppDelegate: NSObject, NSApplicationDelegate, DeviceManagerDelegate {
    
    var validDevices: [Device] = []
    @IBOutlet weak var statusBarMenuController: StatusBarMenuController!
    @IBOutlet weak var checkForUpdatesMenuItem: NSMenuItem!
    var welcomeWindowController: WelcomeWindowController?
    
    let config = Configuration()
    let connectionProvider: ConnectionProvider
    let deviceManager: DeviceManager
    let serviceManager = ServiceManager()
    private(set) var userNotificationManager: UserNotificationManager!
    let updaterController: SPUStandardUpdaterController
    private var heartbeatTimer: Timer?
    
    override init() {
        self.connectionProvider = ConnectionProvider(config: config)
        self.deviceManager = DeviceManager(config: config, serviceManager: self.serviceManager)
        self.updaterController = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
        
        super.init()
        
        self.checkOneAppInstanceRunning()
    }
    
    
    // MARK: NSApplicationDelegate
    
    func applicationDidFinishLaunching(_ aNotification: Notification) {
        self.userNotificationManager = UserNotificationManager(config: self.config, serviceManager: self.serviceManager, deviceManager: self.deviceManager)
        self.config.capabilitiesDataSource = self.serviceManager
        self.connectionProvider.delegate = self.deviceManager
        self.statusBarMenuController.deviceDataSource = self.deviceManager
        self.statusBarMenuController.serviceManager = self.serviceManager
        self.statusBarMenuController.config = self.config
        self.deviceManager.delegate = self
        
        self.checkForUpdatesMenuItem.target = updaterController
        self.checkForUpdatesMenuItem.action = #selector(SPUStandardUpdaterController.checkForUpdates(_:))
        
        self.serviceManager.add(service: NotificationsService())
        self.serviceManager.add(service: ClipboardService())
        self.serviceManager.add(service: SftpService())
        self.serviceManager.add(service: ShareService())
        self.serviceManager.add(service: TelephonyService())
        self.serviceManager.add(service: PingService())
        self.serviceManager.add(service: BatteryService())
        self.serviceManager.add(service: ConnectivityReportService())
        self.serviceManager.add(service: FindMyPhoneService())
        self.serviceManager.add(service: RemoteKeyboardService())
        self.serviceManager.add(service: RunCommandService())
        self.serviceManager.add(service: MacToRemoteInputService())
        self.serviceManager.add(service: MPRISService())
        
        self.updateValidDevices()
        self.startHeartbeat()
        let notificationName = "com.soduto.share.handoff" as CFString
        let notificationCenter = CFNotificationCenterGetDarwinNotifyCenter()
        registerShareExtensionObserver(notificationCenter, notificationName)
        
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(wakeUpListener(_:)), name: NSWorkspace.didWakeNotification, object: nil)
        
        self.connectionProvider.start()
        
        showWelcomeWindow()
    }
    
    func applicationWillTerminate(_ aNotification: Notification) {
        heartbeatTimer?.invalidate()
        AppDefaultsStore.ShareExtension.appLastHeartbeat = 0
        AppDefaultsStore.ShareExtension.reachableDevices = []
    }
    
    
    // MARK: DeviceManagerDelegate
    
    func deviceManager(_ manager: DeviceManager, didChangeDeviceState device: Device) {
        self.statusBarMenuController.refreshDeviceLists()
        self.welcomeWindowController?.refreshDeviceLists()
        self.updateValidDevices()
    }
    
    func deviceManager(_ manager: DeviceManager, didReceivePairingRequest request: PairingRequest, forDevice device: Device) {
        Logger.general.debug("deviceManager(<\(String(describing: request), privacy: .public)> didReceivePairingRequest:<\(String(describing: request), privacy: .public)> forDevice:<\(String(describing: device), privacy: .public)>)")
        PairingInterfaceController.showPairingNotification(for: device)
    }
    
    
    // MARK: Private
    
    private func checkOneAppInstanceRunning() {
        let lockFileName = FileManager.default.compatTemporaryDirectory.appendingPathComponent(self.config.hostDeviceId).appendingPathExtension("lock").path
        if !tryLock(lockFileName) {
            let alert = NSAlert()
            alert.addButton(withTitle: "Quit Soduto")
            alert.informativeText = NSLocalizedString("Another instance of the app is already running!", comment: "")
            alert.messageText = Bundle.main.bundleIdentifier?.components(separatedBy: ".").last ?? ""
            alert.runModal()
            NSApp.terminate(self)
        }
    }
    
    private func showWelcomeWindow() {
        guard self.config.knownDeviceConfigs().filter({ $0.isPaired }).isEmpty else { return }
        
        let storyboard = NSStoryboard(name: "WelcomeWindow", bundle: nil)
        guard let controller = storyboard.instantiateInitialController() as? WelcomeWindowController else { assertionFailure("Could not load welcome window controller."); return }
        
        NSApp.activate(ignoringOtherApps: true)
        
        controller.deviceDataSource = self.deviceManager
        controller.dismissHandler = { [weak self] _ in self?.welcomeWindowController = nil }
        controller.showWindow(nil)
        self.welcomeWindowController = controller
    }
    
    // MARK: WakeUP Function
    
    @objc private func wakeUpListener(_ aNotification: Notification) {
        self.connectionProvider.restart()
        self.updateValidDevices()
    }
    
    // MARK: Extension Support
    
    private func startHeartbeat() {
        AppDefaultsStore.ShareExtension.appLastHeartbeat = Date().timeIntervalSince1970
        heartbeatTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { _ in
            AppDefaultsStore.ShareExtension.appLastHeartbeat = Date().timeIntervalSince1970
        }
    }
    
    public func updateValidDevices() {
        self.validDevices = deviceManager.pairedRechableDevices
        let deviceEntries: [[String: String]] = self.validDevices.map { [
            "id": $0.id,
            "name": $0.name,
            "type": $0.type.rawValue
        ] }
        AppDefaultsStore.ShareExtension.reachableDevices = deviceEntries
    }
    
    static func shared() -> AppDelegate {
        guard let delegate = NSApplication.shared.delegate as? AppDelegate else { fatalError("AppDelegate not configured") }
        return delegate
    }
    
    /// Darwin Notification Center Observer to observe notifications from Share Extension
    fileprivate func registerShareExtensionObserver(_ notificationCenter: CFNotificationCenter?, _ notificationName: CFString) {
        CFNotificationCenterAddObserver(notificationCenter, nil, { _, _, _, _, _ in
            AppDelegate.shared().handleShareExtensionTrigger()
        }, notificationName, nil, .deliverImmediately)
    }
    
    private func handleShareExtensionTrigger() {
        guard let deviceId = AppDefaultsStore.ShareExtension.selectedDevice, !deviceId.isEmpty else {
            UserNotificationHelper.show(title: "Soduto Share", body: "No target device was specified. Please try sharing again.", sound: true, id: "NoDeviceSelected")
            return
        }
        
        let bookmarks = AppDefaultsStore.ShareExtension.fileBookmarkData ?? []
        let texts = AppDefaultsStore.ShareExtension.sharedTexts ?? []
        
        guard !bookmarks.isEmpty || !texts.isEmpty else {
            ShareService.reportExtensionTransferStatus(deviceId: deviceId, status: "failed")
            UserNotificationHelper.show(title: "Soduto Share", body: "Nothing to share. Please try again.", sound: true, id: "NoShareData")
            return
        }
        
        guard let shareService = self.serviceManager.service(ofType: ShareService.self) else {
            ShareService.reportExtensionTransferStatus(deviceId: deviceId, status: "failed")
            UserNotificationHelper.show(title: "Soduto Share", body: "Share service is not available. Please restart Soduto.", sound: true, id: "ShareServiceUnavailable")
            return
        }
        
        guard let device = self.deviceManager.device(withId: deviceId) else {
            ShareService.reportExtensionTransferStatus(deviceId: deviceId, status: "failed")
            UserNotificationHelper.show(title: "Soduto Share", body: "The selected device is no longer reachable.", sound: true, id: "DeviceUnreachable")
            return
        }
        
        // Process file/URL bookmarks
        var failedCount = 0
        var fileUploadCount = 0
        for data in bookmarks {
            do {
                var isStale = false
                let url = try URL(resolvingBookmarkData: data, options: .withoutUI, relativeTo: nil, bookmarkDataIsStale: &isStale)
                switch shareService.shareFromExtension(url: url, to: device) {
                case .fileUploadQueued:    fileUploadCount += 1
                case .sentWithoutPayload:  break
                case .skipped:             failedCount += 1
                }
            } catch {
                failedCount += 1
                Logger.general.error("Failed to resolve bookmark: \(error, privacy: .public)")
            }
        }
        
        if failedCount > 0 {
            let message = failedCount == bookmarks.count
            ? "Soduto Share doesn't have permissions to read files in this directory. Drag the file to the menu bar icon to share!"
            : "\(failedCount) of \(bookmarks.count) items could not be shared."
            UserNotificationHelper.show(title: "Soduto Share", subtitle: "Oops! We got lost!", body: message, sound: true, id: "FileAccessDenied")
        }
        
        // Process shared texts
        for text in texts {
            shareService.shareFromExtension(text: text, to: device)
        }
        
        /// Report transfer status back to the extension.
        /// File uploads (with payloads) are tracked by ShareService — it reports the real completion status via Darwin notification when all uploads finish.
        /// Non-file transfers (URLs, text) complete immediately.
        if fileUploadCount > 0 {
            shareService.beginTrackingExtensionUploads(deviceId: deviceId, fileCount: fileUploadCount)
            // Don't report status yet — ShareService will when uploads actually complete
        } else if failedCount == bookmarks.count && !bookmarks.isEmpty && texts.isEmpty {
            // Everything failed, nothing was sent
            ShareService.reportExtensionTransferStatus(deviceId: deviceId, status: "failed")
        } else {
            // Only URLs/texts were shared (no file payloads) — they complete immediately
            ShareService.reportExtensionTransferStatus(deviceId: deviceId, status: "success")
        }
        
        // Clear consumed data (NOT transferStatuses — extension needs them)
        // Each device reads only its own transferStatus entry by ID. Old entries are inert and cleared on extension deinit
        AppDefaultsStore.ShareExtension.fileBookmarkData = nil
        AppDefaultsStore.ShareExtension.sharedTexts = nil
        AppDefaultsStore.ShareExtension.selectedDevice = nil
    }
}
