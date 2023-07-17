//
//  TelephonyService.swift
//  Soduto
//
//  Created by Giedrius Stanevičius on 2016-12-05.
//  Copyright © 2016 Soduto. All rights reserved.
//

import Foundation
import Cocoa
import CleanroomLogger
import UserNotifications

/// Show notifications for phone call or SMS events. Also allows to send SMS
///
/// This service will display a notification each time a package with type
/// "kdeconnect.telephony" is received. The type of notification will change
/// depending on the contents of the field "event" (string).
///
/// Valid contents for "event" are: "ringing", "talking", "missedCall" and "sms".
/// Note that "talking" is just ignored in this implementation, while the others
/// will display a system notification.
///
/// If the incoming package contains a "phoneNumber" string field, the notification
/// will also display it. Note that "phoneNumber" can be a contact name instead
/// of an actual phone number.
///
/// If the incoming package contains "isCancel" set to true, the package is ignored.
public class TelephonyService: Service, UserNotificationActionHandler {
    
    let un = UNUserNotificationCenter.current()
    
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
    
    private var pendingSMSPackets: [NSUserNotification.Id:([DataPacket], Timer)] = [:]
    private lazy var sendMessageController = SendMessageWindowController.loadController()
    
    
    // MARK: Service properties
    
    public static let serviceId: Service.Id = "com.soduto.services.telephony"
    
    public let incomingCapabilities = Set<Service.Capability>([ DataPacket.telephonyPacketType ])
    public let outgoingCapabilities = Set<Service.Capability>([ DataPacket.telephonyRequestPacketType, DataPacket.smsRequestPacketType ])
    
    
    // MARK: Service methods
    
    public func handleDataPacket(_ dataPacket: DataPacket, fromDevice device: Device, onConnection connection: Connection) -> Bool {
        
        guard dataPacket.isTelephonyPacket else { return false }
        
        Log.debug?.message("handleDataPacket(<\(dataPacket)> fromDevice:<\(device)> onConnection:<\(connection)>)")
        
        do {
            if try dataPacket.getCancelFlag() {
                self.hideNotification(for: dataPacket, from: device)
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
                    break
                case DataPacket.TelephonyEvent.sms.rawValue:
                    self.handleSMSPacket(dataPacket, from: device)
                    break
                default:
                    Log.error?.message("Unknown telephony event type: \(event)")
                    break
                }
            }
        }
        catch {
            Log.error?.message("Error while handling telephony packet: \(error)")
        }
        
