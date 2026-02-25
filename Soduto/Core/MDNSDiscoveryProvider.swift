//
//  MDNSDiscoveryProvider.swift
//  Soduto
//
//  Created by Sannidhya Roy on 21/02/26.
//  Copyright © 2025 Soduto. All rights reserved.
//

import Foundation
import Network
import dnssd
import os

// MARK: - Delegate Protocol

/// Delegate protocol for receiving mDNS discovery events.
public protocol MDNSDiscoveryProviderDelegate: AnyObject {
    /// Called when a KDE Connect device is discovered via mDNS.
    /// - Parameters:
    ///   - provider: The MDNSDiscoveryProvider that discovered the device.
    ///   - address: The IP address of the discovered device.
    ///   - port: The TCP port the device is listening on.
    ///   - deviceId: The unique device identifier.
    func mdnsProvider(_ provider: MDNSDiscoveryProvider,
                      discoveredDeviceAt address: String,
                      port: UInt16,
                      deviceId: String)
}

// MARK: - MDNSDiscoveryProvider

/// Provides mDNS/Bonjour-based device discovery and advertisement for KDE Connect protocol.
///
/// This class advertises the local device as a `_kdeconnect._udp` service and browses
/// for other KDE Connect devices on the network. When a device is discovered, it notifies
/// the delegate which can trigger the existing UDP-based connection flow.
public class MDNSDiscoveryProvider {
    
    // MARK: Constants
    
    /// The Bonjour service type for KDE Connect.
    public static let serviceType = "_kdeconnect._udp"
    
    /// The domain for local network services.
    private static let serviceDomain = "local"
    
    // MARK: Properties
    
    /// The host configuration providing device identity information.
    private let config: HostConfiguration
    
    /// The NWBrowser for discovering other KDE Connect devices.
    private var browser: NWBrowser?
    
    /// DNS-SD service reference used for Bonjour advertisement.
    private var advertisementServiceRef: DNSServiceRef?
    
    /// Dispatch queue for browser operations.
    private let browserQueue = DispatchQueue(label: "com.soduto.MDNSBrowser")
    private static let browserQueueSpecificKey = DispatchSpecificKey<UInt8>()
    
    /// Set of discovered device IDs to avoid duplicate notifications.
    private var discoveredDeviceIds = Set<String>()
    
    /// Lock for thread-safe access to discoveredDeviceIds.
    private let lock = NSLock()
    
    /// The TCP port this device is listening on.
    private var tcpPort: UInt16 = 0
    
    /// Whether the provider is currently running.
    private var isRunning = false
    
    /// Delegate for discovery events.
    public weak var delegate: MDNSDiscoveryProviderDelegate?
    
    /// Callback for DNSServiceRegister result events.
    private static let serviceRegistrationCallback: DNSServiceRegisterReply = {
        _, _, errorCode, name, _, domain, context in
        guard let context = context else { return }
        let provider = Unmanaged<MDNSDiscoveryProvider>.fromOpaque(context).takeUnretainedValue()
        
        if errorCode == kDNSServiceErr_NoError {
            let resolvedName = name.map { String(cString: $0) } ?? provider.config.hostDeviceId
            let resolvedDomain = domain.map { String(cString: $0) } ?? MDNSDiscoveryProvider.serviceDomain
            Logger.network.info("mDNS registration confirmed: \(resolvedName, privacy: .public).\(resolvedDomain, privacy: .public)")
            return
        }
        
        Logger.network.error("mDNS registration callback error: \(errorCode, privacy: .public)")
        provider.stopAdvertising()
    }
    
    // MARK: Initialization
    
    /// Creates a new MDNSDiscoveryProvider.
    /// - Parameter config: The host configuration providing device identity.
    public init(config: HostConfiguration) {
        self.config = config
        self.browserQueue.setSpecific(key: type(of: self).browserQueueSpecificKey, value: 1)
    }
    
    deinit {
        stop()
    }
    
