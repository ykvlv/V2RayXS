#ifndef tun_dns_h
#define tun_dns_h

#import <Foundation/Foundation.h>
#import "route_helper.h"

// Points the system resolver at public resolvers, which the tun routes through the proxy, as a VPN's DNS settings would.
// serverDomains keep the network's resolvers, so the core can still find its servers; those resolvers then get host
// routes around the tun when they are outside the local network, so call this before the tun takes over the routes.
void tunDNSApply(NSArray<NSString*>* serverDomains, SYSRouteHelper* routeHelper);

// Also undoes the override and host routes that a crashed helper left behind.
void tunDNSRestore(SYSRouteHelper* routeHelper);

#endif /* tun_dns_h */
