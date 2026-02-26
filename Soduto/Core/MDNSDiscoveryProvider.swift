//
//  MDNSDiscoveryProvider.swift
//  Soduto
//
//  Created by Sannidhya Roy on 21/02/26.
//  Copyright © 2026 Soduto. All rights reserved.
//

import Foundation
import Network
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
    
    /// Default TCP port when TXT record is not available yet.
    private static let defaultTcpPort: UInt16 = 1716
    
    /// Delay before restarting browsing after a failure.
    private static let browseRestartDelay: TimeInterval = 5.0
    
    // MARK: Properties
    
    /// The host configuration providing device identity information.
    private let config: HostConfiguration
    
    /// Dispatch queue for browse, advertisement, and endpoint resolution operations.
    private let browserQueue = DispatchQueue(label: "com.soduto.MDNSBrowser")
    
    /// Dedicated mDNS advertisement service (DNS-SD registration wrapper).
    private lazy var advertisementService: MDNSAdvertisementService = {
        let service = MDNSAdvertisementService(queue: self.browserQueue)
        service.delegate = self
        return service
    }()
    
    /// Dedicated mDNS browse service (NWBrowser wrapper).
    private lazy var browseService: MDNSBrowseService = {
        let service = MDNSBrowseService(queue: self.browserQueue)
        service.delegate = self
        return service
    }()
    
    /// Dedicated endpoint resolver for service endpoints.
    private lazy var endpointResolver: MDNSEndpointResolver = {
        let resolver = MDNSEndpointResolver(queue: self.browserQueue)
        resolver.delegate = self
        return resolver
    }()
    
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
    
    // MARK: Initialization
    
    /// Creates a new MDNSDiscoveryProvider.
    /// - Parameter config: The host configuration providing device identity.
    public init(config: HostConfiguration) {
        self.config = config
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
        
        browseService.stop()
        advertisementService.stop()
        
        lock.lock()
        discoveredDeviceIds.removeAll()
        lock.unlock()
        
        Logger.network.info("mDNS provider stopped")
    }
    
    // MARK: Private Methods
    
    private func startAdvertising() {
        let started = advertisementService.start(
            deviceId: config.hostDeviceId,
            deviceName: config.hostDeviceName,
            deviceType: config.hostDeviceType.rawValue,
            protocolVersion: DataPacket.protocolVersion,
            tcpPort: tcpPort,
            serviceType: type(of: self).serviceType,
            serviceDomain: type(of: self).serviceDomain
        )
        
        if started {
            Logger.network.info("mDNS advertisement started for \(self.config.hostDeviceId, privacy: .public)")
        }
    }
    
    private func startBrowsing() {
        browseService.start(serviceType: type(of: self).serviceType, serviceDomain: type(of: self).serviceDomain)
    }
    
    private func scheduleBrowseRestart() {
        browserQueue.asyncAfter(deadline: .now() + type(of: self).browseRestartDelay) { [weak self] in
            guard let self = self, self.isRunning else { return }
            self.startBrowsing()
        }
    }
    
    /// Handles a newly discovered device.
    private func handleDeviceDiscovered(_ result: NWBrowser.Result) {
        // Extract device ID from endpoint name (service name is the device ID)
        guard case .service(let name, _, _, _) = result.endpoint else {
            Logger.network.debug("mDNS discovery: unexpected endpoint type")
            return
        }
        
        let deviceId = name
        
        // Skip self-discovery
        guard deviceId != config.hostDeviceId else { return }
        
        // Try to get TCP port from TXT record, otherwise fall back to default KDE Connect port.
        var discoveredTcpPort = type(of: self).defaultTcpPort
        if case .bonjour(let txtRecord) = result.metadata {
            if let portString = txtRecord["port"],
               let parsedPort = UInt16(portString) {
                discoveredTcpPort = parsedPort
            }
        } else {
            Logger.network.debug("mDNS discovery: TXT record not yet available for \(deviceId, privacy: .public), using default port")
        }
        
        lock.lock()
        let isNew = discoveredDeviceIds.insert(deviceId).inserted
        lock.unlock()
        
        if isNew {
            Logger.network.debug("mDNS discovered new device: \(deviceId, privacy: .public) at \(result.endpoint.debugDescription, privacy: .public)")
        } else {
            Logger.network.debug("mDNS re-resolving changed device: \(deviceId, privacy: .public) at \(result.endpoint.debugDescription, privacy: .public)")
        }
        
        endpointResolver.resolve(endpoint: result.endpoint, deviceId: deviceId, tcpPort: discoveredTcpPort)
    }
    
    /// Handles a removed device.
    private func handleDeviceRemoved(_ result: NWBrowser.Result) {
        guard case .service(let name, _, _, _) = result.endpoint else { return }
        
        lock.lock()
        discoveredDeviceIds.remove(name)
        lock.unlock()
        
        Logger.network.debug("mDNS device removed: \(name, privacy: .public)")
    }
}

// MARK: - MDNSAdvertisementServiceDelegate

extension MDNSDiscoveryProvider: MDNSAdvertisementServiceDelegate {
    func mdnsAdvertisementService(_ service: MDNSAdvertisementService, didRegisterWithName name: String, domain: String) {
        let resolvedName = name.isEmpty ? self.config.hostDeviceId : name
        let resolvedDomain = domain.isEmpty ? type(of: self).serviceDomain : domain
        Logger.network.info("mDNS registration confirmed: \(resolvedName, privacy: .public).\(resolvedDomain, privacy: .public)")
    }
    
    func mdnsAdvertisementService(_ service: MDNSAdvertisementService, didFailWithErrorCode errorCode: Int32) {
        Logger.network.error("mDNS registration failed: \(errorCode, privacy: .public)")
        if isRunning {
            advertisementService.stop()
        }
    }
}

// MARK: - MDNSBrowseServiceDelegate

extension MDNSDiscoveryProvider: MDNSBrowseServiceDelegate {
    func mdnsBrowseService(_ service: MDNSBrowseService, didUpdateState state: NWBrowser.State) {
        switch state {
        case .setup:
            break
        case .ready:
            Logger.network.info("mDNS browser ready")
        case .failed(let error):
            Logger.network.error("mDNS browser failed: \(error, privacy: .public)")
            scheduleBrowseRestart()
        case .cancelled:
            Logger.network.debug("mDNS browser cancelled")
        case .waiting(let error):
            Logger.network.notice("mDNS browser waiting: \(error, privacy: .public)")
        @unknown default:
            break
        }
    }
    
    func mdnsBrowseService(_ service: MDNSBrowseService, didReceiveChanges changes: Set<NWBrowser.Result.Change>) {
        for change in changes {
            switch change {
            case .added(let result):
                handleDeviceDiscovered(result)
            case .removed(let result):
                handleDeviceRemoved(result)
            case .changed(old: _, new: let result, flags: _):
                handleDeviceDiscovered(result)
            case .identical:
                break
            @unknown default:
                break
            }
        }
    }
}

// MARK: - MDNSEndpointResolverDelegate

extension MDNSDiscoveryProvider: MDNSEndpointResolverDelegate {
    func mdnsEndpointResolver(_ resolver: MDNSEndpointResolver, didResolveAddress address: String, forDeviceId deviceId: String, tcpPort: UInt16) {
        DispatchQueue.main.async {
            self.delegate?.mdnsProvider(self, discoveredDeviceAt: address, port: tcpPort, deviceId: deviceId)
        }
    }
}
