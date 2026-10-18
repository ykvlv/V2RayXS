// Builds Xray routing and DNS from routing profiles and lets the bundled core validate them.
// clang -fobjc-arc -fmodules -IV2RayX tests/check_routing.m V2RayX/SubscriptionRouting.m -o /tmp/check_routing && /tmp/check_routing xray-core-bin
#import "SubscriptionRouting.h"

static void require(BOOL condition, NSString* message) {
    if (condition) return;
    fprintf(stderr, "FAIL: %s\n", message.UTF8String);
    exit(1);
}

int main(int argc, const char* argv[]) {
    @autoreleasepool {
        require(argc == 2, @"usage: check_routing <directory with xray, geoip.dat and geosite.dat>");
        NSString* assets = @(argv[1]);
        NSString* core = [assets stringByAppendingPathComponent:@"xray"];
        NSError* error;

        NSDictionary* basic = @{@"Name": @"basic", @"GlobalProxy": @YES, @"DomainStrategy": @"IPIfNonMatch", @"UseChunkFiles": @"true",
                                @"BlockSites": @[@"geosite:category-ads-all"], @"DirectSites": @[@"geosite:category-ru"], @"DirectIp": @[@"geoip:private", @"203.0.113.7/32"]};
        NSData* json = [NSJSONSerialization dataWithJSONObject:basic options:0 error:nil];
        NSString* payload = [[[json base64EncodedStringWithOptions:0] stringByReplacingOccurrencesOfString:@"+" withString:@"-"] stringByReplacingOccurrencesOfString:@"=" withString:@""];
        require([[SubscriptionRouting profileFromLink:[@"happ://routing/onadd/" stringByAppendingString:payload] proxyPort:0 error:&error] isEqual:basic], @"routing link decodes to the profile");
        require([[SubscriptionRouting profileFromLink:payload proxyPort:0 error:&error] isEqual:basic], @"a bare base64 payload decodes to the profile");
        require([[SubscriptionRouting profileFromLink:@"happ://routing/off" proxyPort:0 error:nil] isEqual:@{}], @"routing/off gives an empty profile");

        NSArray* rules = [SubscriptionRouting routingFromProfile:basic][@"rules"];
        require([[rules valueForKey:@"outboundTag"] isEqual:@[@"main", @"direct", @"decline", @"direct", @"direct", @"main"]], @"DNS rules, then block, direct, proxy");
        NSDictionary* defaultDNS = [SubscriptionRouting dnsFromProfile:basic];
        require([[defaultDNS[@"servers"] valueForKey:@"address"] isEqual:@[@"8.8.8.8", @"https://cloudflare-dns.com/dns-query"]], @"missing DNS fields take the Happ/Incy defaults");
        require([SubscriptionRouting validateRules:rules dns:defaultDNS assets:assets core:core error:&error], error.localizedDescription ?: @"");

        NSDictionary* withDNS = @{@"RouteOrder": @"block-proxy-direct", @"GlobalProxy": @"true",
                                  @"RemoteDNSType": @"DoH", @"RemoteDNSDomain": @"https://dns.example.com/dns-query", @"RemoteDNSIP": @"198.51.100.1",
                                  @"DomesticDNSType": @"DoU", @"DomesticDNSIP": @"198.51.100.2",
                                  @"ProxySites": @[@"domain:example.org"], @"DirectSites": @[@"geosite:category-ru"]};
        NSDictionary* dns = [SubscriptionRouting dnsFromProfile:withDNS];
        require([[dns[@"servers"] valueForKey:@"address"] isEqual:@[@"https://dns.example.com/dns-query", @"198.51.100.2", @"https://dns.example.com/dns-query"]], @"proxy, direct and fallback resolvers");
        require([dns[@"hosts"] isEqual:@{@"dns.example.com": @"198.51.100.1"}], @"DoH host resolves through the profile IP");
        require([[SubscriptionRouting dnsFromProfile:@{@"RemoteDNSType": @"DoH", @"RemoteDNSDomain": @"https://dns.example.com/dns-query"}][@"hosts"] count] == 0, @"a DoH host without a profile IP uses the system resolver");
        require([[[SubscriptionRouting routingFromProfile:withDNS][@"rules"] valueForKey:@"outboundTag"] isEqual:@[@"main", @"direct", @"main", @"direct", @"main"]], @"DNS rules first, then RouteOrder");
        require([SubscriptionRouting validateRules:@[] dns:dns assets:assets core:core error:&error], error.localizedDescription ?: @"");

        NSMutableDictionary* fake = [withDNS mutableCopy];
        fake[@"FakeDNS"] = @"true";
        NSDictionary* fakeDNS = [SubscriptionRouting dnsFromProfile:fake];
        require([fakeDNS[@"servers"][0][@"address"] isEqual:@"fakedns"], @"FakeDNS answers first");
        require([SubscriptionRouting validateRules:@[] dns:fakeDNS assets:assets core:core error:&error], error.localizedDescription ?: @"");

        NSMutableDictionary* unknown = [withDNS mutableCopy];
        unknown[@"DirectSites"] = @[@"geosite:no-such-category"];
        require(![SubscriptionRouting validateRules:@[] dns:[SubscriptionRouting dnsFromProfile:unknown] assets:assets core:core error:nil], @"DNS domains are checked against the geodata");
        require(![SubscriptionRouting validateRules:[SubscriptionRouting routingFromProfile:unknown][@"rules"] dns:nil assets:assets core:core error:nil], @"unknown geosite category is rejected");
        NSDictionary* vless = @{@"protocol": @"vless", @"settings": @{@"vnext": @[@{@"address": @"203.0.113.1", @"port": @443, @"users": @[@{@"id": @"27848739-7e62-4138-9fd3-098a63964b6b", @"encryption": @"none"}]}]}, @"streamSettings": @{@"network": @"tcp", @"security": @"tls"}};
        NSMutableDictionary* proxy1 = [vless mutableCopy];
        proxy1[@"tag"] = @"proxy-1";
        NSMutableDictionary* proxy2 = [vless mutableCopy];
        proxy2[@"tag"] = @"proxy-2";
        NSDictionary* balanced = @{@"remarks": @"Example", @"meta": @{@"serverDescription": @"balanced"},
                                   @"inbounds": @[@{@"tag": @"socks-in", @"protocol": @"socks", @"port": @10808, @"listen": @"127.0.0.1"}],
                                   @"outbounds": @[proxy1, proxy2, @{@"tag": @"direct", @"protocol": @"freedom"}, @{@"tag": @"block", @"protocol": @"blackhole"}],
                                   @"dns": @{@"servers": @[@"1.1.1.1"]},
                                   @"routing": @{@"domainStrategy": @"IPIfNonMatch", @"balancers": @[@{@"tag": @"auto", @"selector": @[@"proxy-"], @"strategy": @{@"type": @"leastPing"}}],
                                                 @"rules": @[@{@"type": @"field", @"ip": @[@"geoip:private"], @"outboundTag": @"direct"}, @{@"type": @"field", @"inboundTag": @[@"socks-in"], @"network": @"tcp,udp", @"balancerTag": @"auto"}]},
                                   @"observatory": @{@"subjectSelector": @[@"proxy-"], @"probeURL": @"https://www.google.com/generate_204", @"probeInterval": @"1m"}};
        NSDictionary* plain = @{@"inbounds": @[], @"outbounds": @[proxy2, @{@"tag": @"block", @"protocol": @"blackhole"}]};
        NSString* body = [[NSString alloc] initWithData:[NSJSONSerialization dataWithJSONObject:@[balanced, plain, @{@"outbounds": @[]}] options:0 error:nil] encoding:NSUTF8StringEncoding];
        NSArray* servers = [SubscriptionRouting serverConfigsFromJSON:body];
        require([[servers valueForKey:@"tag"] isEqual:@[@"Example", @"proxy-2"]], @"each full config is a server named by remarks or its first proxy outbound");
        NSString* single = [[NSString alloc] initWithData:[NSJSONSerialization dataWithJSONObject:balanced options:0 error:nil] encoding:NSUTF8StringEncoding];
        require([[SubscriptionRouting serverConfigsFromJSON:single] count] == 1, @"a single config object is one server");
        require([[SubscriptionRouting serverConfigsFromJSON:@"vless://27848739-7e62-4138-9fd3-098a63964b6b@203.0.113.1:443"] count] == 0, @"share links are not full configs");

        NSMutableDictionary* runtime = [SubscriptionRouting runtimeConfigFromServerConfig:balanced];
        require(!runtime[@"inbounds"] && runtime[@"observatory"] && [runtime[@"routing"][@"balancers"] count] == 1, @"inbounds are left to the app");
        require([runtime[@"routing"][@"rules"][1][@"inboundTag"] isEqual:APP_INBOUND_TAGS], @"a rule naming a config inbound applies to all of the app's");
        NSDictionary* withAPI = @{@"inbounds": @[@{@"tag": @"api", @"protocol": @"dokodemo-door"}], @"outbounds": @[proxy2],
                                  @"routing": @{@"rules": @[@{@"type": @"field", @"inboundTag": @[@"api"], @"outboundTag": @"api"}]}};
        require([[SubscriptionRouting runtimeConfigFromServerConfig:withAPI][@"routing"][@"rules"][0][@"inboundTag"] isEqual:@[@"api"]], @"rules for other inbounds stay as they are");
        runtime[@"inbounds"] = [SubscriptionRouting inboundsWithSocksPort:1081 httpPort:8001 listen:@"127.0.0.1" udp:YES tunName:nil fakeDNS:NO];
        require([SubscriptionRouting validateConfig:runtime assets:assets core:core error:&error], error.localizedDescription ?: @"");
        runtime[@"inbounds"] = [SubscriptionRouting inboundsWithSocksPort:1081 httpPort:8001 listen:@"0.0.0.0" udp:NO tunName:nil fakeDNS:YES];
        require([SubscriptionRouting validateConfig:runtime assets:assets core:core error:&error], error.localizedDescription ?: @"");
        puts("routing checks passed");
    }
    return 0;
}
