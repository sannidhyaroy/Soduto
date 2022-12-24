//
//  DevicePreferencesViewController.swift
//  Soduto
//
//  Created by Giedrius on 2017-07-22.
//  Copyright © 2017 Soduto. All rights reserved.
//

import Foundation
import Cocoa

let preferencesUserDefaults = UserDefaults(suiteName: SharedUserDefaults.preferencesSuite)
var disableSharePopUp = UserDefaults.standard.bool(forKey: SharedUserDefaults.Preferences.disableSharePopUp)
var deviceTypeInt = preferencesUserDefaults?.integer(forKey: SharedUserDefaults.Preferences.deviceType) ?? 0

class DevicePreferencesViewController: NSViewController {
    
    // MARK: Properties
    
    var deviceDataSource: DeviceDataSource?
    var config: HostConfiguration?
    
    @IBOutlet weak var hostNameLabel: NSTextField!
    
    @IBOutlet weak var disableSharePopUpCheckbox: NSButton!
    @IBOutlet weak var deviceTypeButton: NSPopUpButton!
    
    private weak var deviceListController: DeviceListController?
    
    
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
                NSAttributedStringKey.foregroundColor: NSColor.disabledControlTextColor,
                NSAttributedStringKey.font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
                ], range: NSMakeRange(0, label.length))
            label.append(NSAttributedString(string: "\n\(hostName)"))
            label.setAlignment(.center, range: NSMakeRange(0, label.length))
            self.hostNameLabel.attributedStringValue = label
        }
        else {
            self.hostNameLabel.stringValue = ""
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
            self.disableSharePopUpCheckbox.state = disableSharePopUp ? NSButton.StateValue.on : NSButton.StateValue.off
        }
        if self.deviceTypeButton != nil {
            self.deviceTypeButton.selectItem(withTag: deviceTypeInt)
        }
    }
    
    @IBAction func sharePopUp (_ sender: Any?) {
        let checkBoxState = disableSharePopUpCheckbox.state
        let state: Bool = (checkBoxState == .on) ? true : false
        UserDefaults.standard.set(state, forKey: SharedUserDefaults.Preferences.disableSharePopUp)
        disableSharePopUp = state
        UserDefaults.standard.synchronize()
    }
    
    @IBAction func deviceTypeAction (_ sender: Any?) {
        let selectedIndex = self.deviceTypeButton.indexOfSelectedItem
        if selectedIndex >= 0 {
            preferencesUserDefaults?.set(selectedIndex, forKey: SharedUserDefaults.Preferences.deviceType)
            deviceTypeInt = selectedIndex
        } else {
            // No item selected
        }
        preferencesUserDefaults?.synchronize()
    }
}
