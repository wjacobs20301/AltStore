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
/// byte-for-byte stable once we've successfully provisioned. In particular `clientInfo` describes the
/// Mac the *server's* ADI library impersonates, not this one — anisette data generated for one machine
/// paired with a claim to be another is rejected during the authentication handshake.
struct AnisetteIdentity: Codable
{
    /// Bumped whenever a stored identity is no longer usable and must be provisioned again.
    /// Version 2 started sourcing `clientInfo` from the server instead of hard-coding it.
    static let currentVersion = 2
    
    /// Absent in identities written before versioning existed, which are all version 1.
    private(set) var version: Int?
    
    /// 16 random bytes. Doubles as the ADI identifier and as the seed for `deviceID`/`localUserID`.
    private(set) var identifier: Data
    
    /// The Mac the anisette server's ADI library impersonates, from its /v3/client_info endpoint.
    /// Apple validates anisette data against the client info it was provisioned with, so this has to
    /// be the server's value rather than one we invent, and it has to stay fixed once provisioned.
    private(set) var clientInfo: String?
    private(set) var userAgent: String?
    
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
        
        self.version = AnisetteIdentity.currentVersion
        self.identifier = Data(bytes)
        self.clientInfo = nil
        self.userAgent = nil
        self.serialNumber = AnisetteIdentity.defaultSerialNumber
        self.adiPB = nil
    }
    
    /// Records the identity the server told us to present. Clears any existing provisioning, which was
    /// bound to the previous client info and would no longer be accepted.
    mutating func setClientInfo(_ clientInfo: String, userAgent: String?)
    {
        self.clientInfo = clientInfo
        self.userAgent = userAgent
        self.adiPB = nil
    }
}

extension AnisetteIdentity
{
    /// Anisette servers don't provide a serial number, and Apple accepts "0" for provisioned pseudo-devices.
    static let defaultSerialNumber = "0"
    
    /// Used only for the client_info request itself, before the server has told us what to impersonate.
    static let defaultUserAgent = "akd/1.0 CFNetwork/808.1.4 Darwin/16.1.0"
    
    var isCurrentVersion: Bool {
        return (self.version ?? 1) == AnisetteIdentity.currentVersion
    }
    
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
    func grandSlamHeaders() throws -> [String: String]
    {
        guard let clientInfo = self.clientInfo else { throw AnisetteError.missingValue("clientInfo") }
        
        let dateFormatter = ISO8601DateFormatter()
        
        return [
            "Content-Type": "text/x-xml-plist",
            "Accept": "*/*",
            "User-Agent": self.userAgent ?? AnisetteIdentity.defaultUserAgent,
            "X-Mme-Client-Info": clientInfo,
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
                
                guard identity.isCurrentVersion else
                {
                    Logger.main.notice("Discarding anisette identity provisioned by an older version of AltServer.")
                    
                    let identity = AnisetteIdentity()
                    try self._save(identity)
                    return identity
                }
                
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
