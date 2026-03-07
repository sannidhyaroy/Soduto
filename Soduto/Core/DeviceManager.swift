//
//  DeviceManager.swift
//  Soduto
//
//  Created by Admin on 2016-08-13.
//  Copyright © 2016 Soduto. All rights reserved.
//

import Foundation
import QuartzCore
import os

public protocol DeviceManagerDelegate: AnyObject {
    func deviceManager(_ manager: DeviceManager, didChangeDeviceState device: Device)
    func deviceManager(_ manager: DeviceManager, didReceivePairingRequest request: PairingRequest, forDevice device: Device)
}

public protocol DeviceDataSource: AnyObject {
    var unpairedDevices: [Device] { get }
    var pairedDevices: [Device] { get }
    var pairedRechableDevices: [Device] { get }
    var unavailableDevices: [Device] { get }
}

public protocol DeviceManagerConfiguration {
    func deviceConfig(for deviceId:Device.Id) -> DeviceConfiguration
    func knownDeviceConfigs() -> [DeviceConfiguration]
    var hostDeviceId: Device.Id { get }
}

public class DeviceManager: ConnectionProviderDelegate, DeviceDelegate, DeviceDataSource {
    
    // MARK: Types
    
    private struct RecentDeviceInfo {
        let device: Device
        let timestamp: TimeInterval
    }
    
    
    // MARK: Properties
    
    public weak var delegate: DeviceManagerDelegate? = nil
    
    public var unpairedDevices: [Device] {
        let filtered = self.devices.filter { $0.value.pairingStatus != PairingStatus.Paired }
        return filtered.map { $0.value }
    }
    
    public var pairedDevices: [Device] {
        let filtered = self.devices.filter { $0.value.pairingStatus == PairingStatus.Paired }
        return filtered.map { $0.value }
    }
    
    public var pairedRechableDevices: [Device] {
        let filtered = self.devices.filter { $0.value.isReachable && $0.value.pairingStatus == PairingStatus.Paired }
        return filtered.map { $0.value }
    }
    
    public var unavailableDevices: [Device] {
        let configs = config.knownDeviceConfigs().filter { self.devices[$0.deviceId] == nil && $0.isPaired}
        return configs.map {
            let device = Device(config: $0)
            device.delegate = self
            return device
        }
    }
    
    private let config: DeviceManagerConfiguration
    private let serviceManager: ServiceManager
    private var devices: [Device.Id:Device] = [:] /// Reachable devices
    private var recentDevices: [Device.Id:RecentDeviceInfo] = [:] /// Recently reachable devices
    
    private static let recentDevicesTimout: TimeInterval = 15.0
    
    
    // MARK: Init / Deinit
    
    init(config: DeviceManagerConfiguration, serviceManager: ServiceManager) {
        self.config = config
        self.serviceManager = serviceManager
    }
    
    
    // MARK: ConnectionProviderDelegate
    
    public func isNewConnectionNeeded(byProvider provider: ConnectionProvider, deviceId: Device.Id) -> Bool {
        if deviceId == self.config.hostDeviceId { return false }
        if devices[deviceId] != nil { return false }
        return true
    }
    
    public func connectionProvider(_ provider: ConnectionProvider, didCreateConnection connection: Connection) {
        Logger.device.debug("connectionProvider(<\(provider, privacy: .public)> didCreateConnection:<\(connection, privacy: .public)>)")
        
        // The state transition notification is dispatched asynchronously to the main queue,
        // so the NIO event loop can close the connection in the window between the notification
        // being queued and this handler running
        guard connection.state == .Open else {
            Logger.device.warning("connectionProvider delivered connection not in Open state (\(String(describing: connection.state), privacy: .public)) — ignoring")
            return
        }
        guard connection.identity != nil else {
            Logger.device.warning("connectionProvider delivered connection with nil identity — ignoring")
            return
        }
        
        do {
            let deviceId = try connection.identity!.getDeviceId() as Device.Id
            if let device = self.devices[deviceId] {
                device.addConnection(connection)
            }
            else if let device = self.recentDevices.removeValue(forKey: deviceId)?.device {
                self.readdDevice(device, connection: connection)
            }
            else {
                try self.addNewDevice(withId: deviceId, connection: connection)
            }
        }
        catch {
            Logger.device.error("Error adding new connection: \(error, privacy: .public)")
        }
    }
    
    
    // MARK: Public methods
    
    public func device(withId id: Device.Id) -> Device? {
        return self.devices[id]
    }
    
    
    // MARK: DeviceDelegate
    
