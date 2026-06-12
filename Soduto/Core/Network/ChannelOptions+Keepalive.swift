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
/// - TCP_KEEPALIVE = 10 seconds (interval)
enum TCPKeepaliveConfiguration {
    
    /// The keepalive interval in seconds.
    static let keepaliveInterval: Int32 = 10
    
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
}

// MARK: - Bootstrap Extensions

extension ClientBootstrap {
    /// Configures TCP keepalive for client connections.
    ///
    /// - Returns: The bootstrap with keepalive configured.
    func withTCPKeepalive() -> ClientBootstrap {
        return self
            .channelOption(ChannelOptions.socketOption(.so_keepalive), value: 1)
            .channelOption(TCPKeepaliveConfiguration.keepaliveOption, value: SocketOptionValue(TCPKeepaliveConfiguration.keepaliveInterval))
    }
}

extension ServerBootstrap {
    /// Configures TCP keepalive on child channels for server connections.
    ///
    /// - Returns: The bootstrap with keepalive configured for child channels.
    func withChildTCPKeepalive() -> ServerBootstrap {
        return self
            .childChannelOption(ChannelOptions.socketOption(.so_keepalive), value: 1)
            .childChannelOption(TCPKeepaliveConfiguration.keepaliveOption, value: SocketOptionValue(TCPKeepaliveConfiguration.keepaliveInterval))
    }
}