    // MARK: Public Methods
    
    /// Starts mDNS advertisement and discovery.
    /// - Parameter tcpPort: The TCP port this device is listening on.
    public func start(tcpPort: UInt16) {
        guard !isRunning else { return }
        
        self.tcpPort = tcpPort
        self.isRunning = true
        
        startAdvertising()
        startBrowsing()
        
        Logger.network.info("mDNS provider started on port \(tcpPort, privacy: .public)")
    }
    
    /// Stops mDNS advertisement and discovery.
    public func stop() {
        guard isRunning else { return }
        
        isRunning = false
        
        browser?.cancel()
        browser = nil
        
        stopAdvertising()
        
        lock.lock()
        discoveredDeviceIds.removeAll()
        lock.unlock()
        
        Logger.network.info("mDNS provider stopped")
    }
    
    // MARK: - Advertisement
    
    /// Starts advertising this device via Bonjour using DNSServiceRegister.
    private func startAdvertising() {
        var txtRecordRef = TXTRecordRef()
        TXTRecordCreate(&txtRecordRef, 0, nil)
        defer { TXTRecordDeallocate(&txtRecordRef) }
        
        let txtValues = [
            ("id", self.config.hostDeviceId),
            ("name", self.config.hostDeviceName),
            ("type", self.config.hostDeviceType.rawValue),
            ("protocol", String(DataPacket.protocolVersion)),
            ("port", String(self.tcpPort))
        ]
        
        for (key, value) in txtValues {
            let status = value.withCString { rawValue in
                TXTRecordSetValue(&txtRecordRef, key, UInt8(strlen(rawValue)), rawValue)
            }
            if status != kDNSServiceErr_NoError {
                Logger.network.error("mDNS TXT record setup failed for key \(key, privacy: .public): \(status, privacy: .public)")
                return
            }
        }
        
        let txtLength = UInt16(TXTRecordGetLength(&txtRecordRef))
        let txtBytes = TXTRecordGetBytesPtr(&txtRecordRef)
        
        var serviceRef: DNSServiceRef?
        let registrationError = DNSServiceRegister(
            &serviceRef,
            DNSServiceFlags(kDNSServiceFlagsIncludeP2P),
            0,
            self.config.hostDeviceId,
            MDNSDiscoveryProvider.serviceType,
            MDNSDiscoveryProvider.serviceDomain,
            nil,
            CFSwapInt16HostToBig(self.tcpPort),
            txtLength,
            txtBytes,
            MDNSDiscoveryProvider.serviceRegistrationCallback,
            Unmanaged.passUnretained(self).toOpaque()
        )
        
        guard registrationError == kDNSServiceErr_NoError, let activeRef = serviceRef else {
            Logger.network.error("mDNS registration failed: \(registrationError, privacy: .public)")
            return
        }
        
        let queueError = DNSServiceSetDispatchQueue(activeRef, self.browserQueue)
        guard queueError == kDNSServiceErr_NoError else {
            Logger.network.error("mDNS dispatch queue setup failed: \(queueError, privacy: .public)")
            DNSServiceRefDeallocate(activeRef)
            return
        }
        
        self.advertisementServiceRef = activeRef
        Logger.network.info("mDNS advertisement started for \(self.config.hostDeviceId, privacy: .public)")
    }
    
    /// Stops Bonjour advertisement if active.
    private func stopAdvertising() {
        guard let activeRef = self.advertisementServiceRef else { return }
        
        self.advertisementServiceRef = nil
        
        if DispatchQueue.getSpecific(key: type(of: self).browserQueueSpecificKey) != nil {
            DNSServiceRefDeallocate(activeRef)
        } else {
            self.browserQueue.sync {
                DNSServiceRefDeallocate(activeRef)
            }
        }
    }
    
    // MARK: - Discovery (NWBrowser)
    
