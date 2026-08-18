//
//  AltXPC.swift
//  AltXPC
//
//  Created by Riley Testut on 12/3/20.
//  Copyright © 2020 Riley Testut. All rights reserved.
//

import Foundation

@objc(AltXPC)
class AltXPC: NSObject, AltXPCProtocol
{
    func ping(_ completionHandler: @escaping () -> Void)
    {
        completionHandler()
    }
    
    func requestAnisetteData(completionHandler: @escaping (ALTAnisetteData?, Error?) -> Void)
    {
        guard let anisetteData = ALTPluginService.shared.requestAnisetteData() else {
            // Never report (nil, nil): AltServer builds a Result from this pair and traps when both are nil.
            let error = NSError(domain: "com.rileytestut.AltXPC", code: 1, userInfo: [
                NSLocalizedDescriptionKey: NSLocalizedString("AuthKit did not return valid anisette data.", comment: "")
            ])
            return completionHandler(nil, error)
        }
        
        completionHandler(anisetteData, nil)
    }
}
