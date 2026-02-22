//
//  ConnectionProvider.swift
//  Soduto
//
//  Created by Admin on 2016-08-02.
//  Copyright © 2016 Soduto. All rights reserved.
//

import Foundation
import Cocoa
import Network
import NIOCore
import NIOPosix
import os

enum ConnectionProviderError: Error {
    case IdentityAbsent
}

public protocol ConnectionProviderDelegate: AnyObject {
    func isNewConnectionNeeded(byProvider provider: ConnectionProvider, deviceId: String) -> Bool
    func connectionProvider(_ provider: ConnectionProvider, didCreateConnection: Connection)
}

public class ConnectionProvider: NSObject, ConnectionDelegate {
    
    static public let udpPort: UInt16 = 1716
    static public let minTcpPort: UInt16 = 1716
    static public let maxTcpPort: UInt16 = 1764
    static public let minVersionWithSSLSupport: UInt = 6
    static public let broadcastAnnouncementNotification: Notification.Name = Notification.Name(rawValue: "com.soduto.ConnectionProvider.broadcastAnnouncement")
    static public let networkBecameReachableNotification: Notification.Name = Notification.Name(rawValue: "com.soduto.ConnectionProvider.networkBecameReachable")
    
    public weak var delegate: ConnectionProviderDelegate? = nil
    
    private let config: ConnectionConfiguration
    private let pathMonitor: NWPathMonitor = NWPathMonitor()
    private let pathMonitorQueue: DispatchQueue = DispatchQueue(label: "com.soduto.NetworkMonitor")
    private var pendingConnections: Set<Connection> = Set<Connection>()
    private var isStarted: Bool = false
    
    /// Timestamp when network services were last started (for cooldown).
    private var lastStartTime: Date?
    
    /// Minimum time between network restarts to avoid race conditions.
    private static let restartCooldown: TimeInterval = 3.0
    
    // MARK: Network Properties
    
    /// Event loop group for network operations.
    private var eventLoopGroup: MultiThreadedEventLoopGroup?
    
    /// UDP channel for receiving broadcasts (dual-stack for IPv6 support).
    private var udpChannel: Channel?
    
    /// Dedicated IPv4 UDP channel for sending broadcasts (SO_BROADCAST requires IPv4).
    private var broadcastChannel: Channel?
    
    /// TCP server channel for accepting connections.
    private var tcpServerChannel: Channel?
    
    /// The port the TCP server is listening on.
    private var tcpListeningPort: UInt16 = 0
    
    /// mDNS discovery provider for instant device discovery.
    private var mdnsProvider: MDNSDiscoveryProvider?
    
    
    
