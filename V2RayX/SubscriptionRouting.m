#import "SubscriptionRouting.h"
#import "MutableDeepCopying.h"
#import <CommonCrypto/CommonDigest.h>
#import <arpa/inet.h>
#import <fcntl.h>

static NSError* makeError(NSString* message) {
    return [NSError errorWithDomain:@"V2RayXS.Subscription" code:1 userInfo:@{NSLocalizedDescriptionKey: message}];
}

static id fail(NSError** error, NSString* message) {
    if (error) *error = makeError(message);
    return nil;
}

int ipAddressBits(NSString* address) {
    unsigned char buffer[16];
    if (![address isKindOfClass:NSString.class]) return 0;
    return inet_pton(AF_INET, address.UTF8String, buffer) == 1 ? 32 : inet_pton(AF_INET6, address.UTF8String, buffer) == 1 ? 128 : 0;
}

static NSString* text(NSDictionary* profile, NSString* key) {
    id value = profile[key];
    return [value isKindOfClass:NSString.class] && [value length] ? value : nil;
}

// Profiles write booleans both as JSON booleans and as "true"/"false" strings.
static BOOL flag(NSDictionary* profile, NSString* key, BOOL fallback) {
    id value = profile[key];
    if ([value isEqual:@"true"] || [value isEqual:@"false"]) return [value isEqual:@"true"];
    return [value isKindOfClass:NSNumber.class] ? [value boolValue] : fallback;
}

static NSArray* list(NSDictionary* profile, NSString* key) {
    id value = profile[key];
    if (![value isKindOfClass:NSArray.class]) return @[];
    return [value filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(id item, NSDictionary* bindings) {
        return [item isKindOfClass:NSString.class] && [item length];
    }]];
}

static NSArray* routeOrder(NSDictionary* profile) {
    NSArray* defaultOrder = @[@"block", @"direct", @"proxy"];
    NSArray* order = [text(profile, @"RouteOrder") componentsSeparatedByString:@"-"];
    return order.count == 3 && [[NSSet setWithArray:order] isEqual:[NSSet setWithArray:defaultOrder]] ? order : defaultOrder;
}

static NSString* after(NSString* link, NSArray* markers) {
    for (NSString* marker in markers) {
        NSRange range = [link rangeOfString:marker];
        if (range.location != NSNotFound) return [link substringFromIndex:NSMaxRange(range)];
    }
    return nil;
}