    /// Starts browsing for other KDE Connect devices.
    private func startBrowsing() {
        let descriptor = NWBrowser.Descriptor.bonjour(
            type: MDNSDiscoveryProvider.serviceType,
            domain: MDNSDiscoveryProvider.serviceDomain
        )
        
        let parameters = NWParameters()
        parameters.includePeerToPeer = true
        
        browser = NWBrowser(for: descriptor, using: parameters)
        
        browser?.stateUpdateHandler = { [weak self] state in
            self?.handleBrowserState(state)
        }
        
        browser?.browseResultsChangedHandler = { [weak self] results, changes in
            self?.handleBrowseResults(results, changes: changes)
        }
        
        browser?.start(queue: browserQueue)
    }
    
    /// Handles browser state changes.
    private func handleBrowserState(_ state: NWBrowser.State) {
        switch state {
        case .setup:
            break
        case .ready:
            Logger.network.info("mDNS browser ready")
        case .failed(let error):
            Logger.network.error("mDNS browser failed: \(error, privacy: .public)")
            // Attempt restart after delay
            DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) { [weak self] in
                guard let self = self, self.isRunning else { return }
                self.browser?.cancel()
                self.startBrowsing()
            }
        case .cancelled:
            Logger.network.debug("mDNS browser cancelled")
        case .waiting(let error):
            Logger.network.notice("mDNS browser waiting: \(error, privacy: .public)")
        @unknown default:
            break
        }
    }
    
    /// Handles browse result changes.
    private func handleBrowseResults(_ results: Set<NWBrowser.Result>, changes: Set<NWBrowser.Result.Change>) {
        for change in changes {
            switch change {
            case .added(let result):
                handleDeviceDiscovered(result)
            case .removed(let result):
                handleDeviceRemoved(result)
            case .changed(old: _, new: let result, flags: _):
                handleDeviceDiscovered(result)
            case .identical:
                // No change, ignore
                break
            @unknown default:
                break
            }
        }
    }
    
    /// Handles a newly discovered device.
    private func handleDeviceDiscovered(_ result: NWBrowser.Result) {
        // Extract device ID from endpoint name (service name is the device ID)
        guard case .service(let name, _, _, _) = result.endpoint else {
            Logger.network.debug("mDNS discovery: unexpected endpoint type")
            return
        }
        
        // The service name is the device ID in KDE Connect
        let deviceId = name
        
        // Skip self-discovery
        guard deviceId != config.hostDeviceId else {
            return
        }
        
        // Try to get TXT record for port information
        var tcpPort: UInt16 = 1716  // Default KDE Connect port
        
        if case .bonjour(let txtRecord) = result.metadata {
            // Try to get port from TXT record
            if let portString = MDNSDiscoveryProvider.getTXTEntry(from: txtRecord, key: "port"),
               let port = UInt16(portString) {
                tcpPort = port
            }
        } else {
            // TXT record not available yet - this is common on initial discovery
            // We'll use the standard KDE Connect port and let UDP discovery handle it
            Logger.network.debug("mDNS discovery: TXT record not yet available for \(deviceId, privacy: .public), using default port")
        }
        
        // Check if we've already notified about this device
        lock.lock()
        let isNew = discoveredDeviceIds.insert(deviceId).inserted
        lock.unlock()
        
        guard isNew else {
            return
        }
        
        Logger.network.debug("mDNS discovered device: \(deviceId, privacy: .public) at \(result.endpoint.debugDescription, privacy: .public)")
        
        // Resolve the endpoint to get IP address
        resolveEndpoint(result.endpoint, deviceId: deviceId, tcpPort: tcpPort)
    }
    
    /// Handles a removed device.
    private func handleDeviceRemoved(_ result: NWBrowser.Result) {
        // Extract device ID from endpoint name
        guard case .service(let name, _, _, _) = result.endpoint else {
            return
        }
        
        let deviceId = name
        
        lock.lock()
        discoveredDeviceIds.remove(deviceId)
        lock.unlock()
        
        Logger.network.debug("mDNS device removed: \(deviceId, privacy: .public)")
    }
    
    // MARK: - Endpoint Resolution
    
    /// Resolves an NWEndpoint to an IP address.
    private func resolveEndpoint(_ endpoint: NWEndpoint, deviceId: String, tcpPort: UInt16) {
        // Resolve endpoint using Network framework path resolution.
        resolveEndpointAddress(endpoint: endpoint, deviceId: deviceId, tcpPort: tcpPort)
    }
    
    /// Resolves an mDNS endpoint to an IP address using NWConnection.
    /// Once resolved, notifies the delegate which will send UDP via the normal channel.
    /// Now supports link-local IPv6 addresses (e.g., "fe80::1234%en0") thanks to
    /// NetworkUtils.createSocketAddress() using getaddrinfo().
    private func resolveEndpointAddress(endpoint: NWEndpoint, deviceId: String, tcpPort: UInt16) {
        // Resolve using whatever interface is active (Wi-Fi, Ethernet, etc.).
        let parameters = NWParameters.udp
        
        // Create a temporary connection just to resolve the endpoint
        let connection = NWConnection(to: endpoint, using: parameters)
        
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                guard let self = self else {
                    connection.cancel()
                    return
                }
                
                // Extract the resolved IP address (including scope ID for link-local IPv6)
                if let path = connection.currentPath,
                   let remoteEndpoint = path.remoteEndpoint,
                   let ipAddress = self.extractIPAddress(from: remoteEndpoint) {
                    
                    Logger.network.debug("mDNS resolved \(deviceId, privacy: .public) to \(ipAddress, privacy: .public):\(tcpPort, privacy: .public)")
                    
                    // Notify delegate - it will send UDP via normal channel (port 1716)
                    // NetworkUtils.createSocketAddress() handles IPv6 scope IDs properly
                    DispatchQueue.main.async {
                        self.delegate?.mdnsProvider(self, discoveredDeviceAt: ipAddress, port: tcpPort, deviceId: deviceId)
                    }
                } else {
                    Logger.network.debug("mDNS: could not extract address for \(deviceId, privacy: .public)")
                }
                
                connection.cancel()
                
            case .failed(let error):
                Logger.network.debug("mDNS endpoint resolution failed for \(deviceId, privacy: .public): \(error, privacy: .public)")
                connection.cancel()
                
            case .cancelled:
                break
                
            default:
                break
            }
        }
        
        connection.start(queue: browserQueue)
        
        // Timeout resolution after 5 seconds
        browserQueue.asyncAfter(deadline: .now() + 5.0) {
            if connection.state != .cancelled {
                Logger.network.debug("mDNS endpoint resolution timeout for \(deviceId, privacy: .public)")
                connection.cancel()
            }
        }
    }
    
    /// Extracts an IP address string from an NWEndpoint.
    /// Returns the full address including scope ID for link-local IPv6 (e.g., "fe80::1234%en0").
    /// ConnectionProvider.sendDirectUdpPacket() now properly handles these via getaddrinfo().
    private func extractIPAddress(from endpoint: NWEndpoint) -> String? {
        switch endpoint {
        case .hostPort(let host, _):
            switch host {
            case .ipv4(let addr):
                return "\(addr)"
            case .ipv6(let addr):
                // Return the full address string including scope ID (e.g., %en0)
                // Our NetworkUtils.createSocketAddress() uses getaddrinfo() which
                // properly handles IPv6 scope IDs for link-local addresses
                return "\(addr)"
            default:
                return nil
            }
        default:
            return nil
        }
    }
}

// MARK: - NWTXTRecord Helper

extension MDNSDiscoveryProvider {
    /// Gets a string value for a key from the TXT record.
    /// NWTXTRecord subscript returns String? directly.
    static func getTXTEntry(from txtRecord: NWTXTRecord, key: String) -> String? {
        return txtRecord[key]
    }
}
