//
//  ChannelOptions+Keepalive.swift
//  Soduto
//
//  Created by Sannidhya Roy on 15/02/26.
//  Copyright © 2026 Soduto. All rights reserved.
//

import Foundation
import NIOCore
import NIOPosix

/// TCP keepalive configuration for network connections.
///
/// Configures:
/// - SO_KEEPALIVE = 1 (enable keepalive)
/// - TCP_KEEPALIVE = 10 seconds (idle time before first probe)
/// - TCP_KEEPINTVL = 5 seconds (interval between unanswered probes)
/// - TCP_KEEPCNT = 3 (unanswered probes before the connection is dropped)
/// - TCP_RXT_CONNDROPTIME = 10 seconds (failed data retransmission before drop, Darwin)
///
/// Without the interval/count options the system defaults apply (75 s × 8
/// probes on macOS), so a silently dead peer took up to ~10 minutes to
/// detect. With these values an idle dead connection is detected in
/// ~10 + 3×5 = 25 seconds, and a dead connection with pending outgoing data
/// (keepalive probe, any packet) is dropped after 10 seconds of failed
/// retransmissions even when the peer never answers with an RST.
enum TCPKeepaliveConfiguration {
    
    /// Idle time in seconds before the first keepalive probe.
    static let keepaliveInterval: Int32 = 10
    
    /// Interval in seconds between unanswered keepalive probes.
    static let keepaliveProbeInterval: Int32 = 5
    
    /// Number of unanswered probes before the connection is dropped.
    static let keepaliveProbeCount: Int32 = 3
    
    /// Seconds of failed data retransmissions before the connection is dropped.
    static let retransmitDropTime: Int32 = 10
    
    /// Configures TCP keepalive on a channel.
    ///
    /// This should be called after the channel is connected.
    /// For bootstrap configuration, use `configureBootstrap(_:)` instead.
    ///
    /// - Parameter channel: The channel to configure.
    /// - Returns: A future that completes when configuration is done.
    static func configure(on channel: Channel) -> EventLoopFuture<Void> {
        // SO_KEEPALIVE is typically set via socket options
        // TCP_KEEPALIVE (macOS) or TCP_KEEPIDLE (Linux) controls the interval
        
        let enableKeepalive = channel.setOption(
            ChannelOptions.socketOption(.so_keepalive),
            value: 1
        )
        
        // TCP_KEEPALIVE is macOS-specific (Darwin)
        // On Linux, you'd use TCP_KEEPIDLE, TCP_KEEPINTVL, TCP_KEEPCNT
        #if os(macOS) || os(iOS) || os(tvOS) || os(watchOS)
            let setInterval = enableKeepalive.flatMap {
                channel.setOption(
                    ChannelOptions.Types.SocketOption(level: IPPROTO_TCP, name: TCP_KEEPALIVE),
                    value: SocketOptionValue(keepaliveInterval)
                )
            }
            return setInterval
        #else
            // On Linux, use TCP_KEEPIDLE (same purpose as TCP_KEEPALIVE on macOS)
            let setInterval = enableKeepalive.flatMap {
                channel.setOption(
                    ChannelOptions.Types.SocketOption(level: IPPROTO_TCP, name: TCP_KEEPIDLE),
                    value: SocketOptionValue(keepaliveInterval)
                )
            }
            return setInterval
        #endif
    }
    
    /// Creates channel options for TCP keepalive to be used with bootstrap.
    ///
    /// Usage:
    /// ```swift
    /// let bootstrap = ClientBootstrap(group: group)
    ///     .channelOption(ChannelOptions.socketOption(.so_keepalive), value: 1)
    ///     .channelOption(TCPKeepaliveConfiguration.keepaliveOption, value: 10)
    /// ```
    static var keepaliveOption: ChannelOptions.Types.SocketOption {
        #if os(macOS) || os(iOS) || os(tvOS) || os(watchOS)
            return ChannelOptions.Types.SocketOption(level: IPPROTO_TCP, name: TCP_KEEPALIVE)
        #else
            return ChannelOptions.Types.SocketOption(level: IPPROTO_TCP, name: TCP_KEEPIDLE)
        #endif
    }
    
    /// `TCP_KEEPINTVL`: interval between keepalive probes.
    static var probeIntervalOption: ChannelOptions.Types.SocketOption {
        return ChannelOptions.Types.SocketOption(level: IPPROTO_TCP, name: TCP_KEEPINTVL)
    }
    
    /// `TCP_KEEPCNT`: number of unanswered probes before drop.
    static var probeCountOption: ChannelOptions.Types.SocketOption {
        return ChannelOptions.Types.SocketOption(level: IPPROTO_TCP, name: TCP_KEEPCNT)
    }
    
    #if os(macOS) || os(iOS) || os(tvOS) || os(watchOS)
        /// `TCP_RXT_CONNDROPTIME` (Darwin): seconds of failed retransmissions before drop.
        static var retransmitDropOption: ChannelOptions.Types.SocketOption {
            return ChannelOptions.Types.SocketOption(level: IPPROTO_TCP, name: TCP_RXT_CONNDROPTIME)
        }
    #endif
}

// MARK: - Bootstrap Extensions

extension ClientBootstrap {
    /// Configures TCP keepalive for client connections.
    ///
    /// - Returns: The bootstrap with keepalive configured.
    func withTCPKeepalive() -> ClientBootstrap {
        var bootstrap = self
            .channelOption(ChannelOptions.socketOption(.so_keepalive), value: 1)
            .channelOption(TCPKeepaliveConfiguration.keepaliveOption, value: SocketOptionValue(TCPKeepaliveConfiguration.keepaliveInterval))
            .channelOption(TCPKeepaliveConfiguration.probeIntervalOption, value: SocketOptionValue(TCPKeepaliveConfiguration.keepaliveProbeInterval))
            .channelOption(TCPKeepaliveConfiguration.probeCountOption, value: SocketOptionValue(TCPKeepaliveConfiguration.keepaliveProbeCount))
        #if os(macOS) || os(iOS) || os(tvOS) || os(watchOS)
            bootstrap = bootstrap
                .channelOption(TCPKeepaliveConfiguration.retransmitDropOption, value: SocketOptionValue(TCPKeepaliveConfiguration.retransmitDropTime))
        #endif
        return bootstrap
    }
}

extension ServerBootstrap {
    /// Configures TCP keepalive on child channels for server connections.
    ///
    /// - Returns: The bootstrap with keepalive configured for child channels.
    func withChildTCPKeepalive() -> ServerBootstrap {
        var bootstrap = self
            .childChannelOption(ChannelOptions.socketOption(.so_keepalive), value: 1)
            .childChannelOption(TCPKeepaliveConfiguration.keepaliveOption, value: SocketOptionValue(TCPKeepaliveConfiguration.keepaliveInterval))
            .childChannelOption(TCPKeepaliveConfiguration.probeIntervalOption, value: SocketOptionValue(TCPKeepaliveConfiguration.keepaliveProbeInterval))
            .childChannelOption(TCPKeepaliveConfiguration.probeCountOption, value: SocketOptionValue(TCPKeepaliveConfiguration.keepaliveProbeCount))
        #if os(macOS) || os(iOS) || os(tvOS) || os(watchOS)
            bootstrap = bootstrap
                .childChannelOption(TCPKeepaliveConfiguration.retransmitDropOption, value: SocketOptionValue(TCPKeepaliveConfiguration.retransmitDropTime))
        #endif
        return bootstrap
    }
}