    init(config: ConnectionConfiguration) {
        self.config = config
        
        super.init()
        
        self.pathMonitor.pathUpdateHandler = { [weak self] path in
            DispatchQueue.main.async {
                if path.status == .satisfied {
                    self?.becameReachable()
                } else {
                    self?.becameUnreachable()
                }
            }
        }
        
        NotificationCenter.default.addObserver(self, selector: #selector(broadcastAnnouncement), name: ConnectionProvider.broadcastAnnouncementNotification, object: nil)
    }
    
    deinit {
        self.pathMonitor.cancel()
        NotificationCenter.default.removeObserver(self)
        
        // Shutdown NIO event loop group
        try? self.eventLoopGroup?.syncShutdownGracefully()
    }
    
    public func start() {
        // Only start monitoring network reachability.
        // Actual network services (UDP, TCP, mDNS) are started by becameReachable()
        // when NWPathMonitor confirms the network is available.
        self.pathMonitor.start(queue: self.pathMonitorQueue)
    }
    
    public func stop() {
        self.pathMonitor.cancel()
        stopNetworkServices()
    }
    
    public func restart() {
        guard self.isStarted else { return }
        stopNetworkServices()
        startNetworkServices()
    }
    
    // MARK: - Network Services Lifecycle
    
    /// Starts all network services (UDP, TCP, mDNS) and broadcasts announcement.
    private func startNetworkServices() {
        self.lastStartTime = Date()
        
        // Listen for device announcement broadcasts
        startUdp()
        
        // Listen for connections on TCP
        startTcpServer()
        
        self.isStarted = true
        
        // Start mDNS discovery after TCP server is ready
        startMDNS()
        
        // Broadcast our presence
        broadcastAnnouncement()
    }
    
    /// Stops all network services.
    private func stopNetworkServices() {
        self.isStarted = false
        stopMDNS()
        stopUdp()
        stopTcpServer()
    }
    
    public func restart() {
        guard self.isStarted else { return }
        self.stop()
        self.start()
    }
    
    
    // MARK: Announcements broadcasting
    
    @objc public dynamic func broadcastAnnouncement() {
        guard self.isStarted else { return }
        
        guard self.tcpListeningPort > 0 else { return }
        let tcpPort = self.tcpListeningPort
        
        Logger.network.debug("Broadcasting self-announcement")
        
        // Try to fill ARP table with all reachable addresses
        NetworkUtils.pingLocalNetwork()
        
        let properties: DataPacket.Body = [
            DataPacket.IdentityProperty.tcpPort.rawValue: Int(tcpPort) as AnyObject
        ]
        let packet = DataPacket.identityPacket(additionalProperties: properties, config: self.config)
        sendBroadcast(packet: packet)
    }
    
    /// Sends the identity packet as a UDP broadcast.
    /// Uses the dedicated IPv4 broadcast channel (SO_BROADCAST only works on IPv4 sockets).
    private func sendBroadcast(packet: DataPacket) {
        guard let channel = self.broadcastChannel else {
            Logger.network.error("Broadcast channel not available")
            return
        }
        guard let bytes = try? packet.serialize() else { return }
        
        // Get local interfaces and broadcast to each interface's broadcast address
        let localAddresses = NetworkUtils.localAddresses()
        var broadcastCount = 0
        
        for addressInfo in localAddresses {
            // Only support IPv4 broadcast
            guard addressInfo.ip.isIPv4 else { continue }
            guard addressInfo.netmask.isIPv4 else { continue }
            
            // Calculate broadcast address: IP | ~netmask
            let ipAddr = addressInfo.ip.ipv4.sin_addr.s_addr
            let netmask = addressInfo.netmask.ipv4.sin_addr.s_addr
            let broadcastAddr = ipAddr | ~netmask
            
            // Convert to string
            let addr = in_addr(s_addr: broadcastAddr)
            guard let broadcastString = String(cString: inet_ntoa(addr), encoding: .ascii) else { continue }
            
            do {
                let broadcastAddress = try NIOCore.SocketAddress(ipAddress: broadcastString, port: Int(ConnectionProvider.udpPort))
                var buffer = channel.allocator.buffer(capacity: bytes.count)
                buffer.writeBytes(bytes)
                let envelope = AddressedEnvelope(remoteAddress: broadcastAddress, data: buffer)
                channel.writeAndFlush(envelope).whenFailure { error in
                    Logger.network.debug("UDP broadcast to \(broadcastString, privacy: .public) failed: \(error, privacy: .public)")
                }
                broadcastCount += 1
            } catch {
                Logger.network.error("Failed to create broadcast address for \(broadcastString, privacy: .public): \(error, privacy: .public)")
            }
        }
        
        if broadcastCount > 0 {
            Logger.network.debug("Sent UDP broadcast to \(broadcastCount, privacy: .public) interface(s)")
        } else {
            Logger.network.notice("No suitable interfaces found for UDP broadcast")
        }
        
        // Send explicit announcements to known hardware addresses
        guard channel.isActive else {
            Logger.network.debug("Broadcast channel closed, skipping known device announcements")
            return
        }
        
        let knownDeviceConfigs = self.config.knownDeviceConfigs()
        let accessibleAddresses = (try? NetworkUtils.accessibleIPv4Addresses()) ?? []
        for accessibleAddress in accessibleAddresses {
            guard let accessibleHwAddress = accessibleAddress.hwAddressString else { continue }
            for deviceConfig in knownDeviceConfigs {
                guard deviceConfig.hwAddresses.contains(accessibleHwAddress) else { continue }
                do {
                    let deviceAddress = try NIOCore.SocketAddress(ipAddress: accessibleAddress.ipAddressString, port: Int(ConnectionProvider.udpPort))
                    var deviceBuffer = channel.allocator.buffer(capacity: bytes.count)
                    deviceBuffer.writeBytes(bytes)
                    let envelope = AddressedEnvelope(remoteAddress: deviceAddress, data: deviceBuffer)
                    channel.writeAndFlush(envelope).whenFailure { error in
                        Logger.network.debug("UDP send to known device \(accessibleAddress.ipAddressString, privacy: .public) failed: \(error, privacy: .public)")
                    }
                } catch {
                    Logger.network.error("Failed to create address for known device: \(error, privacy: .public)")
                }
                break
            }
        }
    }
    
    
    // MARK: ConnectionDelegate
    
    public func connection(_ connection: Connection, didSwitchToState state: Connection.State) {
        Logger.network.debug("connection(<\(String(describing: connection), privacy: .public)> switchedToState:<\(String(describing: state), privacy: .public)>)")
        switch state {
        case .Closed:
            self.pendingConnections.remove(connection)
        case .Open:
            if let delegate = self.delegate {
                connection.readPackets()
                self.pendingConnections.remove(connection)
                delegate.connectionProvider(self, didCreateConnection: connection)
            } else {
                Logger.network.error("No connection provider delegate to take new connection - closing")
                connection.close()
            }
        default:
            break
        }
    }
    
    public func connection(_ connection: Connection, didSendPacket packet: DataPacket, uploadedPayload: Bool) {
        Logger.network.debug("connection(<\(connection, privacy: .public)> didSendPacket:<\(packet, privacy: .public)>)")
        
        // After sending identity packet (outgoing connection), secure as server
        do {
            guard let identity = connection.identity else { throw ConnectionProviderError.IdentityAbsent }
            let protocolVersion = try identity.getProtocolVersion()
            if protocolVersion >= ConnectionProvider.minVersionWithSSLSupport {
                // Beware that securing as server while connection initiated by self
                connection.secureServer()
            }
            connection.finishInitialization()
        }
        catch {
            Logger.network.error("Failed to initialize connection: \(error, privacy: .public)")
            connection.close()
        }
    }
    
    public func connection(_ connection: Connection, didReadPacket packet: DataPacket) {
        Logger.network.debug("connection(<\(connection, privacy: .public)> didReadPacket:<\(packet.type, privacy: .public)>)")
        
        // Only process identity packet during initialization
        guard connection.state == .Initializing else {
            return
        }
        
        // The only packet we are waiting for is first identity packet to initialize connection with
        do {
            try connection.applyIdentity(packet: packet)
            let protocolVersion = try packet.getProtocolVersion()
            if protocolVersion >= ConnectionProvider.minVersionWithSSLSupport {
                // Beware that securing as client while connection initiated by the peer
                connection.secureClient()
            }
            connection.finishInitialization()
        }
        catch {
            Logger.network.error("Failed to initialize connection: \(error, privacy: .public)")
            connection.close()
        }
    }
    
    public func connectionCapacityChanged(_ connection: Connection) { }
    
    
    // MARK: - UDP Implementation
    
    /// Starts the UDP channels for receiving and sending.
    /// Creates two sockets:
    /// - Main socket: dual-stack (::) for receiving and IPv6 sends (mDNS link-local)
    /// - Broadcast socket: IPv4-only (0.0.0.0) for sending broadcasts (SO_BROADCAST requires IPv4)
    private func startUdp() {
        // Create event loop group if needed
        if self.eventLoopGroup == nil {
            self.eventLoopGroup = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        }
        
        guard let group = self.eventLoopGroup else {
            Logger.network.error("Failed to create event loop group")
            return
        }
        
        // Main UDP socket - dual-stack for receiving and IPv6 sends
        let mainBootstrap = DatagramBootstrap(group: group)
            .channelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .channelOption(ChannelOptions.Types.SocketOption(level: SOL_SOCKET, name: SO_REUSEPORT), value: 1)
            .channelInitializer { [weak self] channel in
                guard let self = self else {
                    return channel.eventLoop.makeSucceededVoidFuture()
                }
                let handler = UdpHandler(connectionProvider: self, config: self.config)
                return channel.pipeline.addHandler(handler)
            }
        
        do {
            // Bind to IPv6 any address (::) which creates a dual-stack socket
            // This allows receiving both IPv4 and IPv6, including link-local IPv6
            let channel = try mainBootstrap.bind(host: "::", port: Int(ConnectionProvider.udpPort)).wait()
            self.udpChannel = channel
            Logger.network.info("Listening for UDP broadcasts on port \(ConnectionProvider.udpPort, privacy: .public)")
        } catch {
            // Fallback to IPv4-only if IPv6 dual-stack fails
            Logger.network.notice("IPv6 dual-stack UDP failed, falling back to IPv4: \(error, privacy: .public)")
            do {
                let channel = try mainBootstrap.bind(host: "0.0.0.0", port: Int(ConnectionProvider.udpPort)).wait()
                self.udpChannel = channel
                Logger.network.info("Listening for UDP broadcasts on port \(ConnectionProvider.udpPort, privacy: .public) (IPv4 only)")
            } catch {
                Logger.network.error("Failed to start main UDP: \(error, privacy: .public)")
            }
        }
        
        // Broadcast socket - IPv4-only with SO_BROADCAST for sending broadcasts
        // SO_BROADCAST only works on IPv4 sockets, not dual-stack
        let broadcastBootstrap = DatagramBootstrap(group: group)
            .channelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .channelOption(ChannelOptions.socketOption(.so_broadcast), value: 1)
        
        do {
            // Bind to any available port (port 0) - we only send from this socket
            let channel = try broadcastBootstrap.bind(host: "0.0.0.0", port: 0).wait()
            self.broadcastChannel = channel
            Logger.network.debug("Broadcast UDP socket ready")
        } catch {
            Logger.network.error("Failed to start broadcast UDP: \(error, privacy: .public)")
        }
    }
    
    /// Stops the UDP channels.
    private func stopUdp() {
        self.udpChannel?.close(promise: nil)
        self.udpChannel = nil
        self.broadcastChannel?.close(promise: nil)
        self.broadcastChannel = nil
    }
    
    /// Ensures the UDP channel is active, restarting if needed.
    /// Returns true if channel is available for use.
    private func ensureUdpChannelActive() -> Bool {
        if let channel = self.udpChannel, channel.isActive {
            return true
        }
        
        // Channel is nil or inactive - restart it
        Logger.network.notice("UDP channel inactive, restarting...")
        stopUdp()
        startUdp()
        return self.udpChannel?.isActive ?? false
    }
    
    /// Handles incoming UDP packet.
    fileprivate func handleUdpPacket(data: Data, remoteAddress: NIOCore.SocketAddress) {
        guard let delegate = self.delegate else { return }
        guard let packet = DataPacket(data: data) else { return }
        guard let port = try? packet.getTCPPort() else { return }
        guard let deviceId = try? packet.getDeviceId() else { return }
        guard delegate.isNewConnectionNeeded(byProvider: self, deviceId: deviceId) else { return }
        
#if DEBUG
        Logger.network.debug("UDP received packet from \(String(describing: remoteAddress), privacy: .public): \(packet, privacy: .public)")
#else
        Logger.network.debug("UDP received packet from \(String(describing: remoteAddress), privacy: .public) deviceId: \(deviceId, privacy: .public)")
#endif
        
        // Create a socket address for the connection
        guard let connectionAddress = convertToSocketAddress(remoteAddress, port: UInt16(port)) else {
            Logger.network.error("Failed to convert address to SocketAddress")
            return
        }
        
        // Dispatch to main queue for connection creation
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.createOutgoingConnection(address: connectionAddress, identityPacket: packet)
        }
    }
    
