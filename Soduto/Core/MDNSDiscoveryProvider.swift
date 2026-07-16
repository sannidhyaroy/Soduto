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
    
    /// Asks whether a connection to the given device is currently wanted.
    /// Used by the periodic reconnect knock to skip devices that are already connected or that should not be dialed automatically.
    func mdnsProvider(_ provider: MDNSDiscoveryProvider,
                      needsConnectionTo deviceId: String) -> Bool
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
    
    /// Interval between reconnect knocks for visible-but-unconnected devices.
    /// Also the initial per-device knock backoff interval.
    private static let knockInterval: TimeInterval = 10.0
    
    /// Cap for the per-device knock backoff (doubles per knock: 10s, 20s, 40s, 60s).
    private static let knockMaxInterval: TimeInterval = 60.0
    
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
    
    /// Timer driving the periodic reconnect knock.
    private var knockTimer: DispatchSourceTimer?
    
    /// Per-device knock backoff (guarded by `lock`): the earliest time of the next knock, and the interval to apply after it fires.
    /// Reset when the device's browse record changes or it no longer needs a connection, so a returning device is always knocked promptly.
    private var knockBackoff: [String: (nextKnock: Date, interval: TimeInterval)] = [:]
    
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
        startKnockTimer()
        
        Logger.network.info("mDNS provider started on port \(tcpPort, privacy: .public)")
    }
    
    /// Stops mDNS advertisement and discovery.
    public func stop() {
        guard isRunning else { return }
        
        isRunning = false
        
        knockTimer?.cancel()
        knockTimer = nil
        browseService.stop()
        advertisementService.stop()
        
        lock.lock()
        discoveredDeviceIds.removeAll()
        knockBackoff.removeAll()
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
    
    private func startKnockTimer() {
        let timer = DispatchSource.makeTimerSource(queue: browserQueue)
        timer.schedule(deadline: .now() + type(of: self).knockInterval,
                       repeating: type(of: self).knockInterval)
        timer.setEventHandler { [weak self] in
            self?.knockUnconnectedDevices()
        }
        timer.resume()
        self.knockTimer = timer
    }
    
    /// Re-triggers connection attempts for devices that are visible in the browser's current results but not connected.
    /// Browse events are one-shot: a device that leaves the network for less than its record TTL produces no `.removed`/`.added` when it returns, and an event that fired while a connection still existed is discarded by the delegate's gate.
    /// Either way a visible device can end up unconnected with no future event to recover it, so we periodically re-drive the normal discovery flow for any result the delegate still wants a connection to.
    private func knockUnconnectedDevices() {
        guard isRunning else { return }
        let results = browseService.currentResults
        guard !results.isEmpty else { return }
        
        DispatchQueue.main.async { [weak self] in
            guard let self = self, self.isRunning else { return }
            for result in results {
                guard case .service(let name, _, _, _) = result.endpoint else { continue }
                guard name != self.config.hostDeviceId else { continue }
                guard self.delegate?.mdnsProvider(self, needsConnectionTo: name) == true else {
                    // Connected (or not knockable): clear any backoff so a later disconnect starts knocking promptly again
                    self.lock.lock()
                    self.knockBackoff.removeValue(forKey: name)
                    self.lock.unlock()
                    continue
                }
                
                // Per-device backoff: a device that keeps failing to resolve is most likely gone with a stale record lingering in the cache
                // Knock it less and less often until the record is evicted
                self.lock.lock()
                let now = Date()
                let state = self.knockBackoff[name]
                let due = state.map { now >= $0.nextKnock } ?? true
                if due {
                    let interval = state?.interval ?? type(of: self).knockInterval
                    let nextInterval = min(interval * 2, type(of: self).knockMaxInterval)
                    self.knockBackoff[name] = (nextKnock: now.addingTimeInterval(interval), interval: nextInterval)
                }
                self.lock.unlock()
                guard due else { continue }
                
                Logger.network.info("mDNS knock: \(name, privacy: .public) visible but not connected — re-triggering connection")
                self.handleDeviceDiscovered(result)
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
        knockBackoff.removeValue(forKey: name)
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
                resetKnockBackoff(for: result)
                handleDeviceDiscovered(result)
            case .removed(let result):
                handleDeviceRemoved(result)
            case .changed(old: _, new: let result, flags: _):
                resetKnockBackoff(for: result)
                handleDeviceDiscovered(result)
            case .identical:
                break
            @unknown default:
                break
            }
        }
    }
    
    /// Clears knock backoff on a real browse event.
    /// A record that just changed is fresh evidence the device may be back, so it should be knocked promptly.
    private func resetKnockBackoff(for result: NWBrowser.Result) {
        guard case .service(let name, _, _, _) = result.endpoint else { return }
        lock.lock()
        knockBackoff.removeValue(forKey: name)
        lock.unlock()
    }
}

// MARK: - MDNSEndpointResolverDelegate

extension MDNSDiscoveryProvider: MDNSEndpointResolverDelegate {
    func mdnsEndpointResolver(_ resolver: MDNSEndpointResolver, didResolveAddress address: String, forDeviceId deviceId: String, tcpPort: UInt16) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.delegate?.mdnsProvider(self, discoveredDeviceAt: address, port: tcpPort, deviceId: deviceId)
        }
    }
}