        return true
    }
    
    public func setup(for device: Device) {}
    
    public func cleanup(for device: Device) {}
    
    public func actions(for device: Device) -> [ServiceAction] {
        guard device.incomingCapabilities.contains(DataPacket.smsRequestPacketType) else { return [] }
        guard device.pairingStatus == .Paired else { return [] }
        
        return [
            ServiceAction(id: ActionId.sendSms.rawValue, title: "Send SMS", description: "Send text messages from the desktop", service: self, device: device)
        ]
    }
    
    public func performAction(_ id: ServiceAction.Id, forDevice device: Device) {
        guard let actionId = ActionId(rawValue: id) else { return }
        guard device.pairingStatus == .Paired else { return }
        
        switch actionId {
        case .sendSms:
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
    
    public static func handleAction(for notification: NSUserNotification, context: UserNotificationContext) {
        guard let userInfo = notification.userInfo else { return }
        guard let deviceId = userInfo[NotificationProperty.deviceId.rawValue] as? String else { return }
        guard let device = context.deviceManager.device(withId: deviceId) else { return }
        guard device.pairingStatus == .Paired else { return }
        guard let event = userInfo[NotificationProperty.event.rawValue] as? String else { return }
        
        switch event {
        case DataPacket.TelephonyEvent.ringing.rawValue:
            guard notification.activationType == .actionButtonClicked else { break }
            device.send(DataPacket.mutePhonePacket())
            break
        case DataPacket.TelephonyEvent.sms.rawValue:
            guard notification.activationType == .replied else { break }
            guard let response = notification.response?.string else { break }
            guard let phoneNumber = userInfo[NotificationProperty.phoneNumber.rawValue] as? String else { break }
            device.send(DataPacket.smsRequestPacket(phoneNumber: phoneNumber, message: response))
            break
        default:
            break
        }
    }
    
    public static func handleMuteAction(for notification: UNNotificationResponse, context: UserNotificationContext) {
        guard let userInfo = notification.notification.request.content.userInfo as [AnyHashable: Any]? else { return }
        guard let deviceId = userInfo[NotificationProperty.deviceId.rawValue] as? String else { return }
        guard let device = context.deviceManager.device(withId: deviceId) else { return }
        guard device.pairingStatus == .Paired else { return }
        device.send(DataPacket.mutePhonePacket())
    }
    
    public static func handleReplySMSAction(for notification: UNNotificationResponse, context: UserNotificationContext) {
        guard let userInfo = notification.notification.request.content.userInfo as [AnyHashable: Any]? else { return }
        guard let deviceId = userInfo[NotificationProperty.deviceId.rawValue] as? String else { return }
        guard let device = context.deviceManager.device(withId: deviceId) else { return }
        guard device.pairingStatus == .Paired else { return }
        if notification.actionIdentifier == "reply" {
            if let response = notification as? UNTextInputNotificationResponse {
                let responseText = response.userText
                guard let phoneNumber = userInfo[NotificationProperty.phoneNumber.rawValue] as? String else { return }
                device.send(DataPacket.smsRequestPacket(phoneNumber: phoneNumber, message: responseText))
            }
        }
    }
    
    // MARK: Private methods
    
    private func notificationId(for dataPacket: DataPacket, from device: Device) -> NSUserNotification.Id? {
        assert(dataPacket.isTelephonyPacket, "Expected telephony data packet")
        assert(try! dataPacket.getEvent() != nil, "Expected telephony event property")
        
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
        assert(dataPacket.isTelephonyPacket, "Expected telephony data packet")
        assert(try! dataPacket.getEvent() == DataPacket.TelephonyEvent.ringing.rawValue, "Expected 'ringing' event type")
        
        do {
            guard let notificationId = self.notificationId(for: dataPacket, from: device) else { return }
            let phoneNumber = try dataPacket.getPhoneNumber() ?? "unknown number"
            let contactName = try dataPacket.getContactName() ?? phoneNumber
            let thumbnail = (try? dataPacket.getPhoneThumbnail() ?? nil) ?? nil
            
            if #available(macOS 11.0, *) {
                un.requestAuthorization(options: [.alert, .sound]) { (authorized, error) in
                    if authorized {
                        print("Authorized to send notifications!")
                    } else if !authorized {
                        print("Not authorized to send notifications")
                    } else {
                        print(error?.localizedDescription as Any)
                    }
                }
                un.getNotificationSettings { (settings) in
                    if settings.authorizationStatus == .authorized {
                        let notification = UNMutableNotificationContent()
                        var userInfo = notification.userInfo
                        userInfo[NotificationProperty.deviceId.rawValue] = device.id as AnyObject
                        userInfo[NotificationProperty.event.rawValue] = DataPacket.TelephonyEvent.ringing.rawValue as AnyObject
                        notification.userInfo = userInfo
                        notification.title = "Incoming call from \(contactName)"
                        notification.subtitle = device.name
                        
                        let notificationIconPath = Bundle.main.pathForImageResource(NSImage.Name("Phone"))
                        if (notificationIconPath != nil) {
                            let notificationIconURL = URL(fileURLWithPath: notificationIconPath!)
                            do {
                                let attachment = try UNNotificationAttachment.init(identifier: notificationId, url: notificationIconURL, options: .none)
                                notification.attachments = [attachment]
                            }
                            catch let error {
                                print(error.localizedDescription)
                            }
                        }
                        
                        notification.sound = UNNotificationSound.default()
                        notification.categoryIdentifier = "IncomingCall"
                        let id = notificationId
                        let mutecall = UNNotificationAction(identifier: "mutecall", title: "Mute call")
                        let category = UNNotificationCategory(identifier: "IncomingCall", actions: [mutecall], intentIdentifiers: [], options: [])
                        //let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)
                        let request = UNNotificationRequest(identifier: id, content: notification, trigger: nil)
                        self.un.setNotificationCategories([category])
                        self.un.add(request){ (error) in
                            if error != nil {print(error?.localizedDescription as Any)}
                        }
                    } else {
                        Log.debug?.message("Soduto isn't authorized to send notifications!")
                    }
                }
            } else {
                let notification = NSUserNotification(actionHandlerClass: type(of: self))
                var userInfo = notification.userInfo
                userInfo?[NotificationProperty.deviceId.rawValue] = device.id as AnyObject
                userInfo?[NotificationProperty.event.rawValue] = DataPacket.TelephonyEvent.ringing.rawValue as AnyObject
                notification.userInfo = userInfo
                notification.title = "Incoming call from \(contactName)"
                notification.subtitle = device.name
                notification.contentImage = thumbnail
                notification.soundName = NSUserNotificationDefaultSoundName
                notification.hasActionButton = true
                notification.actionButtonTitle = "Mute call"
                notification.identifier = notificationId
                NSUserNotificationCenter.default.scheduleNotification(notification)
                
                Log.debug?.message("Ringing notification shown: \(String(describing: notification.identifier))")
            }
        }
        catch {
            Log.error?.message("Error while showing ringing notification: \(error)")
        }
    }
    
    private func showMissedCallNotification(for dataPacket: DataPacket, from device: Device) {
        assert(dataPacket.isTelephonyPacket, "Expected telephony data packet")
        assert(try! dataPacket.getEvent() == DataPacket.TelephonyEvent.missedCall.rawValue, "Expected 'missedCall' event type")
        
        do {
            guard let notificationId = self.notificationId(for: dataPacket, from: device) else { return }
            let phoneNumber = try dataPacket.getPhoneNumber() ?? "unknown number"
            let contactName = try dataPacket.getContactName() ?? phoneNumber
            let thumbnail = (try? dataPacket.getPhoneThumbnail() ?? nil) ?? nil
            
            let notification = NSUserNotification()
            notification.title = "Missed a call from \(contactName)"
            notification.subtitle = device.name
            notification.contentImage = thumbnail
            notification.soundName = NSUserNotificationDefaultSoundName
            notification.hasActionButton = false
            notification.identifier = notificationId
            NSUserNotificationCenter.default.scheduleNotification(notification)
            
            Log.debug?.message("Missed call notification shown: \(String(describing: notification.identifier))")
        }
        catch {
            Log.error?.message("Error while showing missed call notification: \(error)")
        }
    }
    
    private func showSmsNotification(for dataPacket: DataPacket, from device: Device) {
        assert(dataPacket.isTelephonyPacket, "Expected telephony data packet")
        assert(try! dataPacket.getEvent() == DataPacket.TelephonyEvent.sms.rawValue, "Expected 'sms' event type")
        
        do {
            guard let notificationId = self.notificationId(for: dataPacket, from: device) else { return }
            
            // One SMS might come in chunks - try concating them together.
            // However if time from last notification is big enough - add a new line when concatening - they probably are
            // separate messages
            let hasPhoneNumber = try dataPacket.getPhoneNumber() != nil
            let phoneNumber = try dataPacket.getPhoneNumber() ?? "unknown number"
            let contactName = try dataPacket.getContactName() ?? phoneNumber
            var messageBody = try dataPacket.getMessageBody() ?? ""
            let thumbnail = (try? dataPacket.getPhoneThumbnail() ?? nil) ?? nil
            
            if #available(macOS 11.0, *) {
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
                }
            } else {
                let lastNotification = NSUserNotificationCenter.default.deliveredNotifications.first { notification in
                    return notification.identifier == notificationId
                }
                let lastNotificationIsOld = (lastNotification?.deliveryDate ?? Date()).timeIntervalSinceNow < -10.0
                let lastMessageBody = (lastNotification?.informativeText ?? "") + (lastNotificationIsOld ? "\n" : "")
                messageBody = lastMessageBody + messageBody
                if let notification = lastNotification {
                    NSUserNotificationCenter.default.removeDeliveredNotification(notification)
                }
            }
            if #available(macOS 11.0, *) {
                un.requestAuthorization(options: [.alert, .sound]) { (authorized, error) in
                    if authorized {
                        print("Authorized to send notifications!")
                    } else if !authorized {
                        print("Not authorized to send notifications")
                    } else {
                        print(error?.localizedDescription as Any)
                    }
                }
                un.getNotificationSettings { (settings) in
                    if settings.authorizationStatus == .authorized {
                        let notification = UNMutableNotificationContent()
                        var userInfo = notification.userInfo
                        userInfo[NotificationProperty.deviceId.rawValue] = device.id as AnyObject
                        userInfo[NotificationProperty.event.rawValue] = DataPacket.TelephonyEvent.sms.rawValue as AnyObject
                        userInfo[NotificationProperty.phoneNumber.rawValue] = phoneNumber as AnyObject
                        notification.userInfo = userInfo
                        notification.title = "SMS from  \(contactName) | \(device.name)"
                        notification.body = messageBody
                        notification.sound = UNNotificationSound.default()
                        let notificationIconPath = Bundle.main.pathForImageResource(NSImage.Name("Message"))
                        if (notificationIconPath != nil) {
                            let notificationIconURL = URL(fileURLWithPath: notificationIconPath!)
                            do {
                                let attachment = try UNNotificationAttachment.init(identifier: notificationId, url: notificationIconURL, options: .none)
                                notification.attachments = [attachment]
                            }
                            catch let error {
                                print(error.localizedDescription)
                            }
                        }
                        if hasPhoneNumber {
                            notification.categoryIdentifier = "SMSReceived"
                            let reply = UNTextInputNotificationAction(identifier: "reply", title: "Reply", textInputButtonTitle: "Send", textInputPlaceholder: "Your reply message...")
                            let category = UNNotificationCategory(identifier: "SMSReceived", actions: [reply], intentIdentifiers: [], options: [])
                            self.un.setNotificationCategories([category])
                        }
                        let request = UNNotificationRequest(identifier: notificationId, content: notification, trigger: nil)
                        self.un.add(request){ (error) in
                            if error != nil {print(error?.localizedDescription as Any)}
                        }
                    } else {
                        Log.debug?.message("Soduto isn't authorized to push notifications!")
                    }
                }
            } else {
                let notification = NSUserNotification(actionHandlerClass: type(of: self))
                var userInfo = notification.userInfo
                userInfo?[NotificationProperty.deviceId.rawValue] = device.id as AnyObject
                userInfo?[NotificationProperty.event.rawValue] = DataPacket.TelephonyEvent.sms.rawValue as AnyObject
                userInfo?[NotificationProperty.phoneNumber.rawValue] = phoneNumber as AnyObject
                notification.userInfo = userInfo
                notification.title = "SMS from  \(contactName) | \(device.name)"
                notification.informativeText = messageBody
                notification.contentImage = thumbnail
                notification.soundName = NSUserNotificationDefaultSoundName
                notification.hasActionButton = hasPhoneNumber
                notification.hasReplyButton = hasPhoneNumber
                notification.responsePlaceholder = "Write reply message"
                notification.identifier = notificationId
                NSUserNotificationCenter.default.deliver(notification)
                
                Log.debug?.message("SMS notification shown: \(String(describing: notification.identifier))")
            }
        }
        catch {
            Log.error?.message("Error while showing sms notification: \(error)")
        }
    }
    
    private func hideNotification(for dataPacket: DataPacket, from device: Device) {
        assert(dataPacket.isTelephonyPacket, "Expected telephony data packet")
        
        guard let id = self.notificationId(for: dataPacket, from: device) else { return }
        
        if #available(macOS 11.0, *) {
            UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [id])
            //            UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [id])
        } else {
            for notification in NSUserNotificationCenter.default.deliveredNotifications {
                if notification.identifier == id {
                    NSUserNotificationCenter.default.removeDeliveredNotification(notification)
                    break
                }
            }
            
            for notification in NSUserNotificationCenter.default.scheduledNotifications {
                if notification.identifier == id {
                    NSUserNotificationCenter.default.removeScheduledNotification(notification)
                    break
                }
            }
        }
        
        Log.debug?.message("Notification hidden: \(id)")
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
                Log.error?.message("Failed to handle SMS packets: \(error)")
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
    
    enum TelephonyAction: String {
        case mute = "mute"
    }
    
    enum TelephonyProperty: String {
        case event = "event"                    // (string): can be one of TelephonyEvent values
        case phoneNumber = "phoneNumber"        // (string)
        case contactName = "contactName"        // (string)
        case messageBody = "messageBody"        // (string)
        case phoneThumbnail = "phoneThumbnail"  // (bytes)
        case action = "action"                  // (string): 'mute' for muting the phone
        case sendSms = "sendSms"                // (boolean): true to send sms
        case isCancel = "isCancel"              // (boolean): cancel previous event
    }
    
    
    // MARK: Properties
    
    static let telephonyPacketType = "kdeconnect.telephony"
    static let telephonyRequestPacketType = "kdeconnect.telephony.request"
    static let smsRequestPacketType = "kdeconnect.sms.request"
    
    var isTelephonyPacket: Bool { return self.type == DataPacket.telephonyPacketType }
    
    var isTelephonyRequestPacket: Bool { return self.type == DataPacket.telephonyRequestPacketType }
    
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
        return DataPacket(type: telephonyRequestPacketType, body: [
            TelephonyProperty.action.rawValue: TelephonyAction.mute.rawValue as AnyObject
        ])
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
        guard let data = body[TelephonyProperty.phoneThumbnail.rawValue] as? Data else { throw TelephonyError.invalidEvent }
        guard let image = NSImage(data: data) else { throw TelephonyError.invalidEvent }
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
