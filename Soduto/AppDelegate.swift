//
//  AppDelegate.swift
//  Soduto
//
//  Created by Giedrius Stanevičius on 2016-07-06.
//  Copyright © 2016 Soduto. All rights reserved.
//

import Cocoa
import Foundation
import CleanroomLogger
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
    
    static let logLevelConfigurationKey = "com.soduto.logLevel"
    
    override init() {
        UserDefaults.standard.register(defaults: [AppDelegate.logLevelConfigurationKey: LogSeverity.info.rawValue])
        
#if DEBUG
        Log.enable(configuration: XcodeLogConfiguration(minimumSeverity: .debug, debugMode: true))
#else
        let formatter = FieldBasedLogFormatter(fields: [.severity(.simple), .delimiter(.spacedPipe), .payload])
        if let osRecorder = OSLogRecorder(formatters: [formatter]) {
            let severity: LogSeverity = LogSeverity(rawValue: UserDefaults.standard.integer(forKey: AppDelegate.logLevelConfigurationKey)) ?? .info
            Log.enable(configuration: BasicLogConfiguration(minimumSeverity: severity, recorders: [osRecorder]))
        }
#endif
        
        
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
        let notificationName = "com.Soduto.Share" as CFString
        let notificationCenter = CFNotificationCenterGetDarwinNotifyCenter()
        registerShareExtensionObserver(notificationCenter, notificationName)
        
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(wakeUpListener(_:)), name: NSWorkspace.didWakeNotification, object: nil)
        
        self.connectionProvider.start()
        
        showWelcomeWindow()
    }
    
    func applicationWillTerminate(_ aNotification: Notification) {
        // Insert code here to tear down your application
    }
    
    
    // MARK: DeviceManagerDelegate
    
    func deviceManager(_ manager: DeviceManager, didChangeDeviceState device: Device) {
        self.statusBarMenuController.refreshDeviceLists()
        self.welcomeWindowController?.refreshDeviceLists()
        self.updateValidDevices()
    }
    
    func deviceManager(_ manager: DeviceManager, didReceivePairingRequest request: PairingRequest, forDevice device: Device) {
        Log.debug?.message("deviceManager(<\(request)> didReceivePairingRequest:<\(request)> forDevice:<\(device)>)")
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
    
    public func updateValidDevices() {
        self.validDevices = deviceManager.pairedRechableDevices
        let deviceEntries: [[String: String]] = self.validDevices.map { [
            "id": $0.id,
            "name": $0.name
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
        
        guard let data = AppDefaultsStore.ShareExtension.fileBookmarkData else {
            UserNotificationHelper.show(title: "Soduto Share", body: "Could not read the file bookmark. Please try sharing again.", sound: true, id: "NoBookmarkData")
            return
        }
        
        do {
            var isStale = false
            let url = try URL(resolvingBookmarkData: data, options: .withoutUI, relativeTo: nil, bookmarkDataIsStale: &isStale)
            
            guard let shareService = self.serviceManager.service(ofType: ShareService.self) else {
                UserNotificationHelper.show(title: "Soduto Share", body: "Share service is not available. Please restart Soduto.", sound: true, id: "ShareServiceUnavailable")
                return
            }
            
            guard let device = self.deviceManager.device(withId: deviceId) else {
                UserNotificationHelper.show(title: "Soduto Share", body: "The selected device is no longer reachable.", sound: true, id: "DeviceUnreachable")
                return
            }
            
            shareService.uploadFileFromExtension(url: url, to: device)
        } catch {
            UserNotificationHelper.show(title: "Soduto Share", subtitle: "Oops! We got lost!", body: "Soduto Share doesn't have permissions to read files in this directory. Drag the file to the menu bar icon to share!", sound: true, id: "FileAccessDenied")
        }
    }
}
