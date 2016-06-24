//
//  SEGContext.m
//  Analytics
//
//  Created by Tony Xiao on 6/24/16.
//  Copyright © 2016 Segment. All rights reserved.
//

#import "SEGContext.h"
#import <UIKit/UIKit.h>
#import <CoreTelephony/CTCarrier.h>
#import <CoreTelephony/CTTelephonyNetworkInfo.h>
#import "SEGUtils.h"
#import "SEGAnalytics.h"
#import "SEGAnalyticsUtils.h"
#import "SEGAnalyticsRequest.h"
#import "SEGAnalyticsConfiguration.h"
#import "SEGBluetooth.h"
#import "SEGReachability.h"
#import "SEGLocation.h"

static NSString *const SEGAdvertisingClassIdentifier = @"ASIdentifierManager";
static NSString *const SEGADClientClass = @"ADClient";

@interface SEGContext ()

@property (nonatomic, strong) NSDictionary *context;
@property (nonatomic, strong) SEGBluetooth *bluetooth;
@property (nonatomic, strong) SEGReachability *reachability;
@property (nonatomic, strong) SEGLocation *location;
@property (nonatomic, strong) NSMutableDictionary *traits;

@end

@implementation SEGContext

- (instancetype)initWithConfiguration:(SEGAnalyticsConfiguration *)configuration {
    if (self = [super init]) {
        _configuration = configuration;
        _bluetooth = [[SEGBluetooth alloc] init];
        _reachability = [SEGReachability reachabilityWithHostname:@"google.com"];
        [_reachability startNotifier];
        _context = [self staticContext];
    }
    return self;
}


/*
 * There is an iOS bug that causes instances of the CTTelephonyNetworkInfo class to
 * sometimes get notifications after they have been deallocated.
 * Instead of instantiating, using, and releasing instances you * must instead retain
 * and never release them to work around the bug.
 *
 * Ref: http://stackoverflow.com/questions/14238586/coretelephony-crash
 */

static CTTelephonyNetworkInfo *_telephonyNetworkInfo;

- (NSDictionary *)staticContext {
    NSMutableDictionary *dict = [[NSMutableDictionary alloc] init];
    
    dict[@"library"] = @{
                         @"name" : @"analytics-ios",
                         @"version" : [SEGAnalytics version]
                         };
    
    NSMutableDictionary *infoDictionary = [[[NSBundle mainBundle] infoDictionary] mutableCopy];
    [infoDictionary addEntriesFromDictionary:[[NSBundle mainBundle] localizedInfoDictionary]];
    if (infoDictionary.count) {
        dict[@"app"] = @{
            @"name" : infoDictionary[@"CFBundleDisplayName"] ?: @"",
            @"version" : infoDictionary[@"CFBundleShortVersionString"] ?: @"",
            @"build" : infoDictionary[@"CFBundleVersion"] ?: @"",
            @"namespace" : [[NSBundle mainBundle] bundleIdentifier] ?: @"",
        };
    }
    
    UIDevice *device = [UIDevice currentDevice];
    
    dict[@"device"] = ({
        NSMutableDictionary *dict = [[NSMutableDictionary alloc] init];
        dict[@"manufacturer"] = @"Apple";
        dict[@"model"] = [SEGUtils getDeviceModel];
        dict[@"id"] = [[device identifierForVendor] UUIDString];
        if (NSClassFromString(SEGAdvertisingClassIdentifier)) {
            dict[@"adTrackingEnabled"] = @([SEGUtils getAdTrackingEnabled]);
        }
        if (self.configuration.enableAdvertisingTracking) {
            NSString *idfa = SEGIDFA();
            if (idfa.length) dict[@"advertisingId"] = idfa;
        }
        dict;
    });
    
    dict[@"os"] = @{
        @"name" : device.systemName,
        @"version" : device.systemVersion
    };
    
    static dispatch_once_t networkInfoOnceToken;
    dispatch_once(&networkInfoOnceToken, ^{
        _telephonyNetworkInfo = [[CTTelephonyNetworkInfo alloc] init];
    });
    
    CTCarrier *carrier = [_telephonyNetworkInfo subscriberCellularProvider];
    if (carrier.carrierName.length)
        dict[@"network"] = @{ @"carrier" : carrier.carrierName };
    
    CGSize screenSize = [UIScreen mainScreen].bounds.size;
    dict[@"screen"] = @{
        @"width" : @(screenSize.width),
        @"height" : @(screenSize.height)
    };
    
#if !(TARGET_IPHONE_SIMULATOR)
    Class adClient = NSClassFromString(SEGADClientClass);
    if (adClient) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
        id sharedClient = [adClient performSelector:NSSelectorFromString(@"sharedClient")];
#pragma clang diagnostic pop
        void (^completionHandler)(BOOL iad) = ^(BOOL iad) {
            if (iad) {
                dict[@"referrer"] = @{ @"type" : @"iad" };
            }
        };
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
        [sharedClient performSelector:NSSelectorFromString(@"determineAppInstallationAttributionWithCompletionHandler:")
                           withObject:completionHandler];
#pragma clang diagnostic pop
    }
#endif
    
    return dict;
}


- (NSDictionary *)liveContext {
    NSMutableDictionary *context = [[NSMutableDictionary alloc] init];
    
    [context addEntriesFromDictionary:self.context];
    
    context[@"locale"] = [NSString stringWithFormat:
                          @"%@-%@",
                          [NSLocale.currentLocale objectForKey:NSLocaleLanguageCode],
                          [NSLocale.currentLocale objectForKey:NSLocaleCountryCode]];
    
    context[@"timezone"] = [[NSTimeZone localTimeZone] name];
    
    context[@"network"] = ({
        NSMutableDictionary *network = [[NSMutableDictionary alloc] init];
        
        if (self.bluetooth.hasKnownState)
            network[@"bluetooth"] = @(self.bluetooth.isEnabled);
        
        if (self.reachability.isReachable) {
            network[@"wifi"] = @(self.reachability.isReachableViaWiFi);
            network[@"cellular"] = @(self.reachability.isReachableViaWWAN);
        }
        
        network;
    });
    
    self.location = !self.location ? [self.configuration shouldUseLocationServices] ? [SEGLocation new] : nil : self.location;
    [self.location startUpdatingLocation];
    if (self.location.hasKnownLocation)
        context[@"location"] = self.location.locationDictionary;
    
    context[@"traits"] = ({
        NSMutableDictionary *traits = [[NSMutableDictionary alloc] initWithDictionary:[self traits]];
        
        if (self.location.hasKnownLocation)
            traits[@"address"] = self.location.addressDictionary;
        
        traits;
    });
    
    return [context copy];
}

- (void)addTraits:(NSDictionary *)traits {
    // TODO: Do we need a serial queue here?
//    [self dispatchBackground:^{
        [self.traits addEntriesFromDictionary:traits];
        [[self.traits copy] writeToURL:self.traitsURL atomically:YES];
//    }];
}

- (void)reset {
    // TODO: Do we need a serial queue here?
    [[NSFileManager defaultManager] removeItemAtURL:self.traitsURL error:NULL];
    self.traits = [NSMutableDictionary dictionary];
}

- (NSMutableDictionary *)traits {
    if (!_traits) {
        _traits = [NSMutableDictionary dictionaryWithContentsOfURL:self.traitsURL] ?: [[NSMutableDictionary alloc] init];
    }
    return _traits;
}

- (NSURL *)traitsURL {
    return SEGAnalyticsURLForFilename(@"segmentio.traits.plist");
}


@end
