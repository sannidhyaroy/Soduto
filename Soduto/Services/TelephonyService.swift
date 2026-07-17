//
//  TelephonyService.swift
//  Soduto
//
//  Created by Giedrius Stanevičius on 2016-12-05.
//  Copyright © 2016 Soduto. All rights reserved.
//

import Foundation
import Cocoa
import os
import UserNotifications
import AVFoundation
import CoreAudio
import MediaPlayer

/// Show notifications for phone call. Also allows to send SMS via the legacy
/// compose window (non-v2 devices only)
///
/// This service will display a notification each time a package with type
/// "kdeconnect.telephony" is received. The type of notification will change
/// depending on the contents of the field "event" (string).
///
/// Valid contents for "event" are: "ringing", "talking", "missedCall" and "sms".
/// Note that "sms" is ignored in this implementation, while the others (except
/// "talking" which drives the ongoing-call HUD instead) will display a system
/// notification.
///
/// If the incoming package contains a "phoneNumber" string field, the notification
/// will also display it. Note that "phoneNumber" can be a contact name instead
/// of an actual phone number.
///
/// If the incoming package contains "isCancel" set to true, the package is ignored.
public class TelephonyService: Service, UserNotificationActionHandler {
    
    // MARK: Types
    
    enum NotificationProperty: String {
        case deviceId = "com.soduto.services.telephony.notification.deviceId"
        case event = "com.soduto.services.telephony.notification.event"
        case phoneNumber = "com.soduto.services.telephony.notification.phoneNumber"
        case contactName = "com.soduto.services.telephony.notification.contactName"
        case originalMessage = "com.soduto.services.telephony.notification.originalMessage"
    }
    
    enum ActionId: ServiceAction.Id {
        case sendSms
    }
    
    // MARK: Private properties
    
    let un = UNUserNotificationCenter.current()
    
    private var pendingSMSPackets: [String:([DataPacket], Timer)] = [:]
    private lazy var sendMessageController = SendMessageWindowController.loadController()
    private let mediaController = SystemMediaController.shared
    
    /// IDs of devices for which this service is currently set up
    private var connectedDeviceIds = Set<String>()
    
    /// ID of the device whose active-call HUD is currently on screen, if any
    private var activeCallToastDeviceId: String? = nil
    
    
    // MARK: Service properties
    
    public static let serviceId: Service.Id = "com.soduto.services.telephony"
    
    public let incomingCapabilities = Set<Service.Capability>([ DataPacket.telephonyPacketType ])
    public let outgoingCapabilities = Set<Service.Capability>([ DataPacket.telephonyMuteRequestPacketType, DataPacket.smsRequestPacketType ])
    
    
    // MARK: Service methods
    
    public func handleDataPacket(_ dataPacket: DataPacket, fromDevice device: Device, onConnection connection: Connection) -> Bool {
        guard dataPacket.isTelephonyPacket else { return false }
        
        #if DEBUG
            Logger.services.debug("handleDataPacket(<\(dataPacket, privacy: .public)> fromDevice:<\(device, privacy: .public)>)")
        #else
            Logger.services.debug("handleDataPacket(type: \(dataPacket.type, privacy: .public), id: \(dataPacket.id, privacy: .public)) from device: \(device.id, privacy: .public)")
        #endif
        
        do {
            if try dataPacket.getCancelFlag() {
                self.hideNotification(for: dataPacket, from: device)
                self.dismissOngoingCallHUD(for: device)
                Logger.services.debug("Telephony::isCancel, requesting media resume (pausedByController=\(self.mediaController.pausedByController, privacy: .public))")
                self.mediaController.resume()
                Logger.services.debug("Telephony::isCancel, after media resume request (pausedByController=\(self.mediaController.pausedByController, privacy: .public))")
            }
            else if let event = try dataPacket.getEvent() ?? nil {
                switch event {
                case DataPacket.TelephonyEvent.ringing.rawValue:
                    self.showRingingNotification(for: dataPacket, from: device)
                    break
                case DataPacket.TelephonyEvent.missedCall.rawValue:
                    self.showMissedCallNotification(for: dataPacket, from: device)
                    break
                case DataPacket.TelephonyEvent.talking.rawValue:
                    self.hideNotification(for: dataPacket, from: device)
                    self.showOngoingCallHUD(for: dataPacket, from: device)
                    Logger.services.debug("Telephony::talking, requesting media pause (pausedByController=\(self.mediaController.pausedByController, privacy: .public))")
                    self.mediaController.pause()
                    Logger.services.debug("Telephony::talking, after media pause request (pausedByController=\(self.mediaController.pausedByController, privacy: .public))")
                    break
                case DataPacket.TelephonyEvent.sms.rawValue:
                    // Drop the legacy `event:"sms"` path entirely that matches KDE Desktop (telephonyplugin.cpp:82 "ignore old style sms packet").
                    // SMS notifications come through `NotificationsService` (mirroring the Android SMS app's system notification), and SMS reply / browsing is handled by `SMSService`.
                    // Telephony stays as the path for call events (ringing, missedCall, talking) only.
                    Logger.services.debug("Telephony::sms ignored (handled by NotificationsService + SMSService)")
                    break
                default:
                    Logger.services.error("Unknown telephony event type: \(event, privacy: .public)")
                    break
                }
            }
        }
        catch {
            Logger.services.error("Error while handling telephony packet: \(error, privacy: .public)")
        }
        
        return true
    }
    
