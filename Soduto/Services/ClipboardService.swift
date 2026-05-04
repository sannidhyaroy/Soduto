//
//  ClipboardService.swift
//  Soduto
//
//  Created by Giedrius Stanevičius on 2016-11-30.
//  Copyright © 2016 Soduto. All rights reserved.
//

import Cocoa

/// Service providing clipboard content sharing between devices
///
/// When the clipboard changes, it sends a package with type kdeconnect.clipboard
/// and the field "content" (string) containing the new clipboard content.
///
/// When a device connects, a `kdeconnect.clipboard.connect` packet is sent containing
/// the current clipboard content and a timestamp (ms since epoch). The receiver
/// compares timestamps and only applies the content if it is newer than its own.
///
/// When it receives a package of the same kind, it should update the system
/// clipboard with the received content, so the clipboard in both devices always
/// have the same content.
///
/// This plugin is symmetric to its counterpart in the other device: both have the
/// same behaviour.
public class ClipboardService: BidirectionalService {
    
    // MARK: Properties
    
    private static let monitoringInterval: TimeInterval = 0.5
    
    var userDefaults: UserDefaults = .standard
    let incomingPreferenceKey = AppDefaultsStore.Preferences.Services.Clipboard.incomingKey
    let outgoingPreferenceKey = AppDefaultsStore.Preferences.Services.Clipboard.outgoingKey
    
    private var monitoringTimer: Timer? = nil
    private var lastChangeCount: Int = NSPasteboard.general.changeCount
    private var lastExternalChangeCount: Int = -1
    private var lastExternalChangeDevice: Device? = nil
    private var devices: [Device] = []
    
    /// Timestamp of the last local clipboard change. Initialized to epoch so that
    /// an incoming clipboard.connect from a peer (with a real timestamp) always wins
    /// on first connect when we have no tracked change history
    private var lastLocalChangeTimestamp: Date = Date(timeIntervalSince1970: 0)
    
    
    // MARK: Service
    
    public static let serviceId: Service.Id = "com.soduto.services.clipboard"
    
    public var incomingCapabilities: Set<Service.Capability> {
        incomingEnabled ? [DataPacket.clipboardPacketType, DataPacket.clipboardConnectPacketType] : []
    }
    public var outgoingCapabilities: Set<Service.Capability> {
        outgoingEnabled ? [DataPacket.clipboardPacketType, DataPacket.clipboardConnectPacketType] : []
    }
    
    public func handleDataPacket(_ dataPacket: DataPacket, fromDevice device: Device, onConnection connection: Connection) -> Bool {
        switch dataPacket.type {
        case DataPacket.clipboardPacketType:
            guard incomingEnabled else { return true }
            guard let contents = try? dataPacket.getContent() else { return true }
            applyExternalClipboard(contents, from: device)
            return true
        case DataPacket.clipboardConnectPacketType:
            guard incomingEnabled else { return true }
            guard let contents = try? dataPacket.getContent() else { return true }
            // Treat missing/zero timestamp as "unknown" — do not apply (matches Android behaviour).
            let remoteTimestamp = (try? dataPacket.getTimestamp()) ?? Date(timeIntervalSince1970: 0)
            guard remoteTimestamp.timeIntervalSince1970 > 0 else { return true }
            if remoteTimestamp > lastLocalChangeTimestamp {
                applyExternalClipboard(contents, from: device)
            }
            return true
        default:
            return false
        }
    }
    
    public func setup(for device: Device) {
        guard !self.devices.contains(where: { $0.id == device.id }) else { return }
        
        self.devices.append(device)
        
        // On connect, send our current clipboard with its timestamp so the peer
        // can decide which side has the newer content
        if let items = NSPasteboard.general.readObjects(forClasses: [NSString.self], options: nil),
           let content = items.first as? String {
            send(DataPacket.clipboardConnectPacket(withContent: content, timestamp: self.lastLocalChangeTimestamp), to: device)
        }
        
        if self.monitoringTimer == nil {
            self.startMonitoring()
        }
    }
    
    public func cleanup(for device: Device) {
        guard let index = self.devices.firstIndex(where: { $0.id == device.id }) else { return }
        
        self.devices.remove(at: index)
        
        if self.devices.count == 0 {
            self.stopMonitoring()
        }
    }
    
