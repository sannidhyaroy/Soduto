//
//  LockService.swift
//  Soduto
//
//  Created by Sannidhya Roy on 27/03/26.
//  Copyright © 2026 Soduto. All rights reserved.
//

import Foundation
import AppKit
import os
import UserNotifications

/// Service providing remote screen lock/unlock between devices
///
/// This service implements the KDE Connect lock protocol (`kdeconnect.lock`).
/// It can lock the local Mac screen on request from a paired device, report
/// local lock state changes, and send lock commands to remote devices.
///
/// Lock mechanism: `SACLockScreenImmediate()` from the private `login` framework.
/// Unlock is not feasible on macOS — handled gracefully (no-op, current state reported back).
/// Local state monitoring uses `DistributedNotificationCenter` for screen lock/unlock events.
public class LockService: NSObject, BidirectionalService, ObservableObject {
    
    // MARK: Types
    
    /// Per-device capability flags from the `canLock`/`canUnlock` protocol extension.
    /// `nil` means the remote did not advertise the field — treated as "unknown" (show the control).
    public struct LockCapabilities {
        var canLock: Bool?
        var canUnlock: Bool?
    }
    
    enum ActionId: ServiceAction.Id {
        case lockDevice
        case unlockDevice
    }
    
    
    // MARK: Properties
    
    let un = UNUserNotificationCenter.current()
    
    @Published private(set) var remoteLockStates: [Device.Id: Bool] = [:]
    private(set) var remoteCapabilities: [Device.Id: LockCapabilities] = [:]
    
    var userDefaults: UserDefaults = .standard
    let incomingPreferenceKey = AppDefaultsStore.Preferences.Services.Lock.incomingKey
    let outgoingPreferenceKey = AppDefaultsStore.Preferences.Services.Lock.outgoingKey
    
    private var devices: [Device] = []
    private var localLocked: Bool = false
    
    
    // MARK: Setup / Cleanup
    
    override init() {
        self.localLocked = LockService.readScreenLockedState()
        super.init()
        startMonitoringLockState()
    }
    
    deinit {
        stopMonitoringLockState()
    }
    
    
    // MARK: Service
    
    public static let serviceId: Service.Id = "com.soduto.services.lock"
    
    public var incomingCapabilities: Set<Service.Capability> {
        // incomingEnabled: we accept lock state packets from the device
        // outgoingEnabled: we handle lock request packets from the device (so we can respond)
        var caps = Set<Service.Capability>()
        if incomingEnabled { caps.insert(DataPacket.lockPacketType) }
        if outgoingEnabled { caps.insert(DataPacket.lockRequestPacketType) }
        return caps
    }
    public var outgoingCapabilities: Set<Service.Capability> {
        // incomingEnabled: we send lock request packets to ask the device for its state
        // outgoingEnabled: we send lock state packets to the device
        var caps = Set<Service.Capability>()
        if incomingEnabled { caps.insert(DataPacket.lockRequestPacketType) }
        if outgoingEnabled { caps.insert(DataPacket.lockPacketType) }
        return caps
    }
    
    public func handleDataPacket(_ dataPacket: DataPacket, fromDevice device: Device, onConnection connection: Connection) -> Bool {
        do {
            switch dataPacket.type {
            case DataPacket.lockPacketType:
                // Remote device reporting its lock state or a lock operation result
                guard incomingEnabled else { return true }
                try handle(statePacket: dataPacket, fromDevice: device)
            case DataPacket.lockRequestPacketType:
                // Remote device requesting our state or asking us to lock/unlock
                guard outgoingEnabled else { return true }
                try handle(requestPacket: dataPacket, fromDevice: device)
            default:
                return false
            }
        } catch {
            Logger.services.error("Error handling lock packet: \(error, privacy: .public)")
        }
        return true
    }
    
