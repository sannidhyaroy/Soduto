//
//  UpdateManager.swift
//  Soduto
//
//  Created by Sannidhya Roy on 17/05/26.
//  Copyright © 2026 Soduto. All rights reserved.
//

import Foundation
import Sparkle
import UserNotifications
import os

private let sparkleUpdateNotificationID = "com.soduto.Soduto.UpdateAvailable"

final class UpdateManager: NSObject {

    private(set) lazy var updaterController: SPUStandardUpdaterController = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: self, userDriverDelegate: self)

    var automaticallyChecksForUpdates: Bool {
        get { updaterController.updater.automaticallyChecksForUpdates }
        set { updaterController.updater.automaticallyChecksForUpdates = newValue }
    }

    override init() {
        super.init()
        _ = updaterController
    }
}

// MARK: - SPUStandardUserDriverDelegate

extension UpdateManager: SPUStandardUserDriverDelegate {

    var supportsGentleScheduledUpdateReminders: Bool { true }

    func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState) {
        guard !state.userInitiated else { return }
        let content = UNMutableNotificationContent()
        content.title = NSLocalizedString("Update Available", comment: "")
        content.body = String(format: NSLocalizedString("Soduto %@ is now available.", comment: ""), update.displayVersionString)
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: sparkleUpdateNotificationID, content: content, trigger: nil)
        )
    }

    func standardUserDriverDidReceiveUserAttention(forUpdate update: SUAppcastItem) {
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [sparkleUpdateNotificationID])
    }

    func standardUserDriverWillFinishUpdateSession() {
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [sparkleUpdateNotificationID])
    }
}

// MARK: - SPUUpdaterDelegate

extension UpdateManager: SPUUpdaterDelegate {

    func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
        let nsError = error as NSError
        // Code 1001 = no update found — expected outcome when already on latest version
        if nsError.domain == "SUSparkleErrorDomain" && nsError.code == 1001 { return }
        Logger.general.error("Sparkle updater aborted: \(error, privacy: .public)")
    }
}