    public func setup(for device: Device) {
        connectedDeviceIds.insert(device.id)
    }
    
    public func cleanup(for device: Device) {
        connectedDeviceIds.remove(device.id)
    }
    
    public func actions(for device: Device) -> [ServiceAction] {
        guard device.incomingCapabilities.contains(DataPacket.smsRequestPacketType) else { return [] }
        guard device.pairingStatus == .Paired else { return [] }
        // SMS Protocol v2-capable phones get the proper "Messages" entry from `SMSService`
        // Don't duplicate it with the legacy one-shot "Send SMS" compose window here
        guard !SMSService.deviceSupportsV2SMS(device) else { return [] }
        
        return [
            ServiceAction(id: ActionId.sendSms.rawValue, title: "Send SMS", description: "Send text messages from the desktop", service: self, device: device)
        ]
    }
    
    public func performAction(_ id: ServiceAction.Id, forDevice device: Device, userInfo: [String: Any]?) {
        guard let actionId = ActionId(rawValue: id) else { return }
        guard device.pairingStatus == .Paired else { return }
        
        switch actionId {
        case .sendSms:
            // Only reachable for non-v2 devices as SMS Protocol v2-capable phones are filtered out in `actions(for:)` and instead get `SMSService`'s "Messages" entry
            // Keeps the legacy one-shot compose dialog alive for older Android KDE Connect clients
            sendMessageController.sendActionHandler = { controller in
                controller.sendActionHandler = nil
                controller.window?.close()
                guard device.pairingStatus == .Paired else { return }
                guard let message = controller.messageBody else { return }
                for phoneNumber in controller.phoneNumbers {
                    let packet = DataPacket.smsRequestPacket(phoneNumber: phoneNumber, message: message)
                    device.send(packet)
                }
            }
            sendMessageController.clear()
            sendMessageController.showWindow(self)
            break
        }
    }
    
    
    // MARK: UserNotificationActionHandler
    
    /// Handles user responses to telephony notification actions.
    ///
    /// Supports the following actions:
    /// - **Ringing**: Mutes the incoming call on the remote device
    /// - **SMS**: Sends the user's reply text to the phone number
    public static func handleAction(for response: UNNotificationResponse, context: UserNotificationContext) {
        guard let userInfo = response.notification.request.content.userInfo as [AnyHashable: Any]? else { return }
        guard let deviceId = userInfo[NotificationProperty.deviceId.rawValue] as? String else { return }
        guard let device = context.deviceManager.device(withId: deviceId) else { return }
        guard device.pairingStatus == .Paired else { return }
        guard let event = userInfo[NotificationProperty.event.rawValue] as? String else { return }
        
        switch event {
        case DataPacket.TelephonyEvent.ringing.rawValue:
            if response.actionIdentifier == "mutecall" {
                device.send(DataPacket.mutePhonePacket())
            }
        case DataPacket.TelephonyEvent.sms.rawValue:
            // Legacy SMS reply path, unreachable now that the `event:"sms"` notification is no longer created
            // Kept as a defensive no-op in case an old delivered notification still triggers this codepath after an update
            break
        default:
            break
        }
    }
    
    // MARK: Private methods
    