    public func setup(for device: Device) {
        guard !self.devices.contains(where: { $0.id == device.id }) else { return }
        
        // Query the remote device's lock state
        if device.incomingCapabilities.contains(DataPacket.lockRequestPacketType) {
            request(DataPacket.lockRequestPacket(), from: device)
        }
        
        // Track device for outgoing state broadcasts
        if outgoingEnabled && device.incomingCapabilities.contains(DataPacket.lockPacketType) {
            self.devices.append(device)
        }
    }
    
    public func cleanup(for device: Device) {
        self.remoteLockStates.removeValue(forKey: device.id)
        self.remoteCapabilities.removeValue(forKey: device.id)
        
        if let index = self.devices.firstIndex(where: { $0.id == device.id }) {
            self.devices.remove(at: index)
        }
    }
    
    public func actions(for device: Device) -> [ServiceAction] {
        guard device.incomingCapabilities.contains(DataPacket.lockRequestPacketType) else { return [] }
        guard device.pairingStatus == .Paired else { return [] }
        
        let caps = remoteCapabilities[device.id]
        let isLocked = remoteLockStates[device.id] ?? false
        
        if isLocked {
            // Show Unlock only if canUnlock is explicitly true, or unknown (nil = backward compat)
            guard caps?.canUnlock != false else { return [] }
            return [
                ServiceAction(id: ActionId.unlockDevice.rawValue, title: "Unlock Device", description: "Unlock the remote device screen", service: self, device: device)
            ]
        } else {
            // Show Lock only if canLock is explicitly true, or unknown (nil = backward compat)
            guard caps?.canLock != false else { return [] }
            return [
                ServiceAction(id: ActionId.lockDevice.rawValue, title: "Lock Device", description: "Lock the remote device screen", service: self, device: device)
            ]
        }
    }
    
    public func performAction(_ id: ServiceAction.Id, forDevice device: Device, userInfo: [String: Any]?) {
        guard let actionId = ActionId(rawValue: id) else { return }
        guard device.pairingStatus == .Paired else { return }
        
        switch actionId {
        case .lockDevice:
            request(DataPacket.setLockedPacket(locked: true), from: device)
        case .unlockDevice:
            request(DataPacket.setLockedPacket(locked: false), from: device)
        }
    }
    
    
    // MARK: Private methods
    
    /// C function pointer type for `SACLockScreenImmediate` — must be `@convention(c)` so it
    /// is a plain 8-byte pointer, matching the size of the raw pointer returned by `dlsym`.
    private typealias SACLockFn = @convention(c) () -> Void
    
    /// Handle to the dynamically loaded `SACLockScreenImmediate` function.
    private static let lockFunction: SACLockFn? = {
        guard let lib = dlopen("/System/Library/PrivateFrameworks/login.framework/login", RTLD_LAZY) else { return nil }
        guard let sym = dlsym(lib, "SACLockScreenImmediate") else { return nil }
        return unsafeBitCast(sym, to: SACLockFn.self)
    }()
    
    /// Reads the current screen lock state synchronously via CGSession.
    /// Returns `false` if the state cannot be determined.
    private static func readScreenLockedState() -> Bool {
        guard let dict = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
        return dict["CGSSessionScreenIsLocked"] as? Bool ?? false
    }
    
    /// Whether this Mac can be locked remotely (true iff SACLockScreenImmediate loaded successfully).
    private var localCanLock: Bool { LockService.lockFunction != nil }
    /// macOS does not support remote unlock.
    private let localCanUnlock: Bool = false
    
    private func handle(statePacket packet: DataPacket, fromDevice device: Device) throws {
        if let success = try packet.getLockResult() {
            showLockResultNotification(success: success, device: device)
        }
        if packet.body.keys.contains(DataPacket.LockProperty.isLocked) {
            self.remoteLockStates[device.id] = try packet.getIsLocked()
        }
        // Parse canLock/canUnlock capability extensions; nil = field absent = unknown
        let canLock = try packet.getCanLock()
        let canUnlock = try packet.getCanUnlock()
        if canLock != nil || canUnlock != nil {
            self.remoteCapabilities[device.id] = LockCapabilities(canLock: canLock, canUnlock: canUnlock)
        }
    }
    
