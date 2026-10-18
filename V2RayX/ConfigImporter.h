//
//  ConfigImporter.h
//  V2RayX
//
//

#import <Foundation/Foundation.h>
#import "ServerProfile.h"

NS_ASSUME_NONNULL_BEGIN

@interface ConfigImporter : NSObject
+ (NSDictionary*)parseStandardSSLink:(NSString*)link;
+ (NSMutableDictionary*)ssOutboundFromSSLink:(NSString*)link;
+ (NSMutableDictionary*)ssOutboundFromSSConfig:(NSDictionary*)jsonObject;
+ (ServerProfile*)importFromXrayShareLink:(NSString*)link;
+ (ServerProfile*)importFromVmessOfV2RayN:(NSString*)vmessStr;
+ (ServerProfile*)importFromVLESSOfXray:(NSString*)vlessStr;
+ (NSMutableDictionary*)importFromHTTPSubscription:(NSString*)httpLink proxyPort:(NSUInteger)proxyPort;
// Adds what one share link describes to the vmess, vless and other arrays of result.
+ (void)importShareLink:(NSString*)link into:(NSMutableDictionary*)result;
+ (NSMutableDictionary*)importFromStandardConfigFiles:(NSArray*)files;
+ (NSMutableDictionary*)validateRuleSet:(NSMutableDictionary*)set;
+ (NSMutableDictionary* _Nonnull)importFromSubscriptionOfSSD: (NSString* _Nonnull)ssdLink;
@end

NS_ASSUME_NONNULL_END
