#import "SubscriptionStore.h"
#import "ConfigImporter.h"
#import "MutableDeepCopying.h"
#import "NSData+AES256Encryption.h"
#import "ServerProfile.h"
#import "SubscriptionRouting.h"

static NSString* const kCacheKey = @"subscriptionCache";
static NSString* const kCacheEncryptedKey = @"subscriptionCacheEncrypted";

static BOOL same(id a, id b) {
    return a == b || [a isEqual:b];
}

@implementation SubscriptionStore

+ (NSDictionary*)loadWithKey:(NSString*)key {
    NSUserDefaults* defaults = NSUserDefaults.standardUserDefaults;
    NSData* data = [defaults dataForKey:kCacheKey];
    if ([defaults boolForKey:kCacheEncryptedKey]) data = [data decryptedDataWithKey:key];
    id records = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
    return [records isKindOfClass:NSDictionary.class] ? records : @{};
}

+ (void)save:(NSDictionary*)records key:(NSString*)key {
    NSData* data = [NSJSONSerialization dataWithJSONObject:records options:0 error:nil];
    if (key) data = [data encryptedDataWithKey:key];
    [NSUserDefaults.standardUserDefaults setObject:data forKey:kCacheKey];
    [NSUserDefaults.standardUserDefaults setBool:key != nil forKey:kCacheEncryptedKey];
}

+ (NSDictionary*)refresh:(NSDictionary*)records links:(NSArray*)links force:(BOOL)force proxyPort:(NSUInteger)proxyPort core:(NSString*)core geoRoot:(NSString*)geoRoot {
    NSMutableDictionary* refreshed = [NSMutableDictionary dictionary];
    BOOL newServers = NO;
    for (NSString* link in links) {
        if (!link.length || refreshed[link]) continue;
        NSDictionary* old = records[link] ?: @{};
        refreshed[link] = [self fetched:old link:link force:force proxyPort:proxyPort];
        newServers = newServers || (![old[@"outbounds"] count] && [refreshed[link][@"outbounds"] count]);
    }
    // New servers are shown before the slow geodata downloads, which wait for the next pass.
    if (newServers) return refreshed;
    for (NSString* link in refreshed.allKeys) {
        refreshed[link] = [self withGeoData:refreshed[link] force:force proxyPort:proxyPort core:core geoRoot:geoRoot];
    }
    return refreshed;
}

+ (NSDictionary*)fetched:(NSDictionary*)old link:(NSString*)link force:(BOOL)force proxyPort:(NSUInteger)proxyPort {
    NSTimeInterval now = NSDate.date.timeIntervalSince1970;
    if (!force && now < [old[@"nextUpdate"] doubleValue]) return old;
    NSMutableDictionary* record = [old mutableCopy];
    NSDictionary* result = [ConfigImporter importFromHTTPSubscription:link proxyPort:proxyPort];
    NSTimeInterval retry = [old[@"outbounds"] count] ? 3600 : 300;
    record[@"nextUpdate"] = @(now + (result && !result[@"profileError"] ? [result[@"interval"] doubleValue] : retry));
    record[@"error"] = result ? result[@"profileError"] : @"Subscription update failed.";
    if (!result) return record;
    NSMutableArray* outbounds = [NSMutableArray array];
    for (ServerProfile* server in [result[@"vmess"] arrayByAddingObjectsFromArray:result[@"vless"]]) [outbounds addObject:[server outboundProfile]];
    [outbounds addObjectsFromArray:result[@"other"]];
    [outbounds addObjectsFromArray:result[@"configs"]];
    record[@"outbounds"] = outbounds;
    record[@"title"] = result[@"title"] ?: old[@"title"];
    record[@"announce"] = result[@"announce"];
    if (!result[@"profileError"]) {
        NSDictionary* profile = [result[@"profile"] count] ? result[@"profile"] : nil;
        // Another profile gets its geodata on the next geodata pass.
        if (!same(profile, old[@"latestProfile"])) [record removeObjectForKey:@"nextGeoUpdate"];
        record[@"latestProfile"] = profile;
    }
    return record;
}

+ (NSDictionary*)withGeoData:(NSDictionary*)old force:(BOOL)force proxyPort:(NSUInteger)proxyPort core:(NSString*)core geoRoot:(NSString*)geoRoot {
    NSDictionary* profile = old[@"latestProfile"];
    NSMutableDictionary* record = [old mutableCopy];
    // A subscription without a routing profile uses the default geodata.
    if (!profile) {
        [record removeObjectsForKeys:@[@"profile", @"geoDirectory", @"geoError", @"nextGeoUpdate"]];
        return record;
    }
    NSTimeInterval now = NSDate.date.timeIntervalSince1970;
    if (!force && now < [old[@"nextGeoUpdate"] doubleValue]) return old;
    NSError* error;
    NSString* directory = [SubscriptionRouting downloadGeoData:profile root:geoRoot proxyPort:proxyPort error:&error];
    BOOL valid = directory && (([directory isEqual:old[@"geoDirectory"]] && same(profile, old[@"profile"])) ||
        [SubscriptionRouting validateRules:[SubscriptionRouting routingFromProfile:profile][@"rules"] dns:[SubscriptionRouting dnsFromProfile:profile] assets:directory core:core error:&error]);
    // A failed download is retried within the hour. What Xray rejects waits a day, or until the subscription serves another profile.
    record[@"nextGeoUpdate"] = @(now + (directory ? 86400 : 3600));
    record[@"geoError"] = valid ? nil : error.localizedDescription ?: @"Geodata update failed.";
    if (valid) {
        record[@"profile"] = profile;
        record[@"geoDirectory"] = directory;
    }
    return record;
}

+ (NSArray*)outbounds:(NSDictionary*)records links:(NSArray*)links takenTags:(NSSet*)taken linkByTag:(NSDictionary**)linkByTag {
    NSMutableSet* tags = [taken mutableCopy];
    NSMutableArray* outbounds = [NSMutableArray array];
    NSMutableDictionary* subscriptionByTag = [NSMutableDictionary dictionary];
    for (NSString* link in [NSOrderedSet orderedSetWithArray:links]) {
        for (NSDictionary* stored in records[link][@"outbounds"]) {
            NSMutableDictionary* outbound = [stored mutableDeepCopy];
            NSString* name = outbound[@"tag"] ?: @"server";
            NSString* tag = name;
            for (NSUInteger n = 2; [tags containsObject:tag]; n++) tag = [NSString stringWithFormat:@"%@ (%lu)", name, (unsigned long)n];
            [tags addObject:tag];
            outbound[@"tag"] = tag;
            subscriptionByTag[tag] = link;
            [outbounds addObject:outbound];
        }
    }
    *linkByTag = subscriptionByTag;
    return outbounds;
}

+ (void)removeGeoDataIn:(NSString*)geoRoot unusedBy:(NSDictionary*)records {
    NSArray* used = [records.allValues valueForKey:@"geoDirectory"];
    for (NSString* name in [NSFileManager.defaultManager contentsOfDirectoryAtPath:geoRoot error:nil]) {
        NSString* path = [geoRoot stringByAppendingPathComponent:name];
        if (![used containsObject:path]) [NSFileManager.defaultManager removeItemAtPath:path error:nil];
    }
}

@end
