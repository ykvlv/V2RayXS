#import <SystemConfiguration/SystemConfiguration.h>
#import "tun_dns.h"

// The override, its backup and the resolvers' host routes do not survive a reboot, so a reboot clears whatever a crash leaves behind.
static NSString* const backupKey = @"State:/Network/V2RayXS/DNS";
static NSString* const splitKey = @"State:/Network/Service/V2RayXS-split/DNS";
static NSString* const overrideMark = @"V2RayXSOverride";

static dispatch_queue_t queue;
static void* queueKey = &queueKey;
static SCDynamicStoreRef store;
static SYSRouteHelper* routes;
static volatile sig_atomic_t restorePending;
static NSMutableDictionary<NSString*, NSDictionary*>* originals;
static NSMutableArray<NSDictionary*>* hostRoutes;
static NSArray<NSString*>* resolvers;
static NSArray<NSString*>* splitDomains;

static NSDictionary* copyValue(NSString* key) {
    return CFBridgingRelease(SCDynamicStoreCopyValue(store, (__bridge CFStringRef)key));
}

static void setValue(NSString* key, NSDictionary* value) {
    SCDynamicStoreSetValue(store, (__bridge CFStringRef)key, (__bridge CFDictionaryRef)value);
}

// A helper that crashed leaves this behind, and the next one undoes it.
static void saveBackup(void) {
    setValue(backupKey, @{@"dns": originals, @"hostRoutes": hostRoutes});
}

static NSArray<NSString*>* originalServers(void) {
    NSMutableOrderedSet<NSString*>* servers = [NSMutableOrderedSet orderedSet];
    for (NSDictionary* dns in originals.allValues) [servers addObjectsFromArray:dns[@"ServerAddresses"]];
    return servers.array;
}

static NSDictionary* overridden(NSDictionary* original) {
    NSMutableDictionary* dns = [original mutableCopy];
    dns[@"ServerAddresses"] = resolvers;
    dns[overrideMark] = @YES;
    return dns;
}

static BOOL isOverridden(NSDictionary* dns) {
    return [dns[overrideMark] boolValue];
}

static void publishSplit(void) {
    if (splitDomains.count > 0) setValue(splitKey, @{@"ServerAddresses": originalServers(), @"SupplementalMatchDomains": splitDomains});
}

static void restore(void) {
    SCDynamicStoreSetNotificationKeys(store, NULL, NULL);
    NSDictionary* backup = copyValue(backupKey);
    NSDictionary* dns = backup[@"dns"];
    for (NSString* key in dns) {
        // A network change may already have brought settings of its own.
        if (isOverridden(copyValue(key))) setValue(key, dns[key]);
    }
    SCDynamicStoreRemoveValue(store, (__bridge CFStringRef)splitKey);
    SCDynamicStoreRemoveValue(store, (__bridge CFStringRef)backupKey);
    for (NSDictionary* route in backup[@"hostRoutes"]) {
        [routes deleteHostRouteToDestination:route[@"destination"] gateway:route[@"gateway"] family:SYSRouteAddressFamilyIPv4];
    }
    [hostRoutes removeAllObjects];
    [originals removeAllObjects];
    splitDomains = nil;
}

// The signal handler cannot wait for a block it interrupted on the queue, so that block restores once it is done.
static void finishPendingRestore(void) {
    if (restorePending) restore();
    restorePending = 0;
}

static void storeChanged(SCDynamicStoreRef changedStore, CFArrayRef changedKeys, void* info) {
    // A DHCP renewal rewrites the service's DNS: what it brings becomes the original and gets overridden again.
    for (NSString* key in (__bridge NSArray*)changedKeys) {
        NSDictionary* dns = copyValue(key);
        if (!originals[key] || [dns[@"ServerAddresses"] count] == 0 || isOverridden(dns)) continue;
        originals[key] = dns;
        saveBackup();
        setValue(key, overridden(dns));
        publishSplit();
    }
    finishPendingRestore();
}

static void setUp(SYSRouteHelper* routeHelper) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        queue = dispatch_queue_create("v2rayxs.tun-dns", DISPATCH_QUEUE_SERIAL);
        dispatch_queue_set_specific(queue, queueKey, queueKey, NULL);
        store = SCDynamicStoreCreate(NULL, CFSTR("v2rayx_sysconf"), storeChanged, NULL);
        SCDynamicStoreSetDispatchQueue(store, queue);
        routes = routeHelper;
        originals = [NSMutableDictionary dictionary];
        hostRoutes = [NSMutableArray array];
    });
}

static void apply(NSArray<NSString*>* serverDomains) {
    restore();
    NSString* service = (copyValue(@"State:/Network/Global/IPv4") ?: copyValue(@"State:/Network/Global/IPv6"))[@"PrimaryService"];
    if (service.length == 0) return;
    // Manually set servers in Setup: take precedence over the ones DHCP puts in State:.
    for (NSString* prefix in @[@"State:", @"Setup:"]) {
        NSString* key = [NSString stringWithFormat:@"%@/Network/Service/%@/DNS", prefix, service];
        NSDictionary* dns = copyValue(key);
        if ([dns[@"ServerAddresses"] count] > 0) originals[key] = dns;
    }
    if (originals.count == 0) return;
    NSMutableArray<NSString*>* candidates = [@[@"1.1.1.1", @"8.8.8.8", @"9.9.9.9", @"208.67.222.222"] mutableCopy];
    // The network's own resolvers may get host routes around the tun.
    [candidates removeObjectsInArray:originalServers()];
    resolvers = [candidates subarrayWithRange:NSMakeRange(0, MIN(candidates.count, 2))];
    splitDomains = serverDomains;
    saveBackup();
    if (serverDomains.count > 0) {
        publishSplit();
        for (NSString* server in originalServers()) {
            SYSRouteAddressFamily family = SYSRouteAddressFamilyIPv4;
            if (![routes isValidIPAddress:server family:&family] || family != SYSRouteAddressFamilyIPv4) continue;
            // Only the IPv4 routes go through the tun, and a resolver on the local network is reached directly anyway.
            NSString* gateway = [routes getRouteGateway:server family:SYSRouteAddressFamilyIPv4];
            if (gateway.length > 0 && [routes addHostRouteToDestination:server gateway:gateway family:SYSRouteAddressFamilyIPv4]) {
                [hostRoutes addObject:@{@"destination": server, @"gateway": gateway}];
                saveBackup();
            }
        }
    }
    for (NSString* key in originals) setValue(key, overridden(originals[key]));
    SCDynamicStoreSetNotificationKeys(store, (__bridge CFArrayRef)originals.allKeys, NULL);
}

void tunDNSApply(NSArray<NSString*>* serverDomains, SYSRouteHelper* routeHelper) {
    setUp(routeHelper);
    dispatch_sync(queue, ^{
        apply(serverDomains);
        finishPendingRestore();
    });
}

void tunDNSRestore(SYSRouteHelper* routeHelper) {
    setUp(routeHelper);
    // Called from the signal handler while this thread runs a block on the queue.
    if (dispatch_get_specific(queueKey)) {
        restorePending = 1;
        return;
    }
    dispatch_sync(queue, ^{
        restore();
        finishPendingRestore();
    });
}