    public func actions(for device: Device) -> [ServiceAction] {
        // No supported actions
        return []
    }
    
    public func performAction(_ id: ServiceAction.Id, forDevice device: Device) {
        // No supported actions
    }
    
    
    // MARK: Private methods
    
    private func startMonitoring() {
        let interval = ClipboardService.monitoringInterval
        self.monitoringTimer = Timer.compatScheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            self?.checkPasteboard()
        }
    }
    
    private func stopMonitoring() {
        self.monitoringTimer?.invalidate()
        self.monitoringTimer = nil
    }
    
    private func checkPasteboard() {
        guard NSPasteboard.general.changeCount != self.lastChangeCount else { return }
        guard let items = NSPasteboard.general.readObjects(forClasses: [ NSString.self ], options: nil) else { return }
        guard items.count > 0 else { return }
        guard let content = items[0] as? String else { return }
        
        self.lastChangeCount = NSPasteboard.general.changeCount
        self.lastLocalChangeTimestamp = Date()
        
        for device in self.devices {
            guard !(self.lastChangeCount == self.lastExternalChangeCount && self.lastExternalChangeDevice === device) else { continue }
            send(DataPacket.clipboardPacket(withContent: content), to: device)
        }
    }
    
    private func applyExternalClipboard(_ content: String, from device: Device) {
        self.lastExternalChangeDevice = device
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([content as NSString])
        // Capture changeCount AFTER the write so the dedup check in checkPasteboard fires
        // correctly — clearContents() returns the post-clear count, not the post-write count.
        self.lastExternalChangeCount = NSPasteboard.general.changeCount
        self.lastLocalChangeTimestamp = Date()
    }
}


// MARK: DataPacket (Clipboard)

/// Clipboard service data packet utilities
fileprivate extension DataPacket {
    
    // MARK: Types
    
    enum ClipboardError: Error {
        case wrongType
        case invalidContent
        case invalidTimestamp
    }
    
    enum ClipboardProperty: String {
        case content = "content"
        case timestamp = "timestamp"
    }
    
    
    // MARK: Properties
    
    static let clipboardPacketType = "kdeconnect.clipboard"
    static let clipboardConnectPacketType = "kdeconnect.clipboard.connect"
    
    var isClipboardPacket: Bool { return self.type == DataPacket.clipboardPacketType }
    var isClipboardConnectPacket: Bool { return self.type == DataPacket.clipboardConnectPacketType }
    
    
    // MARK: Public static methods
    
    static func clipboardPacket(withContent content: String) -> DataPacket {
        return DataPacket(type: clipboardPacketType, body: [
            ClipboardProperty.content.rawValue: content as AnyObject
        ])
    }
    
    static func clipboardConnectPacket(withContent content: String, timestamp: Date) -> DataPacket {
        let ms = Int64(timestamp.timeIntervalSince1970 * 1000)
        return DataPacket(type: clipboardConnectPacketType, body: [
            ClipboardProperty.content.rawValue: content as AnyObject,
            ClipboardProperty.timestamp.rawValue: NSNumber(value: ms)
        ])
    }
    
    
    // MARK: Public methods
    
    func getContent() throws -> String {
        try self.validateClipboardType()
        guard body.keys.contains(ClipboardProperty.content.rawValue) else { throw ClipboardError.invalidContent }
        guard let value = body[ClipboardProperty.content.rawValue] as? String else { throw ClipboardError.invalidContent }
        return value
    }
    
    func getTimestamp() throws -> Date {
        guard isClipboardConnectPacket else { throw ClipboardError.wrongType }
        guard body.keys.contains(ClipboardProperty.timestamp.rawValue) else { throw ClipboardError.invalidTimestamp }
        guard let value = body[ClipboardProperty.timestamp.rawValue] as? NSNumber else { throw ClipboardError.invalidTimestamp }
        return Date(timeIntervalSince1970: value.doubleValue / 1000)
    }
    
    func validateClipboardType() throws {
        guard isClipboardPacket || isClipboardConnectPacket else { throw ClipboardError.wrongType }
    }
}