    /// Creates an outgoing connection to the specified address.
    private func createOutgoingConnection(address: SocketAddress, identityPacket packet: DataPacket) {
        guard let group = self.eventLoopGroup else {
            Logger.network.error("No event loop group available for outgoing connection")
            return
        }
        
        if let connection = Connection(address: address, identityPacket: packet, config: self.config, eventLoopGroup: group) {
            Logger.network.debug("Created outgoing connection to \(address.description, privacy: .public)")
            connection.delegate = self
            self.pendingConnections.insert(connection)
            
            // Send initial identity packet
            _ = connection.send(DataPacket.identityPacket(config: self.config))
        } else {
            Logger.network.error("Failed to create outgoing connection")
        }
    }
    
    /// Converts a NIOCore.SocketAddress to SocketAddress.
    private func convertToSocketAddress(_ address: NIOCore.SocketAddress, port: UInt16) -> SocketAddress? {
        switch address {
        case .v4(let addr):
            var socketAddress = SocketAddress(addr: addr.address)
            socketAddress.port = in_port_t(port)
            return socketAddress
        case .v6(let addr):
            var socketAddress = SocketAddress(addr: addr.address)
            socketAddress.port = in_port_t(port)
            return socketAddress
        default:
            return nil
        }
    }
    
    // MARK: - TCP Server Implementation
    
