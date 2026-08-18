//
//  AnisetteIdentity.swift
//  AltServer
//
//  Created by Riley Testut on 8/18/26.
//  Copyright © 2026 Riley Testut. All rights reserved.
//

import Foundation
import CryptoKit
import Security
import OSLog

/// The pseudo-device an anisette server provisions on our behalf.
///
/// Apple ties provisioning to the values we report while registering, so every field here must stay
/// byte-for-byte stable once we've successfully provisioned — including `clientInfo`, which is
/// deliberately *not* derived from the running copy of macOS so that a system update doesn't
/// invalidate an existing provisioning.
struct AnisetteIdentity: Codable
{
    /// 16 random bytes. Doubles as the ADI identifier and as the seed for `deviceID`/`localUserID`.
    private(set) var identifier: Data
    
    private(set) var clientInfo: String
    private(set) var serialNumber: String
    
    var adiPB: Data?
    
    init()
    {
        var bytes = [UInt8](repeating: 0, count: 16)
        
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        if status != errSecSuccess
        {
            // Vanishingly unlikely, but a predictable identifier is worse than a slightly weaker one.
            bytes = (0 ..< 16).map { _ in UInt8.random(in: UInt8.min ... UInt8.max) }
        }
        
        self.identifier = Data(bytes)
        self.clientInfo = AnisetteIdentity.defaultClientInfo
        self.serialNumber = AnisetteIdentity.defaultSerialNumber
        self.adiPB = nil
    }
}

extension AnisetteIdentity
{
    /// Matches the X-Mme-Client-Info format Xcode sends. Frozen on purpose — see the type's documentation.
    static let defaultClientInfo = "<MacBookPro18,3> <macOS;13.4.0;22F66> <com.apple.AuthKit/1 (com.apple.dt.Xcode/3594.4.19)>"
    
    /// Anisette servers don't provide a serial number, and Apple accepts "0" for provisioned pseudo-devices.
    static let defaultSerialNumber = "0"
    
    var identifierBase64: String {
        return self.identifier.base64EncodedString()
    }
    
    /// X-Mme-Device-Id: the identifier's bytes formatted as an uppercase UUID.
    var deviceID: String {
        let bytes = [UInt8](self.identifier)
        guard bytes.count == 16 else { return UUID().uuidString }
        
        let uuid = UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3],
                               bytes[4], bytes[5], bytes[6], bytes[7],
                               bytes[8], bytes[9], bytes[10], bytes[11],
                               bytes[12], bytes[13], bytes[14], bytes[15]))
        return uuid.uuidString.uppercased()
    }
    
    /// X-Apple-I-MD-LU: the SHA-256 of the identifier, as an uppercase hex string.
    var localUserID: String {
        let hash = SHA256.hash(data: self.identifier)
        return hash.map { String(format: "%02X", $0) }.joined()
    }
    
    /// Headers Apple's GrandSlam endpoints expect on every provisioning request.
    var grandSlamHeaders: [String: String] {
        let dateFormatter = ISO8601DateFormatter()
        
        return [
            "Content-Type": "text/x-xml-plist",
            "Accept": "*/*",
            "User-Agent": "akd/1.0 CFNetwork/808.1.4 Darwin/16.1.0",
            "X-Mme-Client-Info": self.clientInfo,
            "X-Mme-Device-Id": self.deviceID,
            "X-Apple-I-MD-LU": self.localUserID,
            "X-Apple-I-SRL-NO": self.serialNumber,
            "X-Apple-I-Client-Time": dateFormatter.string(from: Date()),
            "X-Apple-I-TimeZone": TimeZone.current.abbreviation() ?? "UTC",
            "X-Apple-Locale": Locale.current.identifier
        ]
    }
}

/// Stores the anisette identity on disk so we only have to provision once.
final class AnisetteIdentityStore
{
    static let shared = AnisetteIdentityStore()
    
    let fileURL: URL
    
    private let queue = DispatchQueue(label: "com.rileytestut.AltServer.AnisetteIdentityStore")
    
    init(fileURL: URL = FileManager.default.altserverDirectory.appendingPathComponent("AnisetteIdentity.plist"))
    {
        self.fileURL = fileURL
    }
    
    func loadIdentity() throws -> AnisetteIdentity
    {
        return try self.queue.sync { () throws -> AnisetteIdentity in
            guard FileManager.default.fileExists(atPath: self.fileURL.path) else {
                let identity = AnisetteIdentity()
                try self._save(identity)
                return identity
            }
            
            do
            {
                let data = try Data(contentsOf: self.fileURL)
                let identity = try PropertyListDecoder().decode(AnisetteIdentity.self, from: data)
                return identity
            }
            catch
            {
                // A corrupt identity is unrecoverable, so start over rather than failing forever.
                Logger.main.error("Failed to read anisette identity, generating a new one. \(error.localizedDescription, privacy: .public)")
                
                let identity = AnisetteIdentity()
                try self._save(identity)
                return identity
            }
        }
    }
    
    func save(_ identity: AnisetteIdentity) throws
    {
        try self.queue.sync {
            try self._save(identity)
        }
    }
    
    func reset() throws
    {
        try self.queue.sync {
            guard FileManager.default.fileExists(atPath: self.fileURL.path) else { return }
            try FileManager.default.removeItem(at: self.fileURL)
        }
    }
}

private extension AnisetteIdentityStore
{
    func _save(_ identity: AnisetteIdentity) throws
    {
        let directoryURL = self.fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        
        let data = try encoder.encode(identity)
        try data.write(to: self.fileURL, options: .atomic)
        
        // The identity is as sensitive as a device's own ADI state, so keep it readable by this user only.
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: self.fileURL.path)
    }
}