static NSString* sha256(NSData* data) {
    unsigned char digest[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(data.bytes, (CC_LONG)data.length, digest);
    NSMutableString* result = [NSMutableString string];
    for (NSUInteger i = 0; i < sizeof(digest); i++) [result appendFormat:@"%02x", digest[i]];
    return result;
}

@implementation SubscriptionRouting

+ (NSData*)download:(NSString*)urlString headers:(NSDictionary*)headers proxyPort:(NSUInteger)proxyPort response:(NSHTTPURLResponse**)response error:(NSError**)error {
    NSURL* url = [NSURL URLWithString:urlString];
    if (!url.host.length || ![@[@"http", @"https"] containsObject:url.scheme.lowercaseString]) return fail(error, [@"Invalid download URL: " stringByAppendingString:urlString ?: @""]);
    NSMutableURLRequest* request = [NSMutableURLRequest requestWithURL:url cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:30];
    request.allHTTPHeaderFields = headers;
    __block NSData* body;
    __block NSHTTPURLResponse* http;
    __block NSError* failure;
    for (NSNumber* port in proxyPort ? @[@(proxyPort), @0] : @[@0]) {
        NSURLSessionConfiguration* configuration = NSURLSessionConfiguration.ephemeralSessionConfiguration;
        configuration.timeoutIntervalForResource = 300;
        // An empty dictionary bypasses the system proxy, which may point at this app.
        configuration.connectionProxyDictionary = port.intValue ? @{@"HTTPEnable": @YES, @"HTTPProxy": @"127.0.0.1", @"HTTPPort": port, @"HTTPSEnable": @YES, @"HTTPSProxy": @"127.0.0.1", @"HTTPSPort": port} : @{};
        NSURLSession* session = [NSURLSession sessionWithConfiguration:configuration];
        dispatch_semaphore_t done = dispatch_semaphore_create(0);
        [[session dataTaskWithRequest:request completionHandler:^(NSData* data, NSURLResponse* reply, NSError* problem) {
            http = [reply isKindOfClass:NSHTTPURLResponse.class] ? (NSHTTPURLResponse*)reply : nil;
            body = http.statusCode == 200 ? data : nil;
            failure = problem ?: (body ? nil : makeError([NSString stringWithFormat:@"%@ returned HTTP %ld.", url.host, (long)http.statusCode]));
            dispatch_semaphore_signal(done);
        }] resume];
        dispatch_semaphore_wait(done, DISPATCH_TIME_FOREVER);
        [session finishTasksAndInvalidate];
        // Only a connection failure is worth retrying without the proxy.
        if (http) break;
    }
    if (response) *response = http;
    if (error) *error = body ? nil : failure;
    return body;
}

+ (BOOL)isRoutingLink:(NSString*)link {
    return [link containsString:@"://routing/"] || [link containsString:@"://autorouting/"];
}

+ (NSDictionary*)profileFromLink:(NSString*)link proxyPort:(NSUInteger)proxyPort error:(NSError**)error {
    NSArray* markers = @[@"://routing/onadd/", @"://routing/add/"];
    // routing/onadd/ may also carry a URL, which is imported like an autorouting one.
    NSString* url = after(link, @[@"://autorouting/onadd/", @"://autorouting/add/"]) ?: after(link, markers);
    if ([url hasPrefix:@"http"]) {
        // The URL serves the profile as JSON, base64 JSON or a routing link.
        NSData* data = [self download:url headers:nil proxyPort:proxyPort response:nil error:error];
        if (!data) return nil;
        link = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] ?: @"";
    }
    link = [link stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if ([link hasSuffix:@"://routing/off"]) return @{};
    NSString* payload = after(link, markers) ?: link;
    id profile = [NSJSONSerialization JSONObjectWithData:[payload dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil];
    if (!profile) {
        payload = payload.stringByRemovingPercentEncoding ?: payload;
        payload = [[payload stringByReplacingOccurrencesOfString:@"-" withString:@"+"] stringByReplacingOccurrencesOfString:@"_" withString:@"/"];
        payload = [payload stringByPaddingToLength:(payload.length + 3) / 4 * 4 withString:@"=" startingAtIndex:0];
        NSData* json = [[NSData alloc] initWithBase64EncodedString:payload options:0];
        profile = json ? [NSJSONSerialization JSONObjectWithData:json options:0 error:nil] : nil;
    }
    return [profile isKindOfClass:NSDictionary.class] ? profile : fail(error, @"Invalid routing profile.");
}

+ (NSDictionary*)routingFromProfile:(NSDictionary*)profile {
    NSMutableArray* rules = [NSMutableArray arrayWithObjects:
        @{@"type": @"field", @"inboundTag": @[@"__v2rayxs_dns_remote__"], @"outboundTag": @"main"},
        @{@"type": @"field", @"inboundTag": @[@"__v2rayxs_dns_domestic__"], @"outboundTag": @"direct"}, nil];
    NSDictionary* groups = @{@"block": @[@"Block", @"decline"], @"direct": @[@"Direct", @"direct"], @"proxy": @[@"Proxy", @"main"]};
    for (NSString* group in routeOrder(profile)) {
        NSString* prefix = groups[group][0];
        NSArray* sites = list(profile, [prefix stringByAppendingString:@"Sites"]);
        NSArray* ips = list(profile, [prefix stringByAppendingString:@"Ip"]);
        if (sites.count) [rules addObject:@{@"type": @"field", @"domain": sites, @"outboundTag": groups[group][1]}];
        if (ips.count) [rules addObject:@{@"type": @"field", @"ip": ips, @"outboundTag": groups[group][1]}];
    }
    [rules addObject:@{@"type": @"field", @"port": @"0-65535", @"outboundTag": flag(profile, @"GlobalProxy", YES) ? @"main" : @"direct"}];
    return @{@"name": text(profile, @"Name") ?: @"Subscription", @"domainStrategy": text(profile, @"DomainStrategy") ?: @"AsIs", @"rules": rules};
}

+ (NSDictionary*)dnsFromProfile:(NSDictionary*)profile {
    if (!profile.count) return nil;
    NSMutableDictionary* hosts = [NSMutableDictionary dictionary];
    NSDictionary* dnsHosts = [profile[@"DnsHosts"] isKindOfClass:NSDictionary.class] ? profile[@"DnsHosts"] : nil;
    for (NSString* host in dnsHosts) if (ipAddressBits(dnsHosts[host])) hosts[host] = dnsHosts[host];
    NSMutableDictionary* resolvers = [NSMutableDictionary dictionary];
    for (NSString* side in @[@"Remote", @"Domestic"]) {
        BOOL remote = [side isEqual:@"Remote"];
        NSString* type = text(profile, [side stringByAppendingString:@"DNSType"]);
        NSString* domain = text(profile, [side stringByAppendingString:@"DNSDomain"]);
        NSString* profileIP = text(profile, [side stringByAppendingString:@"DNSIP"]) ?: text(profile, [side stringByAppendingString:@"Dns"]);
        NSString* ip = profileIP ?: (remote ? @"1.1.1.1" : @"8.8.8.8");
        NSString* address = ip;
        if ([(type ?: (remote ? @"DoH" : @"DoU")) isEqual:@"DoH"] && (remote || domain)) {
            address = domain ?: @"https://cloudflare-dns.com/dns-query";
            // Resolve the DoH host through the profile's IP instead of the system resolver. The default IP belongs to the default URL only.
            NSString* host = [NSURL URLWithString:address].host;
            if (host.length && !ipAddressBits(host) && !hosts[host] && (profileIP || !domain)) hosts[host] = ip;
        }
        resolvers[remote ? @"proxy" : @"direct"] = @{@"address": address, @"tag": remote ? @"__v2rayxs_dns_remote__" : @"__v2rayxs_dns_domestic__", @"finalQuery": @YES};
    }
    NSMutableArray* servers = [NSMutableArray array];
    if (flag(profile, @"FakeDNS", NO)) [servers addObject:@{@"address": @"fakedns", @"domains": @[@"regexp:.*"]}];
    for (NSString* group in routeOrder(profile)) {
        NSArray* domains = [group isEqual:@"block"] ? @[] : list(profile, [group isEqual:@"direct"] ? @"DirectSites" : @"ProxySites");
        if (!domains.count) continue;
        NSMutableDictionary* server = [resolvers[group] mutableCopy];
        server[@"domains"] = domains;
        server[@"skipFallback"] = @YES;
        [servers addObject:server];
    }
    [servers addObject:resolvers[flag(profile, @"GlobalProxy", YES) ? @"proxy" : @"direct"]];
    return @{@"hosts": hosts, @"servers": servers};
}

+ (NSString*)publishedChecksum:(NSString*)url proxyPort:(NSUInteger)proxyPort {
    for (NSString* suffix in @[@".sha256sum", @".sha256"]) {
        NSURLComponents* components = [NSURLComponents componentsWithString:url];
        components.path = [components.path stringByAppendingString:suffix];
        NSData* data = [self download:components.string headers:nil proxyPort:proxyPort response:nil error:nil];
        NSString* content = data ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] : nil;
        NSString* sum = [content componentsSeparatedByCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet].firstObject.lowercaseString;
        if ([sum rangeOfString:@"^[0-9a-f]{64}$" options:NSRegularExpressionSearch].location != NSNotFound) return sum;
    }
    return nil;
}

+ (NSString*)downloadGeoData:(NSDictionary*)profile root:(NSString*)root proxyPort:(NSUInteger)proxyPort error:(NSError**)error {
    NSString* base = @"https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/";
    NSArray* names = @[@"geoip.dat", @"geosite.dat"];
    NSArray* urls = @[text(profile, @"Geoipurl") ?: [base stringByAppendingString:names[0]], text(profile, @"Geositeurl") ?: [base stringByAppendingString:names[1]]];
    NSFileManager* files = NSFileManager.defaultManager;
    NSMutableArray* sums = [NSMutableArray array];
    for (NSString* url in urls) [sums addObject:[self publishedChecksum:url proxyPort:proxyPort] ?: @""];
    NSString* published = [root stringByAppendingPathComponent:sha256([[sums componentsJoinedByString:@"\n"] dataUsingEncoding:NSUTF8StringEncoding])];
    if ([sums[0] length] && [sums[1] length] && [files fileExistsAtPath:published]) return published;

    NSString* staging = [root stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
    if (![files createDirectoryAtPath:staging withIntermediateDirectories:YES attributes:nil error:error]) return nil;
    NSMutableArray* hashes = [NSMutableArray array];
    for (NSUInteger i = 0; i < names.count; i++) {
        NSData* data = [self download:urls[i] headers:nil proxyPort:proxyPort response:nil error:error];
        NSString* hash = data ? sha256(data) : nil;
        if (hash && [sums[i] length] && ![hash isEqual:sums[i]]) hash = fail(error, [names[i] stringByAppendingString:@" does not match its published checksum."]);
        if (!hash || ![data writeToFile:[staging stringByAppendingPathComponent:names[i]] options:0 error:error]) {
            [files removeItemAtPath:staging error:nil];
            return nil;
        }
        [hashes addObject:hash];
    }
    NSString* directory = [root stringByAppendingPathComponent:sha256([[hashes componentsJoinedByString:@"\n"] dataUsingEncoding:NSUTF8StringEncoding])];
    if (![files moveItemAtPath:staging toPath:directory error:nil]) [files removeItemAtPath:staging error:nil];
    return [files fileExistsAtPath:directory] ? directory : fail(error, @"Failed to store geodata.");
}

+ (NSArray*)serverConfigsFromJSON:(NSString*)text {
    id json = [NSJSONSerialization JSONObjectWithData:[text dataUsingEncoding:NSUTF8StringEncoding] ?: [NSData data] options:0 error:nil];
    NSMutableArray* servers = [NSMutableArray array];
    for (NSDictionary* config in [json isKindOfClass:NSArray.class] ? json : json ? @[json] : @[]) {
        if (![config isKindOfClass:NSDictionary.class] || ![config[@"inbounds"] isKindOfClass:NSArray.class] || ![config[@"outbounds"] isKindOfClass:NSArray.class]) continue;
        NSString* name = [config[@"remarks"] isKindOfClass:NSString.class] && [config[@"remarks"] length] ? config[@"remarks"] : nil;
        for (NSDictionary* outbound in config[@"outbounds"]) {
            if (name) break;
            BOOL proxy = [outbound isKindOfClass:NSDictionary.class] && ![@[@"freedom", @"blackhole", @"dns", @"loopback"] containsObject:outbound[@"protocol"] ?: @""];
            if (proxy && [outbound[@"tag"] isKindOfClass:NSString.class]) name = outbound[@"tag"];
        }
        [servers addObject:@{@"tag": name ?: @"server", @"config": config}];
    }
    return servers;
}

+ (NSArray*)inboundsWithSocksPort:(NSInteger)socksPort httpPort:(NSInteger)httpPort listen:(NSString*)listen udp:(BOOL)udp tunName:(NSString*)tunName fakeDNS:(BOOL)fakeDNS {
    // Tun traffic arrives by IP, so domain rules need the sniffed domain; FakeDNS also needs the real destination restored.
    NSDictionary* sniffing = fakeDNS ? @{@"enabled": @YES, @"destOverride": @[@"http", @"tls", @"quic", @"fakedns"]} : @{@"enabled": @YES, @"destOverride": @[@"http", @"tls", @"quic"], @"routeOnly": @YES};
    NSMutableArray* inbounds = [NSMutableArray arrayWithObjects:
        @{@"tag": APP_INBOUND_TAGS[0], @"protocol": @"socks", @"listen": listen, @"port": @(socksPort), @"settings": @{@"auth": @"noauth", @"udp": [NSNumber numberWithBool:udp], @"ip": @"127.0.0.1"}, @"sniffing": sniffing},
        @{@"tag": APP_INBOUND_TAGS[1], @"protocol": @"http", @"listen": listen, @"port": @(httpPort), @"settings": @{@"timeout": @0}, @"sniffing": sniffing},
        nil];
    if (tunName.length) {
        [inbounds addObject:@{@"tag": APP_INBOUND_TAGS[2], @"protocol": @"tun", @"port": @0, @"settings": @{@"name": tunName, @"MTU": @1500, @"autoOutboundsInterface": @"auto"}, @"sniffing": sniffing}];
    }
    return inbounds;
}

+ (NSMutableDictionary*)runtimeConfigFromServerConfig:(NSDictionary*)config {
    NSMutableDictionary* fullConfig = [NSMutableDictionary dictionary];
    for (NSString* key in @[@"outbounds", @"routing", @"dns", @"observatory", @"burstObservatory", @"stats"]) {
        if ([config[key] respondsToSelector:@selector(mutableDeepCopy)]) fullConfig[key] = [config[key] mutableDeepCopy];
    }
    // The app's inbounds replace the config's proxy inbounds, so a rule that names one applies to all of the app's.
    // Rules for other inbounds, such as an api one, keep matching nothing.
    NSMutableSet* configInbounds = [NSMutableSet set];
    for (NSDictionary* inbound in config[@"inbounds"]) {
        BOOL replaced = [inbound isKindOfClass:NSDictionary.class] && [@[@"socks", @"mixed", @"http", @"tun"] containsObject:inbound[@"protocol"] ?: @""];
        if (replaced && inbound[@"tag"]) [configInbounds addObject:inbound[@"tag"]];
    }
    NSArray* configRules = [fullConfig[@"routing"] isKindOfClass:NSDictionary.class] ? fullConfig[@"routing"][@"rules"] : nil;
    for (NSMutableDictionary* rule in [configRules isKindOfClass:NSArray.class] ? configRules : @[]) {
        id tags = [rule isKindOfClass:NSDictionary.class] ? rule[@"inboundTag"] : nil;
        NSArray* named = [tags isKindOfClass:NSString.class] ? @[tags] : [tags isKindOfClass:NSArray.class] ? tags : @[];
        if (![configInbounds intersectsSet:[NSSet setWithArray:named]]) continue;
        NSMutableOrderedSet* mapped = [NSMutableOrderedSet orderedSet];
        for (id tag in named) {
            if ([configInbounds containsObject:tag]) [mapped addObjectsFromArray:APP_INBOUND_TAGS];
            else [mapped addObject:tag];
        }
        rule[@"inboundTag"] = mapped.array;
    }
    return fullConfig;
}

+ (BOOL)validateRules:(NSArray*)rules dns:(NSDictionary*)dns assets:(NSString*)assets core:(NSString*)core error:(NSError**)error {
    NSMutableArray* directRules = [NSMutableArray array];
    for (NSDictionary* rule in rules) {
        NSMutableDictionary* directRule = [rule mutableCopy];
        directRule[@"outboundTag"] = @"direct";
        [directRules addObject:directRule];
    }
    NSMutableDictionary* config = [@{@"outbounds": @[@{@"protocol": @"freedom", @"tag": @"direct"}], @"routing": @{@"rules": directRules}} mutableCopy];
    config[@"dns"] = dns;
    return [self validateConfig:config assets:assets core:core error:error];
}

+ (BOOL)validateConfig:(NSDictionary*)config assets:(NSString*)assets core:(NSString*)core error:(NSError**)error {
    NSData* json = [NSJSONSerialization dataWithJSONObject:config options:0 error:error];
    if (!json) return NO;
    NSTask* task = [NSTask new];
    task.executableURL = [NSURL fileURLWithPath:core];
    task.arguments = @[@"run", @"-test", @"-config", @"stdin:"];
    task.environment = assets ? @{@"XRAY_LOCATION_ASSET": assets} : @{};
    NSPipe* input = [NSPipe pipe];
    NSPipe* output = [NSPipe pipe];
    task.standardInput = input;
    task.standardOutput = output;
    task.standardError = output;
    fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1);
    if (![task launchAndReturnError:error]) return NO;
    [input.fileHandleForWriting writeData:json error:nil];
    [input.fileHandleForWriting closeAndReturnError:nil];
    NSString* log = [[NSString alloc] initWithData:[output.fileHandleForReading readDataToEndOfFile] encoding:NSUTF8StringEncoding];
    [task waitUntilExit];
    if (task.terminationStatus == 0) return YES;
    NSString* reason = [[log stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet] componentsSeparatedByString:@"\n"].lastObject;
    fail(error, [@"Xray rejected the configuration: " stringByAppendingString:reason ?: @"unknown error"]);
    return NO;
}

@end
