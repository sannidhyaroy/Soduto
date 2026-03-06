//
//  ConnectivityReportService.swift
//  Soduto
//
//  Created on 2025-04-16.
//  Copyright © 2025 Soduto. All rights reserved.
//

import Foundation
import Cocoa
import os

/// This service receives packages with type "kdeconnect.connectivity_report" and reads the
/// following fields:
///
/// - signalStrengths (dictionary): Contains information about cellular connectivity
///   - [subscriptionID] (dictionary): Data for each SIM card
///     - networkType (string): The cellular network type (GSM, UMTS, LTE, 5G, etc.)
///     - signalStrength (int): Signal strength level (0-4)
///
/// It also sends packages with type "kdeconnect.connectivity_report.request" to ask for updates.
public class ConnectivityReportService: Service {
    
    // MARK: Types
    
    /// Status for a single SIM slot.
    public struct ConnectivityStatus {
        var networkType: String
        var signalStrength: Int
        
        /// Whether this SIM has a known (non-"Unknown") network type.
        var isActive: Bool { networkType != "Unknown" }
    }
    
    // MARK: Properties
    
    /// Per-device SIM statuses, ordered by subscriptionId ascending (SIM 1 first, SIM 2 second).
    /// At most 2 entries are kept. The stable ordering means SIM positions in the UI never swap.
    public private(set) var statuses: [Device.Id: [ConnectivityStatus]] = [:]
    private var devices: [Device] = []
    
    // MARK: Service
    
    public static let serviceId: Service.Id = "com.soduto.services.connectivity_report"
    
    public let incomingCapabilities = Set<Service.Capability>([ DataPacket.connectivityReportPacketType ])
    public let outgoingCapabilities = Set<Service.Capability>([ DataPacket.connectivityReportRequestPacketType ])
    
    public func handleDataPacket(_ dataPacket: DataPacket, fromDevice device: Device, onConnection connection: Connection) -> Bool {
        guard dataPacket.isConnectivityReportPacket else { return false }
        
        do {
            try handle(statusPacket: dataPacket, fromDevice: device)
        } catch {
            Logger.services.error("Error handling connectivity report packet: \(error, privacy: .public)")
        }
        
        return true
    }
    
    public func setup(for device: Device) {
        guard !self.devices.contains(where: { $0.id == device.id }) else { return }
        
        if device.incomingCapabilities.contains(DataPacket.connectivityReportPacketType) {
            self.devices.append(device)
            requestStatus(for: device)
        }
    }
    
    public func cleanup(for device: Device) {
        self.statuses.removeValue(forKey: device.id)
        
        if let index = self.devices.firstIndex(where: { $0.id == device.id }) {
            self.devices.remove(at: index)
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
    
    private func handle(statusPacket packet: DataPacket, fromDevice device: Device) throws {
        guard let signalStrengths = packet.body["signalStrengths"] as? [String: Any] else { return }
        
        // Parse all SIM entries, keyed by their subscriptionId
        let parsed: [(id: Int, status: ConnectivityStatus)] = signalStrengths.compactMap { key, value in
            guard let id = Int(key),
                  let data = value as? [String: Any],
                  let networkType = data["networkType"] as? String,
                  let signalStrength = data["signalStrength"] as? Int else { return nil }
            return (id, ConnectivityStatus(networkType: networkType, signalStrength: signalStrength))
        }
        
        // Sort by subscriptionId ascending so SIM 1 is always first, SIM 2 always second.
        // This keeps positions stable in the UI — they never swap when data SIM changes.
        let sorted = parsed.sorted { $0.id < $1.id }.prefix(2).map { $0.status }
        
        self.statuses[device.id] = sorted
    }
    
    private func requestStatus(for device: Device) {
        device.send(DataPacket.connectivityReportRequestPacket())
    }
}


// MARK: DataPacket (ConnectivityReport)

/// Connectivity Report service data packet utilities
fileprivate extension DataPacket {
    
    // MARK: Types
    
    enum ConnectivityReportError: Error {
        case wrongType
    }
    
    // MARK: Properties
    
    static let connectivityReportPacketType = "kdeconnect.connectivity_report"
    static let connectivityReportRequestPacketType = "kdeconnect.connectivity_report.request"
    
    var isConnectivityReportPacket: Bool { return self.type == DataPacket.connectivityReportPacketType }
    var isConnectivityReportRequestPacket: Bool { return self.type == DataPacket.connectivityReportRequestPacketType }
    
    // MARK: Public static methods
    
    static func connectivityReportRequestPacket() -> DataPacket {
        return DataPacket(type: connectivityReportRequestPacketType, body: [:])
    }
}