    /// Starts the TCP server for accepting incoming connections.
    private func startTcpServer() {
        // Create event loop group if needed (shared with UDP)
        if self.eventLoopGroup == nil {
            self.eventLoopGroup = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        }
        
        guard let group = self.eventLoopGroup else {
            Logger.network.error("Failed to create event loop group for TCP server")
            return
        }
        
        let bootstrap = ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .withChildTCPKeepalive()
            .childChannelInitializer { [weak self] channel in
                guard let self = self else {
                    return channel.eventLoop.makeSucceededVoidFuture()
                }
                let handler = TcpConnectionHandler(connectionProvider: self, config: self.config)
                return channel.pipeline.addHandler(handler)
            }
        
        // Try to bind to a port in the KDE Connect range
        // Use IPv6 dual-stack (::) to accept both IPv4 and IPv6 connections,
        // including link-local IPv6 (required when phone connects back to us)
        for port in ConnectionProvider.minTcpPort...ConnectionProvider.maxTcpPort {
            do {
                let channel = try bootstrap.bind(host: "::", port: Int(port)).wait()
                self.tcpServerChannel = channel
                self.tcpListeningPort = port
                Logger.network.info("Listening for TCP connections on port \(port, privacy: .public)")
                return
            } catch let ipv6Error {
                // IPv6 dual-stack failed, try IPv4-only fallback
                do {
                    let channel = try bootstrap.bind(host: "0.0.0.0", port: Int(port)).wait()
                    self.tcpServerChannel = channel
                    self.tcpListeningPort = port
                    Logger.network.notice("IPv6 TCP failed (\(ipv6Error, privacy: .public)), using IPv4 on port \(port, privacy: .public)")
                    return
                } catch {
                    // Port in use, try next
                    continue
                }
            }
        }
        
        Logger.network.error("Failed to start TCP server on ports \(ConnectionProvider.minTcpPort, privacy: .public)-\(ConnectionProvider.maxTcpPort, privacy: .public)")
    }
    