    /// Returns a notification attachment using the contact's photo from the packet when available,
    /// falling back to a named image from the app bundle.
    private func notificationAttachment(for dataPacket: DataPacket, fallbackImageName: String, identifier: String) -> UNNotificationAttachment? {
        if let image = try? dataPacket.getPhoneThumbnail(),
           let tiff = image.tiffRepresentation,
           let bitmap = NSBitmapImageRep(data: tiff),
           let jpeg = bitmap.representation(using: .jpeg, properties: [.compressionFactor: NSNumber(value: 0.9)]) {
            let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(identifier).appendingPathExtension("jpg")
            do {
                try jpeg.write(to: tempURL)
                // Do NOT delete `tempURL` here
                // UNNotificationAttachment on macOS stores a reference to the file rather than copying it eagerly. The OS cleans `/tmp`.
                return try UNNotificationAttachment(identifier: identifier, url: tempURL)
            } catch {
                Logger.services.error("Failed to create contact photo attachment: \(error, privacy: .public)")
            }
        }
        guard let iconPath = Bundle.main.pathForImageResource(NSImage.Name(fallbackImageName)) else { return nil }
        do {
            return try UNNotificationAttachment(identifier: identifier, url: URL(fileURLWithPath: iconPath))
        } catch {
            Logger.services.error("Failed to create fallback icon attachment (\(fallbackImageName, privacy: .public)): \(error, privacy: .public)")
            return nil
        }
    }
    
    /// Shows a persistent HUD toast indicating an active call
    private func showOngoingCallHUD(for dataPacket: DataPacket, from device: Device) {
        let contactName = (try? dataPacket.getContactName())?.trimmingCharacters(in: .whitespacesAndNewlines)
        let phoneNumber = (try? dataPacket.getPhoneNumber())?.trimmingCharacters(in: .whitespacesAndNewlines)
        let caller = [contactName, phoneNumber].compactMap { $0 }.first { !$0.isEmpty }
        
        let isMultiDevice = connectedDeviceIds.count > 1
        let message: String
        if let caller {
            message = isMultiDevice ? "On a call with \(caller) · \(device.name)" : "On a call with \(caller)"
        } else {
            message = isMultiDevice ? "On an active call · \(device.name)" : "On an active call"
        }
        
        var style = HUDToast.Style.success
        style.symbolName = "phone.badge.waveform.fill"
        
        activeCallToastDeviceId = device.id
        MainActor.assumeIsolated {
            HUDToast.show(message, style: style)
        }
    }
    
    /// Dismisses the active-call HUD if it belongs to the given device
    private func dismissOngoingCallHUD(for device: Device) {
        guard activeCallToastDeviceId == device.id else { return }
        activeCallToastDeviceId = nil
        MainActor.assumeIsolated {
            HUDToast.dismiss()
        }
    }
    
    private func notificationId(for dataPacket: DataPacket, from device: Device) -> String? {
        guard dataPacket.isTelephonyPacket else { return nil }
        guard (try? dataPacket.getEvent()) != nil else { return nil }
        
        guard let deviceId = device.id.addingPercentEncoding(withAllowedCharacters: .alphanumerics) else { return nil }
        guard let event = (try? dataPacket.getEvent() ?? nil) else { return nil }
        
        if event == DataPacket.TelephonyEvent.sms.rawValue {
            // For SMS notifications we want them to be uniqueue per contact
            // TODO: or should it be unique per message?
            let phoneNumber = (try? dataPacket.getPhoneNumber())??.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "unknownPhoneNumber"
            return "\(self.id).\(deviceId).sms.\(phoneNumber)"
        }
        else {
            // For calling notifications we use ids unique per device
            return "\(self.id).\(deviceId).call"
        }
    }
    
