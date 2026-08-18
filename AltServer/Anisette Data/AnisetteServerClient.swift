//
//  AnisetteServerClient.swift
//  AltServer
//
//  Created by Riley Testut on 8/18/26.
//  Copyright © 2026 Riley Testut. All rights reserved.
//

import Foundation
import OSLog

import AltSign

/// Anisette data provider that talks to an "anisette v3" server.
///
/// As of macOS 27, `AOSUtilities.retrieveOTPHeadersForDSID:` fails with error -45070 and returns an
/// empty dictionary, so AltServer can no longer generate anisette data locally (see AnisetteDataManager).
/// AltXPC and the Mail plug-in both call into AuthKit, which requires SIP and/or AMFI to be disabled,
/// so neither of them is a viable fallback on a stock install.
///
/// An anisette server runs Apple's ADI library on our behalf: we register a randomly generated 16-byte
/// identifier with it once (relaying the provisioning handshake to Apple ourselves), receive an `adi.pb`
/// blob back, and afterwards exchange (identifier, adi.pb) for fresh one-time passwords whenever we need
/// anisette data.
///
/// Protocol reference: https://github.com/SideStore/apple-private-apis (omnisette).
final class AnisetteServerClient
{
    let serverURL: URL
    
    private let session: URLSession
    private let identityStore: AnisetteIdentityStore
    
    init(serverURL: URL, identityStore: AnisetteIdentityStore = .shared)
    {
        self.serverURL = serverURL
        self.identityStore = identityStore
        
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 60
        self.session = URLSession(configuration: configuration)
    }
    
    func requestAnisetteData(completion: @escaping (Result<ALTAnisetteData, Error>) -> Void)
    {
        Task<Void, Never> {
            do
            {
                let anisetteData = try await self.requestAnisetteData()
                completion(.success(anisetteData))
            }
            catch
            {
                completion(.failure(error))
            }
        }
    }
    
    func requestAnisetteData() async throws -> ALTAnisetteData
    {
        var identity = try self.identityStore.loadIdentity()
        
        if identity.adiPB == nil
        {
            Logger.main.notice("Provisioning new anisette identity with server \(self.serverURL.absoluteString, privacy: .public)...")
            
            try await self.provision(&identity)
            try self.identityStore.save(identity)
        }
        
        let headers: AnisetteServerHeaders
        
        do
        {
            headers = try await self.fetchHeaders(for: identity)
        }
        catch let error as AnisetteError where error.code == .invalidProvisioningData
        {
            // Our stored adi.pb is no longer accepted (expired, or the server was reset),
            // so throw it away and provision from scratch exactly once.
            Logger.main.error("Anisette server rejected stored provisioning data, re-provisioning. \(error.localizedDescription, privacy: .public)")
            
            identity.adiPB = nil
            
            try await self.provision(&identity)
            try self.identityStore.save(identity)
            
            headers = try await self.fetchHeaders(for: identity)
        }
        
        let anisetteData = ALTAnisetteData(machineID: headers.machineID,
                                           oneTimePassword: headers.oneTimePassword,
                                           localUserID: identity.localUserID,
                                           routingInfo: headers.routingInfo,
                                           deviceUniqueIdentifier: identity.deviceID,
                                           deviceSerialNumber: identity.serialNumber,
                                           deviceDescription: identity.clientInfo,
                                           date: Date(),
                                           locale: .current,
                                           timeZone: .current)
        return anisetteData
    }
}

private extension AnisetteServerClient
{
    struct AnisetteServerHeaders
    {
        var machineID: String
        var oneTimePassword: String
        var routingInfo: UInt64
    }
    
    var provisioningSessionURL: URL {
        // Anisette servers expose the provisioning handshake over a WebSocket,
        // so swap http(s) for the equivalent ws(s) scheme.
        let url = self.serverURL.appendingPathComponent("v3").appendingPathComponent("provisioning_session")
        
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
        
        switch components.scheme?.lowercased()
        {
        case "http": components.scheme = "ws"
        case "https": components.scheme = "wss"
        default: break
        }
        
        return components.url ?? url
    }
    
    /// Reported by anisette servers when they don't know the device's real routing info.
    static let defaultRoutingInfo: UInt64 = 17106176
    