    /// Stops the TCP server.
    private func stopTcpServer() {
        self.tcpServerChannel?.close(promise: nil)
        self.tcpServerChannel = nil
        self.tcpListeningPort = 0
    }
    
    // MARK: - mDNS Implementation
    
    /// Starts mDNS discovery and advertisement.
    private func startMDNS() {
        guard self.tcpListeningPort > 0 else {
            Logger.network.notice("Cannot start mDNS: TCP server not ready")
            return
        }
        
        self.mdnsProvider = MDNSDiscoveryProvider(config: self.config)
        self.mdnsProvider?.delegate = self
        self.mdnsProvider?.start(tcpPort: self.tcpListeningPort)
    }
    
    /// Stops mDNS discovery and advertisement.
    private func stopMDNS() {
        self.mdnsProvider?.stop()
        self.mdnsProvider = nil
    }
    
    /// Sends a UDP identity packet to a specific address (triggered by mDNS discovery).
    /// Supports IPv6 link-local addresses with scope IDs (e.g., "fe80::1234%en0").
    private func sendDirectUdpPacket(to address: String) {
        // Ensure UDP channel is active (may have been closed by broadcast errors)
        guard ensureUdpChannelActive(), let channel = self.udpChannel else {
            Logger.network.error("UDP channel not available for direct send")
            return
        }
        guard self.tcpListeningPort > 0 else { return }
        
        let properties: DataPacket.Body = [
            DataPacket.IdentityProperty.tcpPort.rawValue: Int(self.tcpListeningPort) as AnyObject
        ]
        let packet = DataPacket.identityPacket(additionalProperties: properties, config: self.config)
        
        guard let bytes = try? packet.serialize() else { return }
        
        // Use NetworkUtils helper which properly handles IPv6 scope IDs
        guard let targetAddress = NetworkUtils.createSocketAddress(address: address, port: Int(ConnectionProvider.udpPort)) else {
            Logger.network.error("Failed to create target address for mDNS discovery: \(address, privacy: .public)")
            return
        }
        
        var buffer = channel.allocator.buffer(capacity: bytes.count)
        buffer.writeBytes(bytes)
        let envelope = AddressedEnvelope(remoteAddress: targetAddress, data: buffer)
        
        channel.writeAndFlush(envelope).whenComplete { result in
            switch result {
            case .success:
                Logger.network.debug("mDNS-triggered UDP sent to \(address, privacy: .public)")
            case .failure(let error):
                Logger.network.debug("mDNS-triggered UDP send to \(address, privacy: .public) failed: \(error, privacy: .public)")
            }
        }
    }
    