    private func showRingingNotification(for dataPacket: DataPacket, from device: Device) {
        guard dataPacket.isTelephonyPacket else { return }
        guard (try? dataPacket.getEvent()) == DataPacket.TelephonyEvent.ringing.rawValue else { return }
        
        do {
            guard let notificationId = self.notificationId(for: dataPacket, from: device) else { return }
            let phoneNumber = try dataPacket.getPhoneNumber() ?? "Unknown Number"
            let contactName = try dataPacket.getContactName() ?? phoneNumber
            let displayName = contactName.trimmingCharacters(in: .whitespacesAndNewlines)
            
            let notification = UNMutableNotificationContent()
            notification.userInfo = [
                NotificationProperty.deviceId.rawValue: device.id,
                NotificationProperty.event.rawValue: DataPacket.TelephonyEvent.ringing.rawValue,
                UserNotificationManager.Property.actionHandlerClass.rawValue: NSStringFromClass(TelephonyService.self)
            ]
            notification.title = device.name
            notification.subtitle = displayName.isEmpty ? "Incoming call" : "Incoming call from \(displayName)"
            notification.sound = .default
            notification.categoryIdentifier = "IncomingCall"
            notification.threadIdentifier = "telephony"
            notification.setUrgency(.timeSensitive)
            
            if let attachment = notificationAttachment(for: dataPacket, fallbackImageName: "Phone", identifier: notificationId) {
                notification.attachments = [attachment]
            }
            
            let request = UNNotificationRequest(identifier: notificationId, content: notification, trigger: nil)
            un.add(request) { error in
                if let error = error {
                    Logger.services.error("Failed to add ringing notification request: \(error, privacy: .public)")
                }
            }
            
            Logger.services.debug("Ringing notification shown: \(notificationId, privacy: .public)")
        }
        catch {
            Logger.services.error("Error while showing ringing notification: \(error, privacy: .public)")
        }
    }
    
    private func showMissedCallNotification(for dataPacket: DataPacket, from device: Device) {
        guard dataPacket.isTelephonyPacket else { return }
        guard (try? dataPacket.getEvent()) == DataPacket.TelephonyEvent.missedCall.rawValue else { return }
        
        do {
            guard let notificationId = self.notificationId(for: dataPacket, from: device) else { return }
            let phoneNumber = try dataPacket.getPhoneNumber() ?? "Unknown Number"
            let contactName = try dataPacket.getContactName()
            let displayName = contactName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? phoneNumber
            
            let notification = UNMutableNotificationContent()
            notification.title = device.name
            notification.subtitle = "Missed a call from \(displayName)"
            notification.sound = .default
            notification.threadIdentifier = "telephony"
            notification.setUrgency(.active)
            
            if let attachment = notificationAttachment(for: dataPacket, fallbackImageName: "Phone", identifier: notificationId) {
                notification.attachments = [attachment]
            }
            
            let request = UNNotificationRequest(identifier: notificationId, content: notification, trigger: nil)
            un.add(request) { error in
                if let error = error {
                    Logger.services.error("Failed to add missed call notification request: \(error, privacy: .public)")
                }
            }
            
            Logger.services.debug("Missed call notification shown: \(notificationId, privacy: .public)")
        }
        catch {
            Logger.services.error("Error while showing missed call notification: \(error, privacy: .public)")
        }
    }
    
    private func showSmsNotification(for dataPacket: DataPacket, from device: Device) {
        guard dataPacket.isTelephonyPacket else { return }
        guard (try? dataPacket.getEvent()) == DataPacket.TelephonyEvent.sms.rawValue else { return }
        
        do {
            guard let notificationId = self.notificationId(for: dataPacket, from: device) else { return }
            
            // One SMS might come in chunks - try concating them together.
            // However if time from last notification is big enough - add a new line when concatening - they probably are
            // separate messages
            let hasPhoneNumber = try dataPacket.getPhoneNumber() != nil
            let phoneNumber = try dataPacket.getPhoneNumber() ?? "Unknown Number"
            let contactName = try dataPacket.getContactName()
            let displayName = contactName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? phoneNumber
            var messageBody = try dataPacket.getMessageBody() ?? ""
            
            self.un.getDeliveredNotifications { deliveredNotifications in
                for deliveredNotification in deliveredNotifications {
                    if deliveredNotification.request.identifier == notificationId {
                        let lastNotification = deliveredNotification
                        let lastNotificationIsOld = lastNotification.date.timeIntervalSinceNow < -10.0
                        let lastMessageBody = lastNotification.request.content.body + (lastNotificationIsOld ? "\n" : "")
                        messageBody = lastMessageBody + messageBody
                        self.un.removeDeliveredNotifications(withIdentifiers: [notificationId])
                        break
                    }
                }
                
                let notification = UNMutableNotificationContent()
                notification.userInfo = [
                    NotificationProperty.deviceId.rawValue: device.id,
                    NotificationProperty.event.rawValue: DataPacket.TelephonyEvent.sms.rawValue,
                    NotificationProperty.phoneNumber.rawValue: phoneNumber,
                    UserNotificationManager.Property.actionHandlerClass.rawValue: NSStringFromClass(TelephonyService.self)
                ]
                notification.title = device.name
                notification.subtitle = displayName.isEmpty ? "New SMS message" : "SMS from \(displayName)"
                notification.body = messageBody
                notification.sound = .default
                notification.threadIdentifier = "telephony"
                notification.setUrgency(.active)
                
                if let iconPath = Bundle.main.pathForImageResource(NSImage.Name("Messages")) {
                    let notificationIconURL = URL(fileURLWithPath: iconPath)
                    do {
                        let attachment = try UNNotificationAttachment(identifier: notificationId, url: notificationIconURL, options: nil)
                        notification.attachments = [attachment]
                    } catch {
                        Logger.services.error("Failed to create SMS notification attachment: \(error, privacy: .public)")
                    }
                }
                
                if hasPhoneNumber {
                    notification.categoryIdentifier = "SMSReceived"
                }
                
                let request = UNNotificationRequest(identifier: notificationId, content: notification, trigger: nil)
                self.un.add(request) { error in
                    if let error = error {
                        Logger.services.error("Failed to add SMS notification request: \(error, privacy: .public)")
                    }
                }
                
                Logger.services.debug("SMS notification shown: \(notificationId, privacy: .public)")
            }
        }
        catch {
            Logger.services.error("Error while showing sms notification: \(error, privacy: .public)")
        }
    }
    