    static let grandSlamURL = URL(string: "https://gsa.apple.com")!
    static let grandSlamLookupURL = URL(string: "https://gsa.apple.com/grandslam/GsService2/lookup")!
    
    var headersURL: URL {
        return self.serverURL.appendingPathComponent("v3").appendingPathComponent("get_headers")
    }
}

private extension AnisetteServerClient
{
    func fetchHeaders(for identity: AnisetteIdentity) async throws -> AnisetteServerHeaders
    {
        guard let adiPB = identity.adiPB else { throw AnisetteError.missingValue("adi.pb") }
        
        var request = URLRequest(url: self.headersURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "identifier": identity.identifierBase64,
            "adi_pb": adiPB.base64EncodedString()
        ])
        
        let (data, response) = try await self.session.data(for: request)
        
        if let response = response as? HTTPURLResponse, !(200 ..< 300).contains(response.statusCode)
        {
            throw AnisetteError.anisetteServerFailure(String(format: NSLocalizedString("(HTTP %@)", comment: ""), NSNumber(value: response.statusCode)))
        }
        
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw AnisetteError.invalidServerResponse(self.serverURL)
        }
        
        let result = json["result"] as? String
        guard result == "Headers" else {
            let message = (json["message"] as? String) ?? result
            
            // The server understood us but wouldn't accept our adi.pb, which is recoverable by re-provisioning.
            guard result != "GetHeadersError" else { throw AnisetteError.invalidProvisioningData(message) }
            
            throw AnisetteError.anisetteServerFailure(message)
        }
        
        guard let machineID = json["X-Apple-I-MD-M"] as? String else { throw AnisetteError.missingValue("machineID") }
        guard let oneTimePassword = json["X-Apple-I-MD"] as? String else { throw AnisetteError.missingValue("oneTimePassword") }
        
        // Some servers return X-Apple-I-MD-RINFO as a number, others as a string.
        let routingInfo: UInt64
        if let number = json["X-Apple-I-MD-RINFO"] as? NSNumber
        {
            routingInfo = number.uint64Value
        }
        else if let string = json["X-Apple-I-MD-RINFO"] as? String, let value = UInt64(string)
        {
            routingInfo = value
        }
        else
        {
            routingInfo = AnisetteServerClient.defaultRoutingInfo
        }
        
        return AnisetteServerHeaders(machineID: machineID, oneTimePassword: oneTimePassword, routingInfo: routingInfo)
    }
}

private extension AnisetteServerClient
{
    func provision(_ identity: inout AnisetteIdentity) async throws
    {
        let webSocketTask = self.session.webSocketTask(with: self.provisioningSessionURL)
        webSocketTask.resume()
        
        defer { webSocketTask.cancel(with: .goingAway, reason: nil) }
        
        // Provided by Apple's lookup service once we're asked to start provisioning.
        var finishProvisioningURL: URL?
        
        while true
        {
            let message = try await webSocketTask.receive()
            
            let data: Data
            switch message
            {
            case .string(let string): data = Data(string.utf8)
            case .data(let messageData): data = messageData
            @unknown default: throw AnisetteError.invalidServerResponse(self.serverURL)
            }
            
            guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let result = json["result"] as? String
            else { throw AnisetteError.invalidServerResponse(self.serverURL) }
            
            switch result
            {
            case "GiveIdentifier":
                try await webSocketTask.send(.json(["identifier": identity.identifierBase64]))
                
            case "GiveStartProvisioningData":
                let provisioningURLs = try await self.fetchProvisioningURLs(for: identity)
                finishProvisioningURL = provisioningURLs.finish
                
                let spim = try await self.startProvisioning(at: provisioningURLs.start, for: identity)
                try await webSocketTask.send(.json(["spim": spim]))
                
            case "GiveEndProvisioningData":
                guard let cpim = json["cpim"] as? String else { throw AnisetteError.invalidServerResponse(self.serverURL) }
                guard let finishProvisioningURL = finishProvisioningURL else { throw AnisetteError.invalidServerResponse(self.serverURL) }
                
                let (ptm, tk) = try await self.finishProvisioning(at: finishProvisioningURL, cpim: cpim, for: identity)
                try await webSocketTask.send(.json(["ptm": ptm, "tk": tk]))
                
            case "ProvisioningSuccess":
                guard let adiPBString = json["adi_pb"] as? String, let adiPB = Data(base64Encoded: adiPBString) else {
                    throw AnisetteError.invalidServerResponse(self.serverURL)
                }
                
                identity.adiPB = adiPB
                
                Logger.main.notice("Successfully provisioned anisette identity.")
                return
                
            default:
                let message = (json["message"] as? String) ?? result
                throw AnisetteError.anisetteServerFailure(message)
            }
        }
    }
}

