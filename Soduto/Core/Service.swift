//
//  Service.swift
//  Soduto
//
//  Created by Giedrius Stanevičius on 2016-11-18.
//  Copyright © 2016 Soduto. All rights reserved.
//

import Foundation

public protocol Service: DeviceDataPacketHandler {
    
    typealias Capability = String
    typealias Id = String
    
    static var serviceId: Id { get }
    
    var incomingCapabilities: Set<Capability> { get }
    var outgoingCapabilities: Set<Capability> { get }
    
    func setup(for device: Device)
    func cleanup(for device: Device)
    
    func actions(for device: Device) -> [ServiceAction]
    func performAction(_ id: ServiceAction.Id, forDevice device: Device, userInfo: [String: Any]?)
    
    /// Called by `ServiceManager` immediately after the service is registered,
    /// providing the `UserDefaults` instance the service should use for reading
    /// user-configurable preferences (e.g. per-direction enable/disable flags)
    ///
    /// Services that have no user-configurable preferences do not need to
    /// implement this as the default no-op is inherited automatically
    func configure(with userDefaults: UserDefaults)
}

extension Service {
    var id: Id { return type(of: self).serviceId }
    public func configure(with userDefaults: UserDefaults) {}
}


// MARK: - Service Toggle Protocol Hierarchy
//
// Rules for services that conform to these protocols:
//
//   1. Declare three properties (userDefaults, incomingPreferenceKey, outgoingPreferenceKey)
//      configure(with:), incomingEnabled, outgoingEnabled, and send(_:to:) are provided for free
//
//   2. In handleDataPacket:
//        - Purely incoming branch  → guard incomingEnabled else { return true }
//        - Request→response branch → guard outgoingEnabled else { return true }
//
//   3. All outgoing data sends use send(_:to:) instead of device.send(_:) directly
//      Setup-time decisions (append to device list, start monitoring, send a request to receive)
//      may still use device.send(_:) directly with an inline direction check

/// Base for services that read preferences from an injected UserDefaults
/// Provides configure(with:) automatically, so conforming services do not implement it
protocol ServiceBase: Service {
    var userDefaults: UserDefaults { get set }
}
extension ServiceBase {
    public func configure(with userDefaults: UserDefaults) { self.userDefaults = userDefaults }
}

/// A service that can receive data from a remote device (incoming direction)
/// Provides incomingEnabled and request(_:from:), so conforming services do not implement these
protocol IncomingService: ServiceBase {
    var incomingPreferenceKey: String { get }
}
extension IncomingService {
    var incomingEnabled: Bool { userDefaults.serviceBool(incomingPreferenceKey) }
    
    /// Send a request packet to a device to elicit incoming data, gated by incomingEnabled
    /// Use this instead of device.send(_:) when the purpose of the send is to receive a response
    func request(_ packet: DataPacket, from device: Device) {
        guard incomingEnabled else { return }
        device.send(packet)
    }
}

/// A service that can send data to a remote device (outgoing direction)
/// Provides outgoingEnabled and send(_:to:), so conforming services do not implement these
protocol OutgoingService: ServiceBase {
    var outgoingPreferenceKey: String { get }
}
extension OutgoingService {
    var outgoingEnabled: Bool { userDefaults.serviceBool(outgoingPreferenceKey) }
    
    /// Send a packet to a device, silently dropping it when outgoing is disabled
    /// Use this instead of device.send(_:) for all outgoing data sends
    func send(_ packet: DataPacket, to device: Device) {
        guard outgoingEnabled else { return }
        device.send(packet)
    }
}

/// Convenience alias for services with both incoming and outgoing directions
typealias BidirectionalService = IncomingService & OutgoingService