    private func hideNotification(for dataPacket: DataPacket, from device: Device) {
        assert(dataPacket.isTelephonyPacket, "Expected telephony data packet")
        
        guard let id = self.notificationId(for: dataPacket, from: device) else { return }
        un.removeNotification(withId: id)
        
        Logger.services.debug("Notification hidden: \(id, privacy: .public)")
    }
    
    private func handleSMSPacket(_ packet: DataPacket, from device: Device) {
        // One SMS might come in chunks - try waiting for all chunks before showing notification.
        // Although showSmsNotification(for:from) also performs concatenation, it is not enough.
        // Packets may come out of order - the case that is not handled by showSmsNotification(for:from)
        // So we are dealing with the later here
        
        guard let id = notificationId(for: packet, from: device) else { return }
        
        var packets: [DataPacket] = []
        if let (prevPackets, prevTimer) = pendingSMSPackets[id] {
            prevTimer.invalidate()
            packets = prevPackets
        }
        packets.append(packet)
        
        let timer = Timer.compatScheduledTimer(withTimeInterval: 5.0, repeats: false) { _ in
            do {
                guard let (prevPackets, _) = self.pendingSMSPackets.removeValue(forKey: id) else { return }
                
                let sortedPackets = prevPackets.sorted(by: { (packet1, packet2) -> Bool in
                    return packet1.id < packet2.id
                })
                let messages = try sortedPackets.map { try $0.getMessageBody() ?? "" }
                let concatenedMessage = messages.joined()
                
                guard let lastPacket = sortedPackets.last else { return }
                
                var packet = lastPacket
                var body = packet.body
                body[DataPacket.TelephonyProperty.messageBody.rawValue] = concatenedMessage as AnyObject
                packet.body = body
                
                self.showSmsNotification(for: packet, from: device)
            }
            catch {
                Logger.services.error("Failed to handle SMS packets: \(error, privacy: .public)")
            }
        }
        
        pendingSMSPackets[id] = (packets, timer)
    }
    
}


// MARK: - DataPacket (Telephony)

