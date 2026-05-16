//
//  DevicePreferencesViewController.swift
//  Soduto
//
//  Created by Giedrius on 2017-07-22.
//  Copyright © 2017 Soduto. All rights reserved.
//

import Foundation
import Cocoa
import Sparkle

let updater = AppDelegate.shared().updaterController.updater

class DevicePreferencesViewController: NSViewController {
    
    // MARK: Properties
    
    var deviceDataSource: DeviceDataSource?
    var config: HostConfiguration?
    
    @IBOutlet weak var hostNameLabel: NSTextField!
    
    @IBOutlet weak var automaticCheckForUpdates: NSButton!
    @IBOutlet weak var disableSharePopUpCheckbox: NSButton!
    @IBOutlet weak var deviceTypeButton: NSPopUpButton!
    @IBOutlet weak var runCommandsButton: NSButton!
    
    private weak var deviceListController: DeviceListController?
    private var runCommandsWindowController: RunCommandsWindowController?
    
    
    // MARK: Public methods
    
    func refreshDeviceList() {
        self.deviceListController?.refreshDeviceList()
    }
    
    
    // MARK: NSViewController
    
    override func viewWillAppear() {
        super.viewWillAppear()
        
        if let hostName = config?.hostDeviceName {
            let label = NSMutableAttributedString(string: NSLocalizedString("This device is discoverable as", comment: "") + ":")
            label.addAttributes([
                NSAttributedString.Key.foregroundColor: NSColor.disabledControlTextColor,
                NSAttributedString.Key.font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
            ], range: NSMakeRange(0, label.length))
            label.append(NSAttributedString(string: "\n\(hostName)"))
            label.setAlignment(.center, range: NSMakeRange(0, label.length))
            self.hostNameLabel.attributedStringValue = label
        }
        else {
            self.hostNameLabel.stringValue = ""
        }
        
        if self.runCommandsButton != nil {
            self.runCommandsButton.isEnabled = true
            self.runCommandsButton.title = NSLocalizedString("Edit Run Commands", comment: "")
            self.runCommandsButton.action = #selector(openRunCommandsWindow(_:))
            self.runCommandsButton.target = self
        }
        
        self.deviceListController?.deviceDataSource = self.deviceDataSource
        self.deviceListController?.refreshDeviceList()
        self.loadPreferences()
        self.view.layoutSubtreeIfNeeded()
    }
    
    override func prepare(for segue: NSStoryboardSegue, sender: Any?) {
        if let deviceListController = segue.destinationController as? DeviceListController {
            self.deviceListController = deviceListController
        }
    }
    
    public func loadPreferences() {
        if self.disableSharePopUpCheckbox != nil {
            self.disableSharePopUpCheckbox.state = AppDefaultsStore.Preferences.disableSharePopUp ? NSButton.StateValue.on : NSButton.StateValue.off
        }
        if self.deviceTypeButton != nil {
            self.deviceTypeButton.selectItem(withTag: AppDefaultsStore.Preferences.deviceType)
        }
        if self.automaticCheckForUpdates != nil {
            self.automaticCheckForUpdates.state = updater.automaticallyChecksForUpdates ? NSButton.StateValue.on : NSButton.StateValue.off
        }
    }
    
    @IBAction func sharePopUp (_ sender: Any?) {
        AppDefaultsStore.Preferences.disableSharePopUp = disableSharePopUpCheckbox.state == .on
    }
    
    @IBAction func deviceTypeAction (_ sender: Any?) {
        let selectedIndex = self.deviceTypeButton.indexOfSelectedItem
        if selectedIndex >= 0 {
            AppDefaultsStore.Preferences.deviceType = selectedIndex
        }
    }
    
    @IBAction func autoCheckForUpdates (_ sender: Any?) {
        let checkBoxState = automaticCheckForUpdates.state
        let state: Bool = (checkBoxState == .on) ? true : false
        updater.automaticallyChecksForUpdates = state
    }
    
    @IBAction func openRunCommandsWindow(_ sender: Any?) {
        if runCommandsWindowController == nil {
            runCommandsWindowController = RunCommandsWindowController()
            runCommandsWindowController?.delegate = self
        }
        
        if let parentWindow = view.window {
            runCommandsWindowController?.presentAsSheet(in: parentWindow)
        } else {
            runCommandsWindowController?.showWindow(sender)
        }
    }
}

// MARK: - RunCommandsWindowControllerDelegate

extension DevicePreferencesViewController: RunCommandsWindowControllerDelegate {
    func getLocalCommands() -> [RunCommandService.Command]? {
        return runCommandService?.localCommands
    }
    
    func saveLocalCommands(_ commands: [RunCommandService.Command]) {
        runCommandService?.localCommands = commands
    }
    
    private var runCommandService: RunCommandService? {
        return AppDelegate.shared().serviceManager.service(ofType: RunCommandService.self)
    }
}
