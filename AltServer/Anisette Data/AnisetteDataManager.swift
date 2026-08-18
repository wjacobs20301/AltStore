//
//  AnisetteDataManager.swift
//  AltServer
//
//  Created by Riley Testut on 11/16/19.
//  Copyright © 2019 Riley Testut. All rights reserved.
//

import Foundation
import AppKit
import OSLog

private extension Bundle
{
    struct ID
    {
        static let mail = "com.apple.mail"
        static let altXPC = "com.rileytestut.AltXPC"
    }
}

private extension ALTAnisetteData
{
    func sanitize(byReplacingBundleID bundleID: String)
    {
        guard let range = self.deviceDescription.lowercased().range(of: "(" + bundleID.lowercased()) else { return }
        
        var adjustedDescription = self.deviceDescription[..<range.lowerBound]
        adjustedDescription += "(com.apple.dt.Xcode/3594.4.19)>"
        
        self.deviceDescription = String(adjustedDescription)
    }
}

@objc private protocol AOSUtilitiesProtocol
{
    static var machineSerialNumber: String? { get }
    static var machineUDID: String? { get }
    
    static func retrieveOTPHeadersForDSID(_ dsid: String) -> [String: Any]?
    
    // Non-static versions used for respondsToSelector:
    var machineSerialNumber: String? { get }
    var machineUDID: String? { get }
    func retrieveOTPHeadersForDSID(_ dsid: String) -> [String: Any]?
}

class AnisetteDataManager: NSObject
{
    static let shared = AnisetteDataManager()
    
    private var anisetteDataCompletionHandlers: [String: (Result<ALTAnisetteData, Error>) -> Void] = [:]
    private var anisetteDataTimers: [String: Timer] = [:]
    
    /// Set when the user declines to use an anisette server, so we only ask once per launch.
    private var didDeclineAnisetteServer = false
    
    private lazy var xpcConnection: NSXPCConnection = {
        let connection = NSXPCConnection(serviceName: Bundle.ID.altXPC)
        connection.remoteObjectInterface = NSXPCInterface(with: AltXPCProtocol.self)
        connection.resume()
        return connection
    }()
    
