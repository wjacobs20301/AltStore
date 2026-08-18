//
//  ALTPluginService.m
//  AltPlugin
//
//  Created by Riley Testut on 11/14/19.
//  Copyright © 2019 Riley Testut. All rights reserved.
//

#import "ALTPluginService.h"

#import <dlfcn.h>

#import "ALTAnisetteData.h"

@import AppKit;

@interface AKAppleIDSession : NSObject
- (id)appleIDHeadersForRequest:(id)arg1;
@end

@interface AKDevice
+ (AKDevice *)currentDevice;
- (NSString *)uniqueDeviceIdentifier;
- (nullable NSString *)serialNumber;
- (NSString *)serverFriendlyDescription;
@end

@interface ALTPluginService ()

@property (nonatomic, readonly) NSISO8601DateFormatter *dateFormatter;

@end

@implementation ALTPluginService

+ (instancetype)sharedService
{
    static ALTPluginService *_service = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        _service = [[self alloc] init];
    });
    
    return _service;
}

- (instancetype)init
{
    self = [super init];
    if (self)
    {
        _dateFormatter = [[NSISO8601DateFormatter alloc] init];
    }
    
    return self;
}

+ (void)initialize
{
    [[ALTPluginService sharedService] start];
}

- (void)start
{
    dlopen("/System/Library/PrivateFrameworks/AuthKit.framework/AuthKit", RTLD_NOW);
    
    [[NSDistributedNotificationCenter defaultCenter] addObserver:self selector:@selector(receiveNotification:) name:@"com.rileytestut.AltServer.FetchAnisetteData" object:nil];
}

- (nullable ALTAnisetteData *)requestAnisetteData
{
    NSMutableURLRequest* req = [[NSMutableURLRequest alloc] initWithURL:[[NSURL alloc] initWithString:@"https://developerservices2.apple.com/services/QH65B2/listTeams.action?clientId=XABBG36SBA"]];
    [req setHTTPMethod:@"POST"];

    AKAppleIDSession *session = [[NSClassFromString(@"AKAppleIDSession") alloc] initWithIdentifier:@"com.apple.gs.xcode.auth"];
    NSDictionary *headers = [session appleIDHeadersForRequest:req];

    AKDevice *device = [NSClassFromString(@"AKDevice") currentDevice];
    
    // AuthKit hands back a response without the anisette headers when it won't vend them to us,
    // which is the normal outcome unless SIP and AMFI are disabled. Report that as a failure
    // rather than returning an ALTAnisetteData whose values are all empty -- callers treat a
    // non-nil result as success, so empty values sail through to Apple and fail the handshake.
    if ([headers[@"X-Apple-I-MD-M"] length] == 0 || [headers[@"X-Apple-I-MD"] length] == 0 || device == nil)
    {
        return nil;
    }
    
    NSString *clientTime = headers[@"X-Apple-I-Client-Time"];
    NSDate *date = (clientTime != nil) ? [self.dateFormatter dateFromString:clientTime] : nil;
    if (date == nil)
    {
        date = [NSDate date];
    }
    
    ALTAnisetteData *anisetteData = [[NSClassFromString(@"ALTAnisetteData") alloc] initWithMachineID:headers[@"X-Apple-I-MD-M"]
                                                                                     oneTimePassword:headers[@"X-Apple-I-MD"]
                                                                                         localUserID:headers[@"X-Apple-I-MD-LU"] ?: @""
                                                                                         routingInfo:[headers[@"X-Apple-I-MD-RINFO"] longLongValue]
                                                                              deviceUniqueIdentifier:device.uniqueDeviceIdentifier
                                                                                  deviceSerialNumber:device.serialNumber ?: @"C02LKHBBFD57" // serialNumber can be nil, so provide valid fallback serial number.
                                                                                   deviceDescription:device.serverFriendlyDescription
                                                                                                date:date
                                                                                              locale:[NSLocale currentLocale]
                                                                                            timeZone:[NSTimeZone localTimeZone]];
    
    return anisetteData;
}

- (void)receiveNotification:(NSNotification *)notification
{
    NSString *requestUUID = notification.userInfo[@"requestUUID"];
    
    ALTAnisetteData *anisetteData = [self requestAnisetteData];
    if (anisetteData == nil)
    {
        // Don't reply at all -- AltServer's request timeout reports this as a plug-in failure.
        return;
    }
    
    NSData *data = [NSKeyedArchiver archivedDataWithRootObject:anisetteData requiringSecureCoding:YES error:nil];
    
    [[NSDistributedNotificationCenter defaultCenter] postNotificationName:@"com.rileytestut.AltServer.AnisetteDataResponse" object:nil userInfo:@{@"requestUUID": requestUUID, @"anisetteData": data} deliverImmediately:YES];
}

@end