/// Telephony service data packet utilities
fileprivate extension DataPacket {
    
    // MARK: Types
    
    enum TelephonyError: Error {
        case wrongType
        case invalidEvent
        case invalidPhoneNumber
        case invalidContactName
        case invalidMessageBody
        case invalidPhoneThumbnail
        case invalidCancelFlag
    }
    
    enum TelephonyEvent: String {
        case sms = "sms"
        case ringing = "ringing"
        case missedCall = "missedCall"
        case talking = "talking"
    }
    
    enum TelephonyProperty: String {
        case event = "event"                    // (string): can be one of TelephonyEvent values
        case phoneNumber = "phoneNumber"        // (string)
        case contactName = "contactName"        // (string)
        case messageBody = "messageBody"        // (string)
        case phoneThumbnail = "phoneThumbnail"  // (base64 JPEG)
        case sendSms = "sendSms"                // (boolean): true to send sms
        case isCancel = "isCancel"              // (boolean): cancel previous event
    }
    
    
    // MARK: Properties
    
    static let telephonyPacketType = "kdeconnect.telephony"
    static let telephonyMuteRequestPacketType = "kdeconnect.telephony.request_mute"
    static let smsRequestPacketType = "kdeconnect.sms.request"
    
    var isTelephonyPacket: Bool { return self.type == DataPacket.telephonyPacketType }
    
    var isTelephonyMuteRequestPacket: Bool { return self.type == DataPacket.telephonyMuteRequestPacketType }
    
    var isSmsRequestPacket: Bool { return self.type == DataPacket.smsRequestPacketType }
    
    
    // MARK: Public static methods
    
    static func smsRequestPacket(phoneNumber: String, message: String) -> DataPacket {
        return DataPacket(type: smsRequestPacketType, body: [
            TelephonyProperty.sendSms.rawValue: NSNumber(value: true),
            TelephonyProperty.phoneNumber.rawValue: phoneNumber as AnyObject,
            TelephonyProperty.messageBody.rawValue: message as AnyObject
        ])
    }
    
    static func mutePhonePacket() -> DataPacket {
        return DataPacket(type: telephonyMuteRequestPacketType, body: [:])
    }
    
    
    // MARK: Public methods
    
    func getEvent() throws -> String? {
        try self.validateTelephonyType()
        guard body.keys.contains(TelephonyProperty.event.rawValue) else { return nil }
        guard let value = body[TelephonyProperty.event.rawValue] as? String else { throw TelephonyError.invalidEvent }
        return value
    }
    
    func getPhoneNumber() throws -> String? {
        try self.validateTelephonyOrSmsRequestType()
        guard body.keys.contains(TelephonyProperty.phoneNumber.rawValue) else { return nil }
        guard let value = body[TelephonyProperty.phoneNumber.rawValue] as? String else { throw TelephonyError.invalidPhoneNumber }
        return value
    }
    
    func getContactName() throws -> String? {
        try self.validateTelephonyType()
        guard body.keys.contains(TelephonyProperty.contactName.rawValue) else { return nil }
        guard let value = body[TelephonyProperty.contactName.rawValue] as? String else { throw TelephonyError.invalidContactName }
        return value
    }
    
    func getMessageBody() throws -> String? {
        try self.validateTelephonyOrSmsRequestType()
        guard body.keys.contains(TelephonyProperty.messageBody.rawValue) else { return nil }
        guard let value = body[TelephonyProperty.messageBody.rawValue] as? String else { throw TelephonyError.invalidMessageBody }
        return value
    }
    
    func getPhoneThumbnail() throws -> NSImage? {
        try self.validateTelephonyType()
        guard body.keys.contains(TelephonyProperty.phoneThumbnail.rawValue) else { return nil }
        guard let base64String = body[TelephonyProperty.phoneThumbnail.rawValue] as? String else { throw TelephonyError.invalidPhoneThumbnail }
        guard let data = Data(base64Encoded: base64String, options: .ignoreUnknownCharacters) else { throw TelephonyError.invalidPhoneThumbnail }
        guard let image = NSImage(data: data) else { throw TelephonyError.invalidPhoneThumbnail }
        return image
    }
    
    func getCancelFlag() throws -> Bool {
        // Cancel flag might be (and actually is!) string instead of bool - handling both cases
        try self.validateTelephonyType()
        guard body.keys.contains(TelephonyProperty.isCancel.rawValue) else { return false }
        let stringValue = body[TelephonyProperty.isCancel.rawValue] as? String
        let boolValue: Bool? = (stringValue != nil) ? Bool(stringValue!) : (body[TelephonyProperty.isCancel.rawValue] as? NSNumber)?.boolValue
        guard let value = boolValue else { throw TelephonyError.invalidCancelFlag }
        return value
    }
    
    func validateTelephonyType() throws {
        guard self.isTelephonyPacket else { throw TelephonyError.wrongType }
    }
    
    func validateTelephonyOrSmsRequestType() throws {
        guard self.isTelephonyPacket || self.isSmsRequestPacket else { throw TelephonyError.wrongType }
    }
}
