#import <Foundation/Foundation.h>

// Saved subscription state, keyed by subscription link. A record keeps the servers
// ("outbounds", "title", "announce", "error", "nextUpdate"; a server from a full Xray config is
// {tag, config}) and the routing: "latestProfile" is what the subscription serves,
// "profile" is the one in use, with "geoDirectory", "geoError" and "nextGeoUpdate".
@interface SubscriptionStore : NSObject
+ (NSDictionary*)loadWithKey:(NSString*)key;
// A nil key saves the records unencrypted.
+ (void)save:(NSDictionary*)records key:(NSString*)key;
// Blocks while it downloads what is due, or everything when force is set. Geodata goes into geoRoot.
+ (NSDictionary*)refresh:(NSDictionary*)records links:(NSArray*)links force:(BOOL)force proxyPort:(NSUInteger)proxyPort core:(NSString*)core geoRoot:(NSString*)geoRoot;
// Tags are made unique against taken and each other; linkByTag maps every tag to its subscription.
+ (NSArray*)outbounds:(NSDictionary*)records links:(NSArray*)links takenTags:(NSSet*)taken linkByTag:(NSDictionary**)linkByTag;
+ (void)removeGeoDataIn:(NSString*)geoRoot unusedBy:(NSDictionary*)records;
@end
