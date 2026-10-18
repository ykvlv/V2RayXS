// Walks subscription records through refresh passes: servers first, geodata on the next pass,
// a profile Xray rejects is kept out and not downloaded again. Geodata is served from a local
// python3 http.server, and the subscription comes from the ConfigImporter stub below.
// clang -fobjc-arc -fmodules -IV2RayX -Iv2rayx_sysconf tests/check_subscriptions.m V2RayX/SubscriptionStore.m V2RayX/SubscriptionRouting.m V2RayX/NSData+AES256Encryption.m -framework Cocoa -o /tmp/check_subscriptions && /tmp/check_subscriptions xray-core-bin
#import "ConfigImporter.h"
#import "SubscriptionStore.h"

static NSDictionary* served;

#pragma clang diagnostic ignored "-Wincomplete-implementation"
@implementation ConfigImporter
+ (NSMutableDictionary*)importFromHTTPSubscription:(NSString*)httpLink proxyPort:(NSUInteger)proxyPort {
    return [served mutableCopy];
}
@end

static void require(BOOL condition, NSString* message) {
    if (condition) return;
    fprintf(stderr, "FAIL: %s\n", message.UTF8String);
    exit(1);
}

static NSDictionary* due(NSDictionary* records, NSString* link) {
    NSMutableDictionary* copy = [records mutableCopy];
    NSMutableDictionary* record = [records[link] mutableCopy];
    record[@"nextUpdate"] = @0;
    copy[link] = record;
    return copy;
}

int main(int argc, const char* argv[]) {
    @autoreleasepool {
        require(argc == 2, @"usage: check_subscriptions <directory with xray, geoip.dat and geosite.dat>");
        NSString* assets = @(argv[1]);
        NSString* core = [assets stringByAppendingPathComponent:@"xray"];
        NSString* root = [NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];

        int port = 20000 + getpid() % 20000;
        NSTask* server = [NSTask new];
        server.executableURL = [NSURL fileURLWithPath:@"/usr/bin/python3"];
        server.arguments = @[@"-m", @"http.server", @(port).stringValue, @"--bind", @"127.0.0.1", @"--directory", assets];
        server.standardError = NSFileHandle.fileHandleWithNullDevice;
        require([server launchAndReturnError:nil], @"python3 http.server starts");
        NSString* base = [NSString stringWithFormat:@"http://127.0.0.1:%d/", port];
        for (int i = 0; i < 50 && ![NSData dataWithContentsOfURL:[NSURL URLWithString:base]]; i++) usleep(100000);

        NSString* link = @"https://subscription.example/1";
        NSArray* links = @[link];
        NSDictionary* good = @{@"Name": @"good", @"Geoipurl": [base stringByAppendingString:@"geoip.dat"], @"Geositeurl": [base stringByAppendingString:@"geosite.dat"], @"DirectSites": @[@"geosite:category-ru"]};
        NSMutableDictionary* bad = [good mutableCopy];
        bad[@"DirectSites"] = @[@"geosite:no-such-category"];
        NSArray* outbounds = @[@{@"tag": @"a", @"protocol": @"freedom"}, @{@"tag": @"a", @"protocol": @"freedom"}];
        served = @{@"vmess": @[], @"vless": @[], @"other": outbounds, @"interval": @3600, @"profile": good};
        // A saved record of a removed subscription is dropped.
        NSDictionary* records = @{@"https://subscription.example/removed": @{@"title": @"removed"}};

        NSDictionary* first = [SubscriptionStore refresh:records links:links force:NO proxyPort:0 core:core geoRoot:root];
        require([first[link][@"outbounds"] count] == 2 && [first[link][@"latestProfile"] isEqual:good], @"first pass saves servers and the served profile");
        require(!first[link][@"profile"] && !first[link][@"geoDirectory"], @"geodata waits while new servers are shown");
        require(first.count == 1, @"only listed subscriptions keep records");

        NSDictionary* second = [SubscriptionStore refresh:first links:links force:NO proxyPort:0 core:core geoRoot:root];
        require([second[link][@"profile"] isEqual:good] && !second[link][@"geoError"], second[link][@"geoError"] ?: @"second pass adopts the profile");
        require([NSFileManager.defaultManager fileExistsAtPath:[second[link][@"geoDirectory"] stringByAppendingPathComponent:@"geosite.dat"]], @"geodata is stored");
        require([[SubscriptionStore refresh:second links:links force:NO proxyPort:0 core:core geoRoot:root] isEqual:second], @"nothing is due");

        served = @{@"vmess": @[], @"vless": @[], @"other": outbounds, @"interval": @3600, @"profile": bad};
        NSDictionary* rejected = [SubscriptionStore refresh:due(second, link) links:links force:NO proxyPort:0 core:core geoRoot:root];
        require([rejected[link][@"latestProfile"] isEqual:bad] && [rejected[link][@"profile"] isEqual:good] && rejected[link][@"geoError"], @"a rejected profile leaves the working one in use");
        require([rejected[link][@"nextGeoUpdate"] doubleValue] > NSDate.date.timeIntervalSince1970 + 80000, @"a rejected profile is tried again the next day");
        require([[SubscriptionStore refresh:rejected links:links force:NO proxyPort:0 core:core geoRoot:root] isEqual:rejected], @"a rejected profile is not downloaded again");

        served = @{@"vmess": @[], @"vless": @[], @"other": outbounds, @"interval": @3600};
        NSDictionary* dropped = [SubscriptionStore refresh:due(rejected, link) links:links force:NO proxyPort:0 core:core geoRoot:root];
        require(!dropped[link][@"latestProfile"] && !dropped[link][@"profile"] && !dropped[link][@"geoDirectory"], @"a dropped profile goes out of use");

        NSDictionary* linkByTag;
        NSArray* tagged = [SubscriptionStore outbounds:dropped links:@[link, link] takenTags:[NSSet setWithObject:@"a"] linkByTag:&linkByTag];
        require([[tagged valueForKey:@"tag"] isEqual:@[@"a (2)", @"a (3)"]] && [linkByTag[@"a (3)"] isEqual:link], @"tags are unique and a repeated link counts once");

        [SubscriptionStore removeGeoDataIn:root unusedBy:dropped];
        require([[NSFileManager.defaultManager contentsOfDirectoryAtPath:root error:nil] count] == 0, @"unused geodata is removed");
        [server terminate];
        puts("subscription checks passed");
    }
    return 0;
}
