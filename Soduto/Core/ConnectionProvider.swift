//
//  ConnectionProvider.swift
//  Soduto
//
//  Created by Admin on 2016-08-02.
//  Copyright © 2016 Soduto. All rights reserved.
//

import Foundation
import Cocoa
import CocoaAsyncSocket
import os
import Network
import NIOCore
import NIOPosix

// MARK: - Feature Flag

/// Feature flag to enable NIO TCP server implementation.
/// Set to `true` to use SwiftNIO ServerBootstrap instead of GCDAsyncSocket for accepting connections.
/// Note: Device integration pending - NIOConnection works but can't be passed to Device yet.
private let USE_NIO_TCP_SERVER = false

enum ConnectionProviderError: Error {
    case IdentityAbsent
}

public protocol ConnectionProviderDelegate: AnyObject {
    func isNewConnectionNeeded(byProvider provider: ConnectionProvider, deviceId: String) -> Bool
    func connectionProvider(_ provider: ConnectionProvider, didCreateConnection: Connection)
}

public class ConnectionProvider: NSObject, GCDAsyncSocketDelegate, ConnectionDelegate, NIOConnectionDelegate {
    
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
    private let tcpSocket: GCDAsyncSocket = GCDAsyncSocket(delegate: nil, delegateQueue: DispatchQueue.main)
    private var pendingConnections: Set<Connection> = Set<Connection>()
    private var pendingNIOConnections: Set<NIOConnection> = Set<NIOConnection>()
    private var isStarted: Bool = false
    private var lastAnnouncementTime: TimeInterval = 0.0
    private var announcementTimer: Timer? = nil
    
    // MARK: NIO Properties
    
    /// NIO event loop group for network operations.
    private var nioEventLoopGroup: MultiThreadedEventLoopGroup?
    
    /// NIO UDP channel for receiving broadcasts.
    private var nioUdpChannel: Channel?
    
    /// NIO TCP server channel for accepting connections.
    private var nioTcpServerChannel: Channel?
    
    /// The port the NIO TCP server is listening on.
    private var nioTcpListeningPort: UInt16 = 0
    
    
    
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
        self.tcpSocket.delegate = self
        
        NotificationCenter.default.addObserver(self, selector: #selector(broadcastAnnouncement), name: ConnectionProvider.broadcastAnnouncementNotification, object: nil)
    }
    
    deinit {
        self.pathMonitor.cancel()
        NotificationCenter.default.removeObserver(self)
        
        // Shutdown NIO event loop group
        try? self.nioEventLoopGroup?.syncShutdownGracefully()
    }
    
    public func start() {
        
        // Listen for device announcement broadcasts
        startNIOUdp()
        
        // Listen for connections on TCP
        if USE_NIO_TCP_SERVER {
            startNIOTcpServer()
        } else {
            for port: UInt16 in ConnectionProvider.minTcpPort...ConnectionProvider.maxTcpPort {
                do {
                    try self.tcpSocket.accept(onPort: port)
                    Logger.network.info("Listening for TCP connections on port \(self.tcpSocket.localPort, privacy: .public)")
                }
                catch {}
            }
            if self.tcpSocket.isDisconnected {
                Logger.network.error("Failed to start listening TCP connections on ports in range \(ConnectionProvider.minTcpPort, privacy: .public)-\(ConnectionProvider.maxTcpPort, privacy: .public)")
            }
        }
        
        self.isStarted = true
        
        // Start monitoring network reachability
        self.pathMonitor.start(queue: self.pathMonitorQueue)
        broadcastAnnouncement()
        
        // Speculative broadcasts after some intervals.
        // When broadcasting imediately after internet connection becomes available, ARP table may be incomplete and not all known devices may be detected. After some time, theese undetected devices may become known and may receive the announcement
        _ = Timer.compatScheduledTimer(withTimeInterval: 40.0, repeats: false) { _ in self.broadcastAnnouncement() }
        _ = Timer.compatScheduledTimer(withTimeInterval: 80.0, repeats: false) { _ in self.broadcastAnnouncement() }
        _ = Timer.compatScheduledTimer(withTimeInterval: 120.0, repeats: false) { _ in self.broadcastAnnouncement() }
    }
    
    public func stop() {
        self.isStarted = false
        self.pathMonitor.cancel()
        stopNIOUdp()
        if USE_NIO_TCP_SERVER {
            stopNIOTcpServer()
        } else {
            self.tcpSocket.disconnect()
        }
    }
    
    public func restart() {
        guard self.isStarted else { return }
        self.stop()
        self.start()
    }
    
    
    // MARK: Announcements broadcasting
    
