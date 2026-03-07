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


// MARK: - StatusBarImageProvider

extension ConnectivityReportService: StatusBarImageProvider {
    
    public var statusBarImageSortOrder: Int { 0 }
    
    public func statusBarImage(for device: Device) -> NSImage? {
        guard let simStatuses = statuses[device.id], !simStatuses.isEmpty else {
            return nil
        }
        
        let imageHeight: CGFloat = 13
        let labelWidth: CGFloat = 15
        let labelGap: CGFloat = 1
        
        // Show bars for any SIM with signal strength data, even if network type is unknown
        // But only include network labels for SIMs with known types (not "Unknown")
        
        // Pre-compute the network type label for each SIM (empty string if unknown)
        func networkLabel(for sim: ConnectivityStatus) -> String {
            guard sim.isActive else { return "" }  // Only show label for known network types
            let t = sim.networkType
            return t == "LTE" ? "4G" :
            t == "5G"  ? "5G" :
            (t == "UMTS" || t == "CDMA2000" || t == "HSPA") ? "3G" :
            (t == "GSM"  || t == "CDMA"     || t == "iDEN"  || t == "EDGE") ? "2G" : ""
        }
        
        // Check if we have dual SIMs with data
        let isDual = simStatuses.count == 2
        
        let config = NSImage.SymbolConfiguration.preferringMulticolor()
        
        if isDual {
            // Dual SIM: show [label1] [label2] [bars] layout
            // cellularbars.dual.rX — right tower fixed at X bars, left tower variable draw
            let sim1 = simStatuses[0]
            let sim2 = simStatuses[1]
            let sim1Signal = min(max(sim1.signalStrength, 0), 4)
            let sim2Signal = min(max(sim2.signalStrength, 0), 4)
            let label1 = networkLabel(for: sim1)
            let label2 = networkLabel(for: sim2)
            
            let symbolName = "cellularbars.dual.r\(sim2Signal)"
            let variableValue = Double(sim1Signal) / 4.0
            
            guard let barsSymbol = NSImage(symbolName: symbolName, variableValue: variableValue)?.withSymbolConfiguration(config) else {
                return nil
            }
            
            // Calculate total width: label1 + gap + label2 + gap + bars
            var totalWidth: CGFloat = barsSymbol.size.width
            var labelCount = 0
            if !label1.isEmpty { totalWidth += labelWidth; labelCount += 1 }
            if !label2.isEmpty { totalWidth += labelWidth; labelCount += 1 }
            if labelCount > 0 { totalWidth += labelGap * CGFloat(labelCount) }
            
            let image = NSImage(size: CGSize(width: totalWidth, height: imageHeight), flipped: false) { _ in
                var x: CGFloat = 0
                let netAttr: [NSAttributedString.Key: Any] = [
                    .font: NSFont.systemFont(ofSize: 10),
                    .foregroundColor: NSColor.labelColor,
                ]
                
                // Draw label 1
                if !label1.isEmpty {
                    (label1 as NSString).draw(
                        in: NSRect(x: x, y: 2, width: labelWidth, height: 10),
                        withAttributes: netAttr
                    )
                    x += labelWidth + labelGap
                }
                
                // Draw label 2
                if !label2.isEmpty {
                    (label2 as NSString).draw(
                        in: NSRect(x: x, y: 2, width: labelWidth, height: 10),
                        withAttributes: netAttr
                    )
                    x += labelWidth + labelGap
                }
                
                // Draw bars
                barsSymbol.draw(in: NSRect(
                    x: x, y: (imageHeight - barsSymbol.size.height) / 2,
                    width: barsSymbol.size.width, height: barsSymbol.size.height
                ))
                
                return true
            }
            return image
            
        } else {
            // Single SIM: use plain cellularbars with variable draw
            let sim = simStatuses[0]
            let signal = min(max(sim.signalStrength, 0), 4)
            let label = networkLabel(for: sim)
            let variableValue = Double(signal) / 4.0
            
            guard let barsSymbol = NSImage(symbolName: "cellularbars", variableValue: variableValue)?.withSymbolConfiguration(config) else {
                return nil
            }
            
            let totalWidth = (label.isEmpty ? 0 : labelWidth + labelGap) + barsSymbol.size.width
            
            let image = NSImage(size: CGSize(width: totalWidth, height: imageHeight), flipped: false) { _ in
                var x: CGFloat = 0
                
                if !label.isEmpty {
                    let netAttr: [NSAttributedString.Key: Any] = [
                        .font: NSFont.systemFont(ofSize: 10),
                        .foregroundColor: NSColor.labelColor,
                    ]
                    (label as NSString).draw(
                        in: NSRect(x: x, y: 2, width: labelWidth, height: 10),
                        withAttributes: netAttr
                    )
                    x += labelWidth + labelGap
                }
                
                barsSymbol.draw(in: NSRect(
                    x: x, y: (imageHeight - barsSymbol.size.height) / 2,
                    width: barsSymbol.size.width, height: barsSymbol.size.height
                ))
                
                return true
            }
            return image
        }
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
