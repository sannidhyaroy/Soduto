//
//  SharedUserDefaults.swift
//  Soduto
//
//  Created by Sannidhya Roy on 04/12/22.
//  Copyright © 2022 Soduto. All rights reserved.
//

import Foundation

struct SharedUserDefaults {
    static let suiteName = (Bundle.main.object(forInfoDictionaryKey: "TeamIdentifierPrefix") as? String ?? "") + "com.soduto.Soduto"
    static let preferencesSuite = "com.soduto.Soduto.Preferences.Keys"
    
    struct Keys {
        static let devicesToShow = "com.soduto.share.devicesToShow"
        static let uploadFile = "com.soduto.share.uploadFile"
        static let fileurl = "com.soduto.share.fileurl"
        static let buttonTag = "com.soduto.share.buttonTag"
        static let kSandboxKey = "com.soduto.share.kSandboxKey"
        static let selectedDeviceId = "com.soduto.share.selectedDeviceId"
    }
    
    struct Preferences {
        static let disableSharePopUp = "com.soduto.preferences.disableSharePopUp"
        static let deviceType = "com.soduto.preferences.deviceType"
        static let hostName = "com.soduto.preferences.hostName"
    }
}