private extension AnisetteServerClient
{
    /// Apple's provisioning endpoints move around, so ask GSA where they currently live.
    func fetchProvisioningURLs(for identity: AnisetteIdentity) async throws -> (start: URL, finish: URL)
    {
        var request = URLRequest(url: AnisetteServerClient.grandSlamLookupURL)
        request.httpMethod = "GET"
        
        for (key, value) in identity.grandSlamHeaders
        {
            request.setValue(value, forHTTPHeaderField: key)
        }
        
        let (data, _) = try await self.session.data(for: request)
        
        guard let plist = try self.plist(from: data),
              let urls = self.value(forKey: "urls", in: plist) as? [String: Any],
              let startURLString = urls["midStartProvisioning"] as? String, let startURL = URL(string: startURLString),
              let finishURLString = urls["midFinishProvisioning"] as? String, let finishURL = URL(string: finishURLString)
        else { throw AnisetteError.invalidServerResponse(AnisetteServerClient.grandSlamURL) }
        
        return (startURL, finishURL)
    }
    
    func startProvisioning(at url: URL, for identity: AnisetteIdentity) async throws -> String
    {
        let plist = try await self.sendGrandSlamRequest(to: url, request: [:], for: identity)
        
        guard let spim = self.value(forKey: "spim", in: plist) as? String else {
            throw AnisetteError.missingValue("spim")
        }
        
        return spim
    }
    
    func finishProvisioning(at url: URL, cpim: String, for identity: AnisetteIdentity) async throws -> (ptm: String, tk: String)
    {
        let plist = try await self.sendGrandSlamRequest(to: url, request: ["cpim": cpim], for: identity)
        
        guard let ptm = self.value(forKey: "ptm", in: plist) as? String else { throw AnisetteError.missingValue("ptm") }
        guard let tk = self.value(forKey: "tk", in: plist) as? String else { throw AnisetteError.missingValue("tk") }
        
        return (ptm, tk)
    }
    
    func sendGrandSlamRequest(to url: URL, request requestBody: [String: Any], for identity: AnisetteIdentity) async throws -> [String: Any]
    {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        
        for (key, value) in identity.grandSlamHeaders
        {
            request.setValue(value, forHTTPHeaderField: key)
        }
        
        let body: [String: Any] = ["Header": [String: Any](), "Request": requestBody]
        request.httpBody = try PropertyListSerialization.data(fromPropertyList: body, format: .xml, options: 0)
        
        let (data, _) = try await self.session.data(for: request)
        
        guard let plist = try self.plist(from: data) else { throw AnisetteError.invalidServerResponse(url) }
        return plist
    }
    
    func plist(from data: Data) throws -> [String: Any]?
    {
        let plist = try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
        return plist as? [String: Any]
    }
    
    /// GrandSlam nests its payload under a "Response" dictionary, but not consistently across endpoints,
    /// so check both the root dictionary and the nested one.
    func value(forKey key: String, in plist: [String: Any]) -> Any?
    {
        if let value = plist[key]
        {
            return value
        }
        
        if let response = plist["Response"] as? [String: Any], let value = response[key]
        {
            return value
        }
        
        return nil
    }
}

private extension URLSessionWebSocketTask.Message
{
    static func json(_ payload: [String: Any]) throws -> URLSessionWebSocketTask.Message
    {
        let data = try JSONSerialization.data(withJSONObject: payload)
        
        guard let string = String(data: data, encoding: .utf8) else { throw AnisetteError.missingValue(nil) }
        return .string(string)
    }
}
