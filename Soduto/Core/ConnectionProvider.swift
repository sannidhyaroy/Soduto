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
    static public let minAnnouncementInterval: TimeInterval = 30.0
    static public let broadcastAnnouncementNotification: Notification.Name = Notification.Name(rawValue: "com.soduto.ConnectionProvider.broadcastAnnouncement")
    static public let networkBecameReachableNotification: Notification.Name = Notification.Name(rawValue: "com.soduto.ConnectionProvider.networkBecameReachable")
    
    public weak var delegate: ConnectionProviderDelegate? = nil
    
    private let config: ConnectionConfiguration
    private let pathMonitor: NWPathMonitor = NWPathMonitor()
    private let pathMonitorQueue: DispatchQueue = DispatchQueue(label: "com.soduto.NetworkMonitor")
    private var pendingConnections: Set<Connection> = Set<Connection>()
    private var isStarted: Bool = false
    private var lastAnnouncementTime: TimeInterval = 0.0
    private var announcementTimer: Timer? = nil
    
    // MARK: Network Properties
    
    /// Event loop group for network operations.
    private var eventLoopGroup: MultiThreadedEventLoopGroup?
    
    /// UDP channel for receiving broadcasts.
    private var udpChannel: Channel?
    
    /// TCP server channel for accepting connections.
    private var tcpServerChannel: Channel?
    
    /// The port the TCP server is listening on.
    private var tcpListeningPort: UInt16 = 0
    
    
    
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
        
        // Listen for device announcement broadcasts
        startUdp()
        
        // Listen for connections on TCP
        startTcpServer()
        
        self.isStarted = true
        
        // Start monitoring network reachability
        self.pathMonitor.start(queue: self.pathMonitorQueue)
        broadcastAnnouncement()
        
        // Speculative broadcasts after some intervals.
        _ = Timer.compatScheduledTimer(withTimeInterval: 40.0, repeats: false) { _ in self.broadcastAnnouncement() }
        _ = Timer.compatScheduledTimer(withTimeInterval: 80.0, repeats: false) { _ in self.broadcastAnnouncement() }
        _ = Timer.compatScheduledTimer(withTimeInterval: 120.0, repeats: false) { _ in self.broadcastAnnouncement() }
    }
    
    public func stop() {
        self.isStarted = false
        self.pathMonitor.cancel()
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
        
        guard self.announcementTimer == nil else { return }
        
        if self.lastAnnouncementTime + ConnectionProvider.minAnnouncementInterval < CACurrentMediaTime() {
            
            Logger.network.debug("Broadcasting self-announcement")
            
            // Try to fill ARP table with all reachable addresses
            NetworkUtils.pingLocalNetwork()
            
            let properties: DataPacket.Body = [
                DataPacket.IdentityProperty.tcpPort.rawValue: Int(tcpPort) as AnyObject
            ]
            let packet = DataPacket.identityPacket(additionalProperties: properties, config: self.config)
            sendBroadcast(packet: packet)
            self.lastAnnouncementTime = CACurrentMediaTime()
        }
        else {
            self.announcementTimer = Timer.compatScheduledTimer(withTimeInterval: ConnectionProvider.minAnnouncementInterval, repeats: false) { _ in
                self.announcementTimer = nil
                self.broadcastAnnouncement()
            }
        }
    }
    
    /// Sends the identity packet as a UDP broadcast.
    private func sendBroadcast(packet: DataPacket) {
        guard let channel = self.udpChannel else {
            Logger.network.error("UDP channel not available for broadcast")
            return
        }
        guard let bytes = try? packet.serialize() else { return }
        
        // Create ByteBuffer from packet bytes
        var buffer = channel.allocator.buffer(capacity: bytes.count)
        buffer.writeBytes(bytes)
        
        // Broadcast to 255.255.255.255
        do {
            let broadcastAddress = try NIOCore.SocketAddress(ipAddress: "255.255.255.255", port: Int(ConnectionProvider.udpPort))
            let envelope = AddressedEnvelope(remoteAddress: broadcastAddress, data: buffer)
            channel.writeAndFlush(envelope, promise: nil)
            Logger.network.debug("Sent UDP broadcast")
        } catch {
            Logger.network.error("Failed to create broadcast address: \(error, privacy: .public)")
        }
        
        // Send explicit announcements to known hardware addresses
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
                    channel.writeAndFlush(envelope, promise: nil)
                } catch {
                    Logger.network.error("Failed to send to known device: \(error, privacy: .public)")
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
    
    /// Starts the UDP channel for receiving and sending broadcasts.
    private func startUdp() {
        // Create event loop group if needed
        if self.eventLoopGroup == nil {
            self.eventLoopGroup = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        }
        
        guard let group = self.eventLoopGroup else {
            Logger.network.error("Failed to create event loop group")
            return
        }
        
        let bootstrap = DatagramBootstrap(group: group)
            .channelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .channelOption(ChannelOptions.Types.SocketOption(level: SOL_SOCKET, name: SO_REUSEPORT), value: 1)
            .channelOption(ChannelOptions.socketOption(.so_broadcast), value: 1)
            .channelInitializer { [weak self] channel in
                guard let self = self else {
                    return channel.eventLoop.makeSucceededVoidFuture()
                }
                let handler = UdpHandler(connectionProvider: self, config: self.config)
                return channel.pipeline.addHandler(handler)
            }
        
        do {
            let channel = try bootstrap.bind(host: "0.0.0.0", port: Int(ConnectionProvider.udpPort)).wait()
            self.udpChannel = channel
            Logger.network.info("Listening for UDP broadcasts on port \(ConnectionProvider.udpPort, privacy: .public)")
        } catch {
            Logger.network.error("Failed to start UDP: \(error, privacy: .public)")
        }
    }
    
    /// Stops the UDP channel.
    private func stopUdp() {
        self.udpChannel?.close(promise: nil)
        self.udpChannel = nil
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
        for port in ConnectionProvider.minTcpPort...ConnectionProvider.maxTcpPort {
            do {
                let channel = try bootstrap.bind(host: "0.0.0.0", port: Int(port)).wait()
                self.tcpServerChannel = channel
                self.tcpListeningPort = port
                Logger.network.info("Listening for TCP connections on port \(port, privacy: .public)")
                return
            } catch {
                // Port in use, try next
                continue
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
        Logger.network.debug("Became reachable")
        NotificationCenter.default.post(name: ConnectionProvider.networkBecameReachableNotification, object: self)
        self.restart()
    }
    
    private func becameUnreachable() {
        Logger.network.debug("Became unreachable")
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