    private func handle(requestPacket packet: DataPacket, fromDevice device: Device) throws {
        if try packet.getRequestLockedFlag() {
            sendLocalState(to: device)
            return
        }
        if let setLocked = try packet.getSetLocked() {
            if setLocked {
                let success = lockScreen()
                if success { localLocked = true }
                send(DataPacket.lockResultPacket(success: success, isLocked: localLocked, canLock: localCanLock, canUnlock: localCanUnlock), to: device)
            }
            // Always report current state after any lock/unlock attempt
            sendLocalState(to: device)
        }
    }
    
    /// Locks the Mac screen using `SACLockScreenImmediate` from the private login framework.
    /// Returns `true` if the lock function was available and invoked.
    private func lockScreen() -> Bool {
        guard let lock = LockService.lockFunction else {
            Logger.services.error("SACLockScreenImmediate unavailable — cannot lock screen")
            return false
        }
        lock()
        Logger.services.info("Screen locked via SACLockScreenImmediate")
        return true
    }
    
    private func sendLocalState(to device: Device) {
        send(DataPacket.lockStatePacket(isLocked: localLocked, canLock: localCanLock, canUnlock: localCanUnlock), to: device)
    }
    
    private func broadcastLocalState() {
        let packet = DataPacket.lockStatePacket(isLocked: localLocked, canLock: localCanLock, canUnlock: localCanUnlock)
        for device in devices {
            send(packet, to: device)
        }
    }
    
    private func startMonitoringLockState() {
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(screenDidLock),
            name: NSNotification.Name("com.apple.screenIsLocked"),
            object: nil
        )
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(screenDidUnlock),
            name: NSNotification.Name("com.apple.screenIsUnlocked"),
            object: nil
        )
    }
    
    private func stopMonitoringLockState() {
        DistributedNotificationCenter.default().removeObserver(
            self,
            name: NSNotification.Name("com.apple.screenIsLocked"),
            object: nil
        )
        DistributedNotificationCenter.default().removeObserver(
            self,
            name: NSNotification.Name("com.apple.screenIsUnlocked"),
            object: nil
        )
    }
    
    @objc private func screenDidLock() {
        localLocked = true
        broadcastLocalState()
    }
    
    @objc private func screenDidUnlock() {
        localLocked = false
        broadcastLocalState()
    }
    
    private func notificationId(for device: Device) -> String {
        return "\(self.id).\(device.id)"
    }
    
    private func showLockResultNotification(success: Bool, device: Device) {
        let notification = UNMutableNotificationContent()
        notification.title = device.name
        notification.body = success
        ? NSLocalizedString("Remote lock successful", comment: "lock result notification")
        : NSLocalizedString("Remote lock failed", comment: "lock result notification")
        notification.sound = .default
        notification.threadIdentifier = "lock"
        notification.setUrgency(.active)
        
        let id = notificationId(for: device)
        let request = UNNotificationRequest(identifier: id, content: notification, trigger: nil)
        un.add(request) { error in
            if let error = error {
                Logger.services.error("Failed to show lock result notification: \(error, privacy: .public)")
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(5)) {
            self.un.removeNotification(withId: id)
        }
    }
}


// MARK: DataPacket (Lock)

