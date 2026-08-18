//
//  UserDefaults+AltServer.swift
//  AltServer
//
//  Created by Riley Testut on 7/31/19.
//  Copyright © 2019 Riley Testut. All rights reserved.
//

import Foundation

extension UserDefaults
{
    var serverID: String? {
        get {
            return self.string(forKey: "serverID")
        }
        set {
            self.set(newValue, forKey: "serverID")
        }
    }
    
    var didPresentInitialNotification: Bool {
        get {
            return self.bool(forKey: "didPresentInitialNotification")
        }
        set {
            self.set(newValue, forKey: "didPresentInitialNotification")
        }
    }
    
    func registerDefaults()
    {
        if self.serverID == nil
        {
            self.serverID = UUID().uuidString
        }
    }
}

// "Public" defaults configurable via CLI.
extension UserDefaults
{
    private static let altJITTimeoutKey = "JITTimeout"
    
    var altJITTimeout: TimeInterval? {
        let timeout = self.double(forKey: UserDefaults.altJITTimeoutKey) // Coerces strings into doubles.
        guard timeout != 0 else { return nil }
        
        return timeout
    }
}

// Anisette server, used as a fallback when macOS can't generate anisette data locally.
extension UserDefaults
{
    private static let anisetteServerURLKey = "AnisetteServerURL"
    private static let isAnisetteServerAllowedKey = "IsAnisetteServerAllowed"
    
    static let defaultAnisetteServerURL = URL(string: "https://ani.sidestore.io")!
    
    var anisetteServerURL: URL {
        get {
            guard let urlString = self.string(forKey: UserDefaults.anisetteServerURLKey),
                  let url = URL(string: urlString), url.scheme != nil
            else { return UserDefaults.defaultAnisetteServerURL }
            
            return url
        }
        set {
            self.set(newValue.absoluteString, forKey: UserDefaults.anisetteServerURLKey)
        }
    }
    
    /// `nil` until the user has been asked whether AltServer may use an anisette server.
    var isAnisetteServerAllowed: Bool? {
        get {
            guard let isAllowed = self.object(forKey: UserDefaults.isAnisetteServerAllowedKey) as? Bool else { return nil }
            return isAllowed
        }
        set {
            self.set(newValue, forKey: UserDefaults.isAnisetteServerAllowedKey)
        }
    }
}
