//
//  BroadcastIdentity.swift
//  Soduto
//
//  Created by Sannidhya Roy on 16/07/26.
//  Copyright © 2026 Soduto. All rights reserved.
//

import Foundation
import os

/// Policy for the identity packet sent over the legacy IPv4 subnet broadcast.
///
/// macOS refuses to fragment broadcast datagrams, so the broadcast identity must
/// fit a single MTU frame (~1472 bytes of UDP payload on a 1500 MTU network).
///
/// The only consumers of broadcast capabilities are protocol v7 peers: v8 peers
/// take the authoritative identity from the post-TLS exchange and discover us
/// primarily via mDNS. So the broadcast advertises an allowlisted subset of
/// capabilities (the features a v7 peer can actually use in a broadcast-discovered
/// session), and omits the identity extension fields, which no v7 client parses.
/// Everything else reaches peers through the directed unicast announcements,
/// the mDNS-triggered exchange, and the TCP identity packets, all of which
/// carry the full identity.
enum BroadcastIdentity {
    
    /// Maximum serialized size for the broadcast identity. Conservative against the 1472-byte UDP payload limit of a 1500 MTU frame, leaving headroom for long device names.
    static let sizeBudget = 1400
    
    /// Allowlist of capabilities eligible for the broadcast, in current capability names.
    /// This is channel policy, not a capability source: the broadcast carries the intersection of this set with the live capabilities aggregated from registered services, so an entry here without a registered service behind it advertises nothing.
    /// Chosen as the feature set that protocol v7 era clients can actually use in a broadcast-discovered session.
    ///
    /// Grow deliberately: the serialized packet must stay under `sizeBudget`.
    /// The runtime guard in `packet(...)` falls back to a capability-less form and logs an error if it doesn't.
    static let allowedCapabilities: Set<Service.Capability> = [
        "kdeconnect.battery",
        "kdeconnect.battery.request",
        "kdeconnect.clipboard",
        "kdeconnect.connectivity_report",
        "kdeconnect.connectivity_report.request",
        "kdeconnect.findmyphone.request",
        "kdeconnect.mousepad.echo",
        "kdeconnect.mousepad.request",
        "kdeconnect.mpris",
        "kdeconnect.mpris.request",
        "kdeconnect.notification",
        "kdeconnect.notification.action",
        "kdeconnect.notification.reply",
        "kdeconnect.notification.request",
        "kdeconnect.ping",
        "kdeconnect.presenter",
        "kdeconnect.runcommand",
        "kdeconnect.runcommand.request",
        "kdeconnect.sftp",
        "kdeconnect.sftp.request",
        "kdeconnect.share.request",
        "kdeconnect.sms.request",
        "kdeconnect.telephony",
        "kdeconnect.telephony.request_mute"
    ]
    
    /// Builds the identity packet for the subnet broadcast: capabilities filtered through the allowlist, extension fields omitted.
    /// Falls back to a capability-less form (with an error log) if the result would exceed the MTU budget (degradation is never silent).
    static func packet(additionalProperties: DataPacket.Body?, config: HostConfiguration) -> DataPacket {
        let packet = DataPacket.identityPacket(
            additionalProperties: additionalProperties,
            config: config,
            incomingCapabilities: Array(config.incomingCapabilities.intersection(allowedCapabilities)),
            outgoingCapabilities: Array(config.outgoingCapabilities.intersection(allowedCapabilities)),
            includeExtensionFields: false
        )
        
        guard let size = (try? packet.serialize())?.count else { return packet }
        if size <= sizeBudget {
            return packet
        }
        
        Logger.network.error("Broadcast identity is \(size, privacy: .public) bytes, over the \(sizeBudget, privacy: .public) byte budget — sending without capabilities")
        return DataPacket.identityPacket(
            additionalProperties: additionalProperties,
            config: config,
            incomingCapabilities: [],
            outgoingCapabilities: [],
            includeExtensionFields: false
        )
    }
}