/// Lock service data packet utilities
fileprivate extension DataPacket {
    
    // MARK: Types
    
    enum LockError: Error {
        case wrongType
        case invalidLockedFlag
        case invalidLockResult
        case invalidCanLock
        case invalidCanUnlock
        case invalidSetLockedFlag
    }
    
    struct LockProperty {
        static let isLocked = "isLocked"
        static let lockResult = "lockResult"
        static let requestLocked = "requestLocked"
        static let setLocked = "setLocked"
        static let canLock = "canLock"
        static let canUnlock = "canUnlock"
    }
    
    
    // MARK: Properties
    
    static let lockPacketType = "kdeconnect.lock"
    static let lockRequestPacketType = "kdeconnect.lock.request"
    
    var isLockPacket: Bool { return self.type == DataPacket.lockPacketType }
    var isLockRequestPacket: Bool { return self.type == DataPacket.lockRequestPacketType }
    
    
    // MARK: Public static methods
    
    /// Lock state announcement: `{ "isLocked": bool, "canLock": bool, "canUnlock": bool }`
    /// `canLock`/`canUnlock` are the Soduto protocol extension fields (protocol-extensions.md).
    static func lockStatePacket(isLocked: Bool, canLock: Bool, canUnlock: Bool) -> DataPacket {
        return DataPacket(type: lockPacketType, body: [
            LockProperty.isLocked: isLocked as AnyObject,
            LockProperty.canLock: canLock as AnyObject,
            LockProperty.canUnlock: canUnlock as AnyObject
        ])
    }
    
    /// Lock operation result with state: `{ "lockResult": bool, "isLocked": bool, "canLock": bool, "canUnlock": bool }`
    static func lockResultPacket(success: Bool, isLocked: Bool, canLock: Bool, canUnlock: Bool) -> DataPacket {
        return DataPacket(type: lockPacketType, body: [
            LockProperty.lockResult: success as AnyObject,
            LockProperty.isLocked: isLocked as AnyObject,
            LockProperty.canLock: canLock as AnyObject,
            LockProperty.canUnlock: canUnlock as AnyObject
        ])
    }
    
    /// Request current lock state: `{ "requestLocked": true }`
    static func lockRequestPacket() -> DataPacket {
        return DataPacket(type: lockRequestPacketType, body: [
            LockProperty.requestLocked: true as AnyObject
        ])
    }
    
    /// Request to lock or unlock: `{ "setLocked": bool }`
    static func setLockedPacket(locked: Bool) -> DataPacket {
        return DataPacket(type: lockRequestPacketType, body: [
            LockProperty.setLocked: locked as AnyObject
        ])
    }
    
    
    // MARK: Public methods
    
    func getIsLocked() throws -> Bool {
        try self.validateLockType()
        guard let value = body[LockProperty.isLocked] as? NSNumber else { throw LockError.invalidLockedFlag }
        return value.boolValue
    }
    
    func getLockResult() throws -> Bool? {
        try self.validateLockType()
        guard body.keys.contains(LockProperty.lockResult) else { return nil }
        guard let value = body[LockProperty.lockResult] as? NSNumber else { throw LockError.invalidLockResult }
        return value.boolValue
    }
    
    func getRequestLockedFlag() throws -> Bool {
        try self.validateLockRequestType()
        // Per the protocol spec, requestLocked is always true when present.
        // KDE Desktop sends QVariant() (null) as the value, so we treat presence
        // of the key alone as the signal rather than parsing the value.
        return body.keys.contains(LockProperty.requestLocked)
    }
    
    func getSetLocked() throws -> Bool? {
        try self.validateLockRequestType()
        guard body.keys.contains(LockProperty.setLocked) else { return nil }
        guard let value = body[LockProperty.setLocked] as? NSNumber else { throw LockError.invalidSetLockedFlag }
        return value.boolValue
    }
    
    /// Returns the `canLock` capability field, or `nil` if absent (unknown — backward compat).
    func getCanLock() throws -> Bool? {
        try self.validateLockType()
        guard body.keys.contains(LockProperty.canLock) else { return nil }
        guard let value = body[LockProperty.canLock] as? NSNumber else { throw LockError.invalidCanLock }
        return value.boolValue
    }
    
    /// Returns the `canUnlock` capability field, or `nil` if absent (unknown — backward compat).
    func getCanUnlock() throws -> Bool? {
        try self.validateLockType()
        guard body.keys.contains(LockProperty.canUnlock) else { return nil }
        guard let value = body[LockProperty.canUnlock] as? NSNumber else { throw LockError.invalidCanUnlock }
        return value.boolValue
    }
    
    func validateLockType() throws {
        guard self.isLockPacket else { throw LockError.wrongType }
    }
    
    func validateLockRequestType() throws {
        guard self.isLockRequestPacket else { throw LockError.wrongType }
    }
}