    /// Handles a new TCP connection accepted by the server.
    fileprivate func handleTcpConnection(channel: Channel, remoteAddress: NIOCore.SocketAddress) {
        Logger.network.debug("TCP accepted connection from \(String(describing: remoteAddress), privacy: .public)")
        
        guard let group = self.eventLoopGroup else {
            Logger.network.error("No event loop group available for connection")
            channel.close(promise: nil)
            return
        }
        
        // Create connection from the accepted channel
        if let connection = Connection(channel: channel, config: self.config, eventLoopGroup: group) {
            connection.delegate = self
            self.pendingConnections.insert(connection)
            
            // Read initial identity packet
            connection.readOnePacket()
        } else {
            Logger.network.error("Failed to create connection from channel")
            channel.close(promise: nil)
        }
    }
    
    // MARK: Private methods
    
    private func becameReachable() {
        Logger.network.debug("Network became reachable")
        NotificationCenter.default.post(name: ConnectionProvider.networkBecameReachableNotification, object: self)
        
        if self.isStarted {
            // Check cooldown to avoid race conditions from rapid NWPathMonitor callbacks
            if let lastStart = self.lastStartTime,
               Date().timeIntervalSince(lastStart) < ConnectionProvider.restartCooldown {
                // Schedule restart after cooldown expires
                let delay = ConnectionProvider.restartCooldown - Date().timeIntervalSince(lastStart)
                Logger.network.debug("Network services recently started, delaying restart by \(delay, privacy: .public)s")
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                    self?.restart()
                }
                return
            }
            
            // Network changed (e.g., WiFi → Ethernet) - restart to pick up new interfaces
            Logger.network.debug("Network change detected - restarting network services")
            stopNetworkServices()
        }
        