    private override init()
    {
        super.init()
        
        DistributedNotificationCenter.default().addObserver(self, selector: #selector(AnisetteDataManager.handleAnisetteDataResponse(_:)), name: Notification.Name("com.rileytestut.AltServer.AnisetteDataResponse"), object: nil)
    }
    
    func requestAnisetteData(_ completion: @escaping (Result<ALTAnisetteData, Error>) -> Void)
    {
        self.requestAnisetteDataFromAOSKit { (result) in
            do
            {
                let anisetteData = try result.get()
                completion(.success(anisetteData))
            }
            catch let aosKitError
            {
                Logger.main.error("Failed to fetch anisette data via AOSKit. \(aosKitError.localizedDescription, privacy: .public)")
                
                // Fall back to XPC in case SIP is disabled.
                self.requestAnisetteDataFromXPCService { (result) in
                    do
                    {
                        let anisetteData = try result.get()
                        completion(.success(anisetteData))
                    }
                    catch
                    {
                        Logger.main.error("Failed to fetch anisette data via XPC service. \(error.localizedDescription, privacy: .public)")
                        
                        // SIP and/or AMFI are not disabled, so fall back to Mail plug-in.
                        self.requestAnisetteDataFromPlugin { (result) in
                            do
                            {
                                let anisetteData = try result.get()
                                completion(.success(anisetteData))
                            }
                            catch
                            {
                                Logger.main.error("Failed to fetch anisette data via Mail plug-in. \(error.localizedDescription, privacy: .public)")
                                
                                // Every local option has failed, which is expected as of macOS 27:
                                // AOSKit's retrieveOTPHeadersForDSID: returns error -45070 and an empty
                                // dictionary, and both remaining paths require SIP and/or AMFI to be disabled.
                                // Ask an anisette server to generate anisette data for us instead.
                                self.requestAnisetteDataFromServer { (result) in
                                    switch result
                                    {
                                    case .success(let anisetteData): completion(.success(anisetteData))
                                        
                                    case .failure(let error as AnisetteError) where error.code == .cancelled:
                                        // The user declined to use an anisette server, so report why we needed one.
                                        completion(.failure(aosKitError))
                                        
                                    case .failure(let error):
                                        Logger.main.error("Failed to fetch anisette data via anisette server. \(error.localizedDescription, privacy: .public)")
                                        completion(.failure(error))
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}

private extension AnisetteDataManager
{
    func requestAnisetteDataFromAOSKit(completion: @escaping (Result<ALTAnisetteData, Error>) -> Void)
    {
        do
        {
            let aosKitURL = URL(fileURLWithPath: "/System/Library/PrivateFrameworks/AOSKit.framework")
            
            guard let aosKit = Bundle(url: aosKitURL) else { throw AnisetteError.aosKitFailure() }
            try aosKit.loadAndReturnError()
            
            guard let AOSUtilitiesClass = NSClassFromString("AOSUtilities"),
                  AOSUtilitiesClass.responds(to: #selector(AOSUtilitiesProtocol.retrieveOTPHeadersForDSID(_:))),
                  AOSUtilitiesClass.responds(to: #selector(getter: AOSUtilitiesProtocol.machineSerialNumber)),
                  AOSUtilitiesClass.responds(to: #selector(getter: AOSUtilitiesProtocol.machineUDID))
            else { throw AnisetteError.aosKitFailure() }
            
            let AOSUtilities = unsafeBitCast(AOSUtilitiesClass, to: AOSUtilitiesProtocol.Type.self)
            
            // -2 = Production environment (via https://github.com/ionescu007/Blackwood-4NT)
            guard let requestHeaders = AOSUtilities.retrieveOTPHeadersForDSID("-2") else { throw AnisetteError.missingValue("oneTimePassword") }
            
            guard let machineID = requestHeaders["X-Apple-MD-M"] as? String else { throw AnisetteError.missingValue("machineID") }
            guard let oneTimePassword = requestHeaders["X-Apple-MD"] as? String else { throw AnisetteError.missingValue("oneTimePassword") }
            
            guard let deviceID = AOSUtilities.machineUDID else { throw AnisetteError.missingValue("deviceUniqueIdentifier") }
            guard let localUserID = deviceID.data(using: .utf8)?.base64EncodedString() else { throw AnisetteError.missingValue("localUserID") }
            
            let serialNumber = AOSUtilities.machineSerialNumber ?? "C02LKHBBFD57" // serialNumber can be nil, so provide valid fallback serial number.
            let routingInfo: UInt64 = 84215040 // Other known values: 17106176, 50660608
            
            let osVersion: OperatingSystemVersion
            let buildVersion: String
            
            if let build = ProcessInfo.processInfo.operatingSystemBuildVersion
            {
                osVersion = ProcessInfo.processInfo.operatingSystemVersion
                buildVersion = build
            }
            else
            {
                // Unknown build, so fall back to known valid macOS version.
                osVersion = OperatingSystemVersion(majorVersion: 13, minorVersion: 4, patchVersion: 0)
                buildVersion = "22F66"
            }
            
            let deviceModel = ProcessInfo.processInfo.deviceModel ?? "iMac21,1"
            let osName = (osVersion.majorVersion < 11) ? "Mac OS X" : "macOS"
            
            let serverFriendlyDescription = "<\(deviceModel)> <\(osName);\(osVersion.stringValue);\(buildVersion)> <com.apple.AuthKit/1 (com.apple.dt.Xcode/3594.4.19)>"
            
            let anisetteData = ALTAnisetteData(machineID: machineID,
                                               oneTimePassword: oneTimePassword,
                                               localUserID: localUserID,
                                               routingInfo: routingInfo,
                                               deviceUniqueIdentifier: deviceID,
                                               deviceSerialNumber: serialNumber,
                                               deviceDescription: serverFriendlyDescription,
                                               date: Date(),
                                               locale: .current,
                                               timeZone: .current)
            completion(.success(anisetteData))
        }
        catch
        {
            completion(.failure(error))
        }
    }
    
    func requestAnisetteDataFromXPCService(completion: @escaping (Result<ALTAnisetteData, Error>) -> Void)
    {
        guard let proxy = self.xpcConnection.remoteObjectProxyWithErrorHandler({ (error) in
            print("Anisette XPC Error:", error)
            completion(.failure(error))
        }) as? AltXPCProtocol else { return }
        
        proxy.requestAnisetteData { (anisetteData, error) in
            anisetteData?.sanitize(byReplacingBundleID: Bundle.ID.altXPC)
            completion(Result(anisetteData, error))
        }
    }
    
    func requestAnisetteDataFromServer(completion: @escaping (Result<ALTAnisetteData, Error>) -> Void)
    {
        self.requestAnisetteServerPermission { isAllowed in
            guard isAllowed else { return completion(.failure(AnisetteError.cancelled())) }
            
            let serverURL = UserDefaults.standard.anisetteServerURL
            Logger.main.notice("Fetching anisette data from anisette server \(serverURL.absoluteString, privacy: .public)...")
            
            let client = AnisetteServerClient(serverURL: serverURL)
            client.requestAnisetteData(completion: completion)
        }
    }
    
    /// Anisette servers see a device identifier we generate for them, so don't contact one without asking first.
    func requestAnisetteServerPermission(completion: @escaping (Bool) -> Void)
    {
        if let isAllowed = UserDefaults.standard.isAnisetteServerAllowed
        {
            return completion(isAllowed)
        }
        
        if self.didDeclineAnisetteServer
        {
            return completion(false)
        }
        
        DispatchQueue.main.async {
            let serverURL = UserDefaults.standard.anisetteServerURL
            
            let alert = NSAlert()
            alert.alertStyle = .informational
            alert.messageText = NSLocalizedString("Use an Anisette Server?", comment: "")
            alert.informativeText = String(format: NSLocalizedString("""
            This version of macOS can no longer generate the anisette data AltServer needs to sign in with your Apple ID, so AltServer can ask an anisette server to generate it instead.
            
            AltServer will register a randomly generated device identifier with %@, then send that identifier to it each time you sign in or refresh apps. Your Apple ID and password are never sent to the anisette server.
            
            To use a different server, quit AltServer and run:
            defaults write com.rileytestut.AltServer AnisetteServerURL <url>
            """, comment: ""), serverURL.absoluteString)
            
            alert.addButton(withTitle: NSLocalizedString("Use Anisette Server", comment: ""))
            alert.addButton(withTitle: NSLocalizedString("Don't Use", comment: ""))
            
            NSRunningApplication.current.activate(options: .activateIgnoringOtherApps)
            
            let response = alert.runModal()
            let isAllowed = (response == .alertFirstButtonReturn)
            
            if isAllowed
            {
                // Only remember approval; declining just skips the server until AltServer is relaunched.
                UserDefaults.standard.isAnisetteServerAllowed = true
            }
            else
            {
                self.didDeclineAnisetteServer = true
            }
            
            completion(isAllowed)
        }
    }
    
    func requestAnisetteDataFromPlugin(completion: @escaping (Result<ALTAnisetteData, Error>) -> Void)
    {
        let requestUUID = UUID().uuidString
        self.anisetteDataCompletionHandlers[requestUUID] = completion
        
        let timer = Timer(timeInterval: 1.0, repeats: false) { (timer) in
            self.finishRequest(forUUID: requestUUID, result: .failure(ALTServerError(.pluginNotFound)))
        }
        self.anisetteDataTimers[requestUUID] = timer
        
        RunLoop.main.add(timer, forMode: .default)
        
        DistributedNotificationCenter.default().postNotificationName(Notification.Name("com.rileytestut.AltServer.FetchAnisetteData"), object: nil, userInfo: ["requestUUID": requestUUID], options: .deliverImmediately)
    }
    
    @objc func handleAnisetteDataResponse(_ notification: Notification)
    {
        guard let userInfo = notification.userInfo, let requestUUID = userInfo["requestUUID"] as? String else { return }
                
        if
            let archivedAnisetteData = userInfo["anisetteData"] as? Data,
            let anisetteData = try? NSKeyedUnarchiver.unarchivedObject(ofClass: ALTAnisetteData.self, from: archivedAnisetteData)
        {
            anisetteData.sanitize(byReplacingBundleID: Bundle.ID.mail)
            self.finishRequest(forUUID: requestUUID, result: .success(anisetteData))
        }
        else
        {
            self.finishRequest(forUUID: requestUUID, result: .failure(ALTServerError(.invalidAnisetteData)))
        }
    }
    
    func finishRequest(forUUID requestUUID: String, result: Result<ALTAnisetteData, Error>)
    {
        let completionHandler = self.anisetteDataCompletionHandlers[requestUUID]
        self.anisetteDataCompletionHandlers[requestUUID] = nil
        
        let timer = self.anisetteDataTimers[requestUUID]
        self.anisetteDataTimers[requestUUID] = nil
        
        timer?.invalidate()
        completionHandler?(result)
    }
}