    @objc public dynamic func broadcastAnnouncement() {
        guard self.isStarted else { return }
        
        // Get the TCP port from the appropriate server
        let tcpPort: UInt16
        if USE_NIO_TCP_SERVER {
            guard self.nioTcpListeningPort > 0 else { return }
            tcpPort = self.nioTcpListeningPort
        } else {
            guard self.tcpSocket.localPort > 0 else { return }
            tcpPort = self.tcpSocket.localPort
        }
        
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
        guard let channel = self.nioUdpChannel else {
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
                    let deviceNIOAddress = try NIOCore.SocketAddress(ipAddress: accessibleAddress.ipAddressString, port: Int(ConnectionProvider.udpPort))
                    var deviceBuffer = channel.allocator.buffer(capacity: bytes.count)
                    deviceBuffer.writeBytes(bytes)
                    let envelope = AddressedEnvelope(remoteAddress: deviceNIOAddress, data: deviceBuffer)
                    channel.writeAndFlush(envelope, promise: nil)
                } catch {
                    Logger.network.error("Failed to send to known device: \(error, privacy: .public)")
                }
                break
            }
        }
    }
    
    // MARK: GCDAsyncSocketDelegate
    
    public func newSocketQueueForConnection(fromAddress address: Data, on sock: GCDAsyncSocket) -> DispatchQueue? {
        return DispatchQueue.main
    }
    
    public func socket(_ sock: GCDAsyncSocket, didAcceptNewSocket newSocket: GCDAsyncSocket) {
        Logger.network.debug("socket(<\(sock, privacy: .public)> didAcceptNewSocket:<\(newSocket, privacy: .public)>)")
        
        if let connection = Connection(socket: newSocket, config: self.config) {
            connection.delegate = self
            self.pendingConnections.insert(connection)
            
            // read initial identity packet
            connection.readOnePacket()
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
            }
            else {
                Logger.network.error("No connection provider delegate to take new connection - closing");
                connection.close()
            }
        default:
            assert(false, "Closed or Open connection state expected")
        }
    }
    
    public func connection(_ connection: Connection, didSendPacket packet: DataPacket, uploadedPayload: Bool) {
        Logger.network.debug("connection(<\(connection, privacy: .public)> didSendPacket:<\(packet, privacy: .public)>)")
        
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
        Logger.network.debug("connection(<\(connection, privacy: .public)> didReadPacket:<\(packet, privacy: .public)>)")
        
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
    
    
    // MARK: NIOConnectionDelegate
    
    public func nioConnection(_ connection: NIOConnection, didSwitchToState state: NIOConnection.State) {
        Logger.network.debug("nioConnection(<\(String(describing: connection), privacy: .public)> switchedToState:<\(String(describing: state), privacy: .public)>)")
        switch state {
        case .Closed:
            self.pendingNIOConnections.remove(connection)
        case .Open:
            // TODO: Integrate with delegate when Device supports NIOConnection
            // For now, NIOConnection can't be passed to the delegate since it expects Connection
            // Keep connection in pendingNIOConnections to keep it alive until Device integration
            Logger.network.info("NIOConnection is open - keeping alive for testing (Device integration pending)")
            connection.readPackets()
            // Note: NOT removing from pendingNIOConnections - this keeps the connection alive
            // Once Device supports NIOConnection, we'll remove it here and pass to delegate
        default:
            break
        }
    }
    
    public func nioConnection(_ connection: NIOConnection, didSendPacket packet: DataPacket, uploadedPayload: Bool) {
        Logger.network.debug("nioConnection(<\(connection, privacy: .public)> didSendPacket:<\(packet, privacy: .public)>)")
        
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
            Logger.network.error("Failed to initialize NIOConnection: \(error, privacy: .public)")
            connection.close()
        }
    }
    
    public func nioConnection(_ connection: NIOConnection, didReadPacket packet: DataPacket) {
        Logger.network.debug("nioConnection(<\(connection, privacy: .public)> didReadPacket:<\(packet.type, privacy: .public)>)")
        
        // Only process identity packet during initialization
        guard connection.state == .Initializing else {
            // Connection already initialized - packet would normally go to Device
            // For now, just log it since Device integration is pending
            Logger.network.debug("Received \(packet.type, privacy: .public) packet on open NIOConnection (Device integration pending)")
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
            Logger.network.error("Failed to initialize NIOConnection: \(error, privacy: .public)")
            connection.close()
        }
    }
    
    public func nioConnectionCapacityChanged(_ connection: NIOConnection) { }
    
    
    // MARK: - NIO UDP Implementation
    
    /// Starts the NIO UDP channel for receiving and sending broadcasts.
    private func startNIOUdp() {
        // Create event loop group if needed
        if self.nioEventLoopGroup == nil {
            self.nioEventLoopGroup = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        }
        
        guard let group = self.nioEventLoopGroup else {
            Logger.network.error("Failed to create NIO event loop group")
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
                let handler = NIOUdpHandler(connectionProvider: self, config: self.config)
                return channel.pipeline.addHandler(handler)
            }
        
        do {
            let channel = try bootstrap.bind(host: "0.0.0.0", port: Int(ConnectionProvider.udpPort)).wait()
            self.nioUdpChannel = channel
            Logger.network.info("Listening for UDP broadcasts on port \(ConnectionProvider.udpPort, privacy: .public)")
        } catch {
            Logger.network.error("Failed to start NIO UDP: \(error, privacy: .public)")
        }
    }
    
    /// Stops the NIO UDP channel.
    private func stopNIOUdp() {
        self.nioUdpChannel?.close(promise: nil)
        self.nioUdpChannel = nil
    }
    
    /// Handles incoming UDP packet from NIO.
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
        guard let connectionAddress = convertNIOAddressToSocketAddress(remoteAddress, port: UInt16(port)) else {
            Logger.network.error("Failed to convert NIO address to SocketAddress")
            return
        }
        
        // Dispatch to main queue for connection creation
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            if let connection = Connection(address: connectionAddress, identityPacket: packet, config: self.config) {
                connection.delegate = self
                self.pendingConnections.insert(connection)
                
                // send initial identity packet
                _ = connection.send(DataPacket.identityPacket(config: self.config))
            }
        }
    }
    
    /// Converts a NIO SocketAddress to the legacy SocketAddress type.
    private func convertNIOAddressToSocketAddress(_ nioAddress: NIOCore.SocketAddress, port: UInt16) -> SocketAddress? {
        switch nioAddress {
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
    
    // MARK: - NIO TCP Server Implementation
    
    /// Starts the NIO TCP server for accepting incoming connections.
    private func startNIOTcpServer() {
        // Create event loop group if needed (shared with UDP)
        if self.nioEventLoopGroup == nil {
            self.nioEventLoopGroup = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        }
        
        guard let group = self.nioEventLoopGroup else {
            Logger.network.error("Failed to create NIO event loop group for TCP server")
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
                // For now, just add a handler that notifies us of new connections
                // Full connection handling will be implemented with NIOConnection
                let handler = NIOTcpConnectionHandler(connectionProvider: self, config: self.config)
                return channel.pipeline.addHandler(handler)
            }
        
        // Try to bind to a port in the KDE Connect range
        for port in ConnectionProvider.minTcpPort...ConnectionProvider.maxTcpPort {
            do {
                let channel = try bootstrap.bind(host: "0.0.0.0", port: Int(port)).wait()
                self.nioTcpServerChannel = channel
                self.nioTcpListeningPort = port
                Logger.network.info("Listening for TCP connections on port \(port, privacy: .public)")
                return
            } catch {
                // Port in use, try next
                continue
            }
        }
        
        Logger.network.error("Failed to start TCP server on ports \(ConnectionProvider.minTcpPort, privacy: .public)-\(ConnectionProvider.maxTcpPort, privacy: .public)")
    }
    
    /// Stops the NIO TCP server.
    private func stopNIOTcpServer() {
        self.nioTcpServerChannel?.close(promise: nil)
        self.nioTcpServerChannel = nil
        self.nioTcpListeningPort = 0
    }
    
    /// Handles a new TCP connection accepted by the NIO server.
    fileprivate func handleTcpConnection(channel: Channel, remoteAddress: NIOCore.SocketAddress) {
        Logger.network.debug("TCP accepted connection from \(String(describing: remoteAddress), privacy: .public)")
        
        guard let group = self.nioEventLoopGroup else {
            Logger.network.error("No event loop group available for NIOConnection")
            channel.close(promise: nil)
            return
        }
        
        // Create NIOConnection from the accepted channel
        if let connection = NIOConnection(channel: channel, config: self.config, eventLoopGroup: group) {
            Logger.network.debug("Created NIOConnection, adding to pending set")
            connection.delegate = self
            self.pendingNIOConnections.insert(connection)
            Logger.network.debug("Pending NIOConnections count: \(self.pendingNIOConnections.count, privacy: .public)")
            
            // Read initial identity packet
            connection.readOnePacket()
        } else {
            Logger.network.error("Failed to create NIOConnection from channel")
            channel.close(promise: nil)
        }
    }
    
    // MARK: Private methrod
    
    private func becameReachable() {
        Logger.network.debug("Became reachable")
        NotificationCenter.default.post(name: ConnectionProvider.networkBecameReachableNotification, object: self)
        self.restart()
    }
    
    private func becameUnreachable() {
        Logger.network.debug("Became unreachable")
    }
    
}

// MARK: - NIO UDP Handler

/// Channel handler for receiving UDP datagrams via SwiftNIO.
private final class NIOUdpHandler: ChannelInboundHandler {
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

// MARK: - NIO TCP Connection Handler

/// Channel handler for TCP connections accepted by the NIO server.
/// This handler simply notifies ConnectionProvider and then removes itself,
/// allowing NIOConnection to take over the channel pipeline.
private final class NIOTcpConnectionHandler: ChannelInboundHandler, RemovableChannelHandler {
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
        
        // Remove ourselves from the pipeline - NIOConnection will add its own handlers
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