    public func device(_ device: Device, didChangePairingStatus status: PairingStatus) {
        Logger.device.debug("device(<\(String(describing: device), privacy: .public)> didChangePairingStatus:<\(String(describing: status), privacy: .public)>)")
        
        if device.isReachable {
            if status == .Paired {
                self.serviceManager.setup(for: device)
            }
            else {
                self.serviceManager.cleanup(for: device)
            }
        }
        
        // Update pairing window based on status
        DispatchQueue.main.async {
            switch status {
            case .Paired:
                PairingInterfaceController.updatePairingUI(for: device.id, success: true)
            case .Unpaired:
                // If there's an active pairing window, it means pairing was rejected/cancelled
                if PairingWindowController.isActive(for: device.id) {
                    // Preserve explicit timeout state if it was already set by pairingFailed callback.
                    if let state = PairingWindowController.state(for: device.id),
                       state == .outgoingRequest || state == .incomingRequest {
                        PairingWindowController.updateState(for: device.id, state: .failed)
                    }
                }
            default:
                break
            }
        }
        
        self.delegate?.deviceManager(self, didChangeDeviceState: device)
    }
    
    public func device(_ device: Device, didReceivePairingRequest request: PairingRequest) {
        self.delegate?.deviceManager(self, didReceivePairingRequest: request, forDevice: device)
    }
    
    public func device(_ device: Device, pairingFailed error: Error) {
        Logger.device.debug("device(<\(String(describing: device), privacy: .public)> pairingFailed:<\(error, privacy: .public)>)")
        
        DispatchQueue.main.async {
            guard PairingWindowController.isActive(for: device.id) else { return }
            
            if let pairingError = error as? DefaultPairingHandler.Error,
               pairingError == .timedOut {
                PairingWindowController.updateState(for: device.id, state: .timeout)
            } else {
                PairingWindowController.updateState(for: device.id, state: .failed)
            }
        }
    }
    
    
    public func device(_ device: Device, didChangeReachabilityStatus isReachable: Bool) {
        Logger.device.debug("device(<\(device, privacy: .public)> didChangeReachabilityStatus:<\(isReachable, privacy: .public)>)")
        
        if device.pairingStatus == .Paired {
            if isReachable {
                self.serviceManager.setup(for: device)
            }
            else {
                self.serviceManager.cleanup(for: device)
            }
        }
        if !isReachable {
            self.removeDevice(device)
        }
        self.delegate?.deviceManager(self, didChangeDeviceState: device)
    }
    
    public func serviceActions(for device: Device) -> [ServiceAction] {
        guard device.pairingStatus == .Paired else { return [] }
        let services = self.serviceManager.services(supportingOutgoingCapabilities: device.incomingCapabilities)
        let actions = services.flatMap {
            return $0.actions(for: device)
        }
        return actions
    }
    
    /// Close all TCP connections for all devices (force reconnect)
    public func closeAllConnections() {
        for device in self.devices.values {
            device.closeAllConnections()
        }
    }
    
    // MARK: Private methods
    
    private func addNewDevice(withId id: Device.Id, connection: Connection) throws {
        let device = try Device(connection: connection, config: self.config.deviceConfig(for: id))
        device.delegate = self
        
        let services: [DeviceDataPacketHandler] = self.serviceManager.services(supportingIncomingCapabilities: device.outgoingCapabilities)
        device.addDataPacketHandlers(services)
        
        self.devices[device.id] = device
        self.device(device, didChangeReachabilityStatus: device.isReachable)
    }
    
    private func removeDevice(_ device: Device) {
        device.delegate = nil
        
        self.devices.removeValue(forKey: device.id)
        self.recentDevices[device.id] = RecentDeviceInfo(device: device, timestamp: CACurrentMediaTime())
        _ = Timer.compatScheduledTimer(withTimeInterval: type(of: self).recentDevicesTimout, repeats: false) { _ in
            guard let info = self.recentDevices[device.id] else { return }
            guard info.timestamp + type(of: self).recentDevicesTimout < CACurrentMediaTime() else { return }
            self.recentDevices.removeValue(forKey: device.id)
            self.serviceManager.cleanup(for: device)
        }
    }
    
    private func readdDevice(_ device: Device, connection: Connection) {
        device.addConnection(connection)
        device.delegate = self
        self.devices[device.id] = device
        self.device(device, didChangeReachabilityStatus: device.isReachable)
    }
}
