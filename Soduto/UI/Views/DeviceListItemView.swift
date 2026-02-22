//
//  DeviceListItemView.swift
//  Soduto
//
//  Created by Giedrius Stanevičius on 2016-09-01.
//  Copyright © 2016 Soduto. All rights reserved.
//

import Foundation
import Cocoa

public class DeviceListItemView: NSTableCellView {
    
    var device: Device? { didSet { updateInfo() } }
    var defaultTextString: String = "" { didSet { updateInfo() } }
    var defaultInfoString: String = "" { didSet { updateInfo() } }
    var defaultImage: NSImage? = nil { didSet { updateInfo() } }
    
    @IBOutlet weak var infoLabel: NSTextField?
    @IBOutlet weak var actionButton: NSButton?
    
    private lazy var infoButton: NSButton = {
        let button = NSButton(frame: NSRect(x: 0, y: 0, width: 24, height: 24))
        button.bezelStyle = .inline
        button.isBordered = false
        button.contentTintColor = NSColor.secondaryLabelColor
        button.image = NSImage(systemSymbolName: "info.circle", accessibilityDescription: "Info")
        button.imagePosition = .imageOnly
        button.target = self
        button.action = #selector(showDeviceInfo(_:))
        
        return button
    }()
    
    public override func awakeFromNib() {
        super.awakeFromNib()
        addInfoButton()
        applyActionButtonStyling()
    }
    
    private func addInfoButton() {
        // Add the info button next to the action button
        self.addSubview(infoButton)
        
        // Position the info button
        if let actionButton = self.actionButton {
            infoButton.translatesAutoresizingMaskIntoConstraints = false
            
            NSLayoutConstraint.activate([
                infoButton.centerYAnchor.constraint(equalTo: actionButton.centerYAnchor),
                infoButton.trailingAnchor.constraint(equalTo: actionButton.leadingAnchor, constant: -8),
                infoButton.widthAnchor.constraint(equalToConstant: 24),
                infoButton.heightAnchor.constraint(equalToConstant: 24)
            ])
        }
    }
    
    @IBAction func actionButtonAction(sender: NSButton) {
        guard let device = self.device else { return }
        
        switch device.pairingStatus {
        case .Unpaired:
            device.requestPairing()
            // Show the pairing window with verification code
            PairingWindowController.showOutgoingRequest(for: device)
        case .Paired:
            device.unpair()
        default:
            break
        }
    }
    
    @objc private func showDeviceInfo(_ sender: NSButton) {
        guard let device = self.device else { return }
        
        let controller = DeviceInfoWindowController.loadController()
        controller.device = device
        
        guard let window = controller.window,
              let parentWindow = self.window else { return }
        
        parentWindow.beginSheet(window) { _ in
            controller.window = nil // just to keep controller until sheet ends
        }
    }
    
    private func updateInfo() {
        if let device = self.device {
            self.textField?.stringValue = device.name
            self.textField?.alphaValue = device.isReachable ? 1.0 : 0.5
            
            let deviceTypeInfo: String = device.type != .Unknown ? NSLocalizedString(device.type.rawValue, comment: "Device type") : ""
            let deviceStatusInfo: String = device.isReachable ? NSLocalizedString("reachable", comment: "Device status") : NSLocalizedString("unreachable", comment: "Device status")
            self.infoLabel?.stringValue = deviceTypeInfo.isEmpty ? deviceStatusInfo : "\(deviceTypeInfo) - \(deviceStatusInfo)"
            self.infoLabel?.alphaValue = device.isReachable ? 0.8 : 0.4
            
            self.actionButton?.title = device.pairingStatus == .Paired ? NSLocalizedString("Unpair", comment: "action") : NSLocalizedString("Pair", comment: "action")
            self.actionButton?.isEnabled = device.pairingStatus != .Requested && device.pairingStatus != .RequestedByPeer
            self.actionButton?.isHidden = false
            
            self.imageView?.image = device.type.icon?.copy() as? NSImage
            self.imageView?.image?.isTemplate = true
            self.imageView?.alphaValue = device.isReachable ? 0.8 : 0.4
            
            // Show the info button for all devices
            self.infoButton.isHidden = false
        }
        else {
            self.textField?.stringValue = self.defaultTextString
            self.infoLabel?.stringValue = self.defaultInfoString
            self.actionButton?.isHidden = true
            self.imageView?.image = self.defaultImage
            
            // Hide the info button when there's no device
            self.infoButton.isHidden = true
        }
        
        applyActionButtonStyling()
    }
    
    private func applyActionButtonStyling() {
        if let actionButton = self.actionButton {
            actionButton.bezelStyle = .push
            actionButton.controlSize = .small
            actionButton.isBordered = true
            
            if #available(macOS 10.14, *) {
                actionButton.contentTintColor = NSColor.controlAccentColor
            }
        }
        
        infoButton.bezelStyle = .inline
        infoButton.isBordered = false
        infoButton.contentTintColor = NSColor.secondaryLabelColor
        infoButton.image = NSImage(systemSymbolName: "info.circle", accessibilityDescription: "Info")
        infoButton.imagePosition = .imageOnly
        
        if let textField = self.textField {
            textField.font = NSFont.systemFont(ofSize: NSFont.systemFontSize, weight: .medium)
            textField.textColor = .labelColor
        }
        
        if let infoLabel = self.infoLabel {
            infoLabel.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
            infoLabel.textColor = .secondaryLabelColor
        }
        
        self.imageView?.imageScaling = .scaleProportionallyUpOrDown
        if let imageView = self.imageView, let device = self.device {
            imageView.alphaValue = device.isReachable ? 0.8 : 0.4
        } else if let imageView = self.imageView {
            imageView.alphaValue = 0.4
        }
        if #available(macOS 10.14, *) {
            self.imageView?.contentTintColor = .labelColor
        }
    }
}

extension DeviceType {
    
    public var icon: NSImage? {
        switch self {
        case .Desktop: return #imageLiteral(resourceName: "desktopIcon")
        case .Laptop: return #imageLiteral(resourceName: "laptopIcon")
        case .Tablet: return #imageLiteral(resourceName: "tabletIcon")
        case .Phone: return #imageLiteral(resourceName: "phoneIcon")
        case .TV: return NSImage(systemSymbolName: "tv", accessibilityDescription: "TV")
        default: return nil
        }
    }
    
    /// SF Symbol name for this device type.
    public var sfSymbolName: String {
        switch self {
        case .Desktop: return "desktopcomputer"
        case .Laptop: return "laptopcomputer"
        case .Phone: return "iphone"
        case .Tablet: return "ipad"
        case .TV: return "tv"
        case .Unknown: return "display"
        }
    }
    
}
