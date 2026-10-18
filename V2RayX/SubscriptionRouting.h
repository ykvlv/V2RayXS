#import <Foundation/Foundation.h>

#define APP_INBOUND_TAGS (@[@"socksinbound", @"httpinbound", @"__v2rayxs_tun__"])

// 32 for an IPv4 address, 128 for IPv6, 0 for anything else.
int ipAddressBits(NSString* address);

// Happ/Incy routing profiles delivered with subscriptions.
@interface SubscriptionRouting : NSObject
// Goes through the local HTTP proxy when proxyPort is set, and directly if that connection fails.
+ (NSData*)download:(NSString*)url headers:(NSDictionary*)headers proxyPort:(NSUInteger)proxyPort response:(NSHTTPURLResponse**)response error:(NSError**)error;
+ (BOOL)isRoutingLink:(NSString*)link;
// An empty dictionary means the subscription turned routing off.
+ (NSDictionary*)profileFromLink:(NSString*)link proxyPort:(NSUInteger)proxyPort error:(NSError**)error;
+ (NSDictionary*)routingFromProfile:(NSDictionary*)profile;
+ (NSDictionary*)dnsFromProfile:(NSDictionary*)profile;
// Returns a directory with geoip.dat and geosite.dat named after their contents.
+ (NSString*)downloadGeoData:(NSDictionary*)profile root:(NSString*)root proxyPort:(NSUInteger)proxyPort error:(NSError**)error;
// Full Xray configs in the Incy format, one object or an array of them, as servers {tag, config}.
+ (NSArray*)serverConfigsFromJSON:(NSString*)text;
// The app's inbounds, tagged with APP_INBOUND_TAGS. A tunName adds Xray's own tun inbound.
+ (NSArray*)inboundsWithSocksPort:(NSInteger)socksPort httpPort:(NSInteger)httpPort listen:(NSString*)listen udp:(BOOL)udp tunName:(NSString*)tunName fakeDNS:(BOOL)fakeDNS;
// A full config keeps its outbounds, routing, DNS and observatory.
+ (NSMutableDictionary*)runtimeConfigFromServerConfig:(NSDictionary*)config;
// Asks Xray whether the config loads with the geodata in assets.
+ (BOOL)validateConfig:(NSDictionary*)config assets:(NSString*)assets core:(NSString*)core error:(NSError**)error;
// Asks Xray whether the rules and DNS load with the geodata in assets.
+ (BOOL)validateRules:(NSArray*)rules dns:(NSDictionary*)dns assets:(NSString*)assets core:(NSString*)core error:(NSError**)error;
@end
