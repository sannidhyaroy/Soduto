//
//  NotificationThreadPolicy.swift
//  Soduto
//
//  Created by Sannidhya Roy on 14/06/26.
//  Copyright © 2026 Soduto. All rights reserved.
//

import Foundation

/// Decides the macOS `threadIdentifier` for a mirrored remote notification.
///
/// macOS Notification Center treats each unique `threadIdentifier` as a
/// top-level card. To balance per-app stacking against NC clutter, only
/// notifications from a curated list of Android packages get their own
/// per-app thread; everything else collapses into a single per-device
/// thread alongside other one-offs.
///
/// The decision is a pure function of `(packageId, deviceId, appName)`,
/// no state, no migration, no re-posts. The same packet always lands in
/// the same bucket on every arrival, preserving Notification Center's
/// chronological ordering.
enum NotificationThreadPolicy {
    
    /// Android package IDs that receive their own per-app thread in Notification Center. Bundle IDs are system-assigned and unforgeable, unlike the user-facing `appName`.
    static let threadedPackages: Set<String> = [
        "com.whatsapp",                       // WhatsApp Messenger
        "com.whatsapp.w4b",                   // WhatsApp Business
        "org.telegram.messenger",             // Telegram
        "org.telegram.messenger.web",         // Telegram Web/Direct
        "org.telegram.messenger.beta",        // Telegram Beta
        "org.thunderdog.challegram",          // Telegram X
        "tw.nekomimi.nekogram",               // Nekogram
        "com.cherrygram.messenger",           // Cherrygram
        "org.thoughtcrime.securesms",         // Signal
        "com.facebook.orca",                  // Messenger
        "com.discord",                        // Discord
        "com.Slack",                          // Slack
        "com.instagram.android",              // Instagram
        "com.google.android.apps.messaging",  // Google Messages
        "com.samsung.android.messaging",      // Samsung Messages
        "com.twitter.android",                // X (Twitter)
        "com.microsoft.teams",                // Microsoft Teams
        "com.google.android.gm",              // Gmail (Android)
        "net.thunderbird.android",            // Thunderbird (Android)
        "com.fsck.k9",                        // K-9 Mail
        "com.microsoft.office.outlook",       // Microsoft Outlook
        "ch.protonmail.android",              // Proton Mail (Android)
        "com.samsung.android.email.provider", // Samsung Email (Android)
        "com.pingapp.app",                    // Spike
        "com.skype.raider",                   // Skype
        "com.viber.voip",                     // Viber
        "jp.naver.line.android",              // Line
        "com.tencent.mm",                     // WeChat
    ]
    
    /// Namespace prefix shared by every thread identifier this service emits
    private static let prefix = "notifications"
    
    /// Returns the `threadIdentifier` to stamp on a notification.
    ///
    /// Only peers that surface Android-style package ids (phones and tablets) are eligible
    /// for per-app threading. Desktops, laptops, TVs, and peers of unknown type consolidate
    /// into the per-device thread regardless of which app they came from. KDE Desktop and
    /// Windows notifications, for example, don't carry package ids at all.
    ///
    /// - Returns: `"notifications.\(deviceId).\(appName)"` when the peer is a phone/tablet *and* `packageId` is in the threaded set, the app gets its own top-level NC card.
    ///   Otherwise returns `"notifications.\(deviceId)"`, collapsing the notification into the shared per-device thread.
    static func threadIdentifier(for appName: String, on deviceId: String, package packageId: String?, peer peerType: DeviceType) -> String {
        // Only android peers send Android-style package ids; desktops/laptops/TVs/unknown go straight to the device thread.
        guard peerType == .Phone || peerType == .Tablet else {
            return "\(prefix).\(deviceId)"
        }
        if let packageId, threadedPackages.contains(packageId) {
            return "\(prefix).\(deviceId).\(appName)"
        }
        return "\(prefix).\(deviceId)"
    }
}
