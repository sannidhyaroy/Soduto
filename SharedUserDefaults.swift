//
//  SharedUserDefaults.swift
//  Soduto
//
//  Created by Sannidhya Roy on 04/12/22.
//  Copyright © 2022 Soduto. All rights reserved.
//

import Foundation

struct SharedUserDefaults {
    static let suiteName = "D492BH5DH9.com.soduto.Soduto"
    static let preferencesSuite = "com.soduto.Soduto.Preferences.Keys"
    
    struct Keys {
        static let devicesToShow = ""
        static let uploadFile = ""
        static let fileurl = ""
        static let buttonTag = ""
        static let kSandboxKey = ""
    }
    
    struct Preferences {
        static let disableSharePopUp = ""
        static let deviceType = ""
        static let hostName = ""
    }
}