        startNetworkServices()
    }
    
    private func becameUnreachable() {
        Logger.network.debug("Network became unreachable")
        // Optionally stop services when network is down
        // For now, keep them running - they'll fail gracefully and resume when network returns
    }
    
}

// MARK: - MDNSDiscoveryProviderDelegate

extension ConnectionProvider: MDNSDiscoveryProviderDelegate {
    
    public func mdnsProvider(_ provider: MDNSDiscoveryProvider,
                             discoveredDeviceAt address: String,
                             port: UInt16,
                             deviceId: String) {
        // Check if we need a new connection to this device
        guard let delegate = self.delegate else { return }
        guard delegate.isNewConnectionNeeded(byProvider: self, deviceId: deviceId) else {
            Logger.network.debug("mDNS: Connection to \(deviceId, privacy: .public) not needed")
            return
        }
        
        Logger.network.debug("mDNS: Triggering connection to \(deviceId, privacy: .public) at \(address, privacy: .public)")
        
        // Send UDP identity packet to trigger normal connection flow
        // This is the recommended approach per KDE Connect protocol spec
        sendDirectUdpPacket(to: address)
    }
}

// MARK: - UDP Handler

/// Channel handler for receiving UDP datagrams.
private final class UdpHandler: ChannelInboundHandler {
    typealias InboundIn = AddressedEnvelope<ByteBuffer>
    
    private weak var connectionProvider: ConnectionProvider?
    private let config: ConnectionConfiguration
    
    init(connectionProvider: ConnectionProvider, config: ConnectionConfiguration) {
        self.connectionProvider = connectionProvider
        self.config = config
    }
    
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let envelope = unwrapInboundIn(data)
        let remoteAddress = envelope.remoteAddress
        
        // Convert ByteBuffer to Data
        var buffer = envelope.data
        guard let bytes = buffer.readBytes(length: buffer.readableBytes) else { return }
        let packetData = Data(bytes)
        
        // Forward to connection provider
        connectionProvider?.handleUdpPacket(data: packetData, remoteAddress: remoteAddress)
    }
    
    func errorCaught(context: ChannelHandlerContext, error: Error) {
        Logger.network.error("UDP channel error: \(error, privacy: .public)")
    }
}

// MARK: - TCP Connection Handler

/// Channel handler for TCP connections accepted by the server.
/// This handler simply notifies ConnectionProvider and then removes itself,
/// allowing Connection to take over the channel pipeline.
private final class TcpConnectionHandler: ChannelInboundHandler, RemovableChannelHandler {
    typealias InboundIn = ByteBuffer
    
    private weak var connectionProvider: ConnectionProvider?
    private let config: ConnectionConfiguration
    
    init(connectionProvider: ConnectionProvider, config: ConnectionConfiguration) {
        self.connectionProvider = connectionProvider
        self.config = config
    }
    
    func channelActive(context: ChannelHandlerContext) {
        // Notify the connection provider of the new connection
        if let remoteAddress = context.remoteAddress {
            connectionProvider?.handleTcpConnection(channel: context.channel, remoteAddress: remoteAddress)
        }
        
        // Remove ourselves from the pipeline - Connection will add its own handlers
        context.pipeline.removeHandler(self, promise: nil)
    }
    
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        // Should not receive data - we remove ourselves immediately
        // Forward to next handler if somehow called
        context.fireChannelRead(data)
    }
    
    func errorCaught(context: ChannelHandlerContext, error: Error) {
        Logger.network.error("TCP channel error: \(error, privacy: .public)")
        context.close(promise: nil)
    }
}
