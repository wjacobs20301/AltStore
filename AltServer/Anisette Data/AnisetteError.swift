//
//  AnisetteError.swift
//  AltServer
//
//  Created by Riley Testut on 9/13/23.
//  Copyright © 2023 Riley Testut. All rights reserved.
//

import Foundation

extension AnisetteError
{
    enum Code: Int, ALTErrorCode
    {
        typealias Error = AnisetteError
        
        case aosKitFailure
        case missingValue
        case anisetteServerFailure
        case invalidProvisioningData
        case invalidServerResponse
        case cancelled
    }
    
    static func aosKitFailure(file: String = #fileID, line: UInt = #line) -> AnisetteError {
        AnisetteError(code: .aosKitFailure, sourceFile: file, sourceLine: line)
    }
    
    static func missingValue(_ value: String?, file: String = #fileID, line: UInt = #line) -> AnisetteError {
        AnisetteError(code: .missingValue, value: value, sourceFile: file, sourceLine: line)
    }
    
    static func anisetteServerFailure(_ message: String?, file: String = #fileID, line: UInt = #line) -> AnisetteError {
        AnisetteError(code: .anisetteServerFailure, value: message, sourceFile: file, sourceLine: line)
    }
    
    static func invalidProvisioningData(_ message: String?, file: String = #fileID, line: UInt = #line) -> AnisetteError {
        AnisetteError(code: .invalidProvisioningData, value: message, sourceFile: file, sourceLine: line)
    }
    
    static func invalidServerResponse(_ serverURL: URL, file: String = #fileID, line: UInt = #line) -> AnisetteError {
        AnisetteError(code: .invalidServerResponse, value: serverURL.absoluteString, sourceFile: file, sourceLine: line)
    }
    
    static func cancelled(file: String = #fileID, line: UInt = #line) -> AnisetteError {
        AnisetteError(code: .cancelled, sourceFile: file, sourceLine: line)
    }
}

struct AnisetteError: ALTLocalizedError
{
    var code: Code
    var errorTitle: String?
    var errorFailure: String?
    
    @UserInfoValue
    var value: String?
    
    var sourceFile: String?
    var sourceLine: UInt?
    
    var errorFailureReason: String {
        switch self.code
        {
        case .aosKitFailure: return NSLocalizedString("AltServer could not retrieve anisette data from AOSKit.", comment: "")
        case .missingValue:
            let valueName = self.value.map { "anisette data value “\($0)”" } ?? NSLocalizedString("anisette data values.", comment: "")
            return String(format: NSLocalizedString("AltServer could not retrieve %@.", comment: ""), valueName)
            
        case .anisetteServerFailure:
            let baseMessage = NSLocalizedString("The anisette server could not provide anisette data.", comment: "")
            guard let message = self.value else { return baseMessage }
            
            return baseMessage + " " + message
            
        case .invalidProvisioningData:
            let baseMessage = NSLocalizedString("The anisette server rejected AltServer's provisioning data.", comment: "")
            guard let message = self.value else { return baseMessage }
            
            return baseMessage + " " + message
            
        case .invalidServerResponse:
            let baseMessage = NSLocalizedString("AltServer received an invalid response while fetching anisette data.", comment: "")
            guard let serverURL = self.value else { return baseMessage }
            
            return String(format: NSLocalizedString("AltServer received an invalid response from %@ while fetching anisette data.", comment: ""), serverURL)
            
        case .cancelled: return NSLocalizedString("Fetching anisette data from an anisette server was cancelled.", comment: "")
        }
    }
}
