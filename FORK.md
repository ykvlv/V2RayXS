# Fork differences

Compared with [tzmax/V2RayXS at 247e771](https://github.com/tzmax/V2RayXS/commit/247e7713b48d1ed3dec2646f9a6afb64e3b28dff).

## Subscriptions

- Requests send a V2RayXS User-Agent, HWID and device headers: remnawave answers an unknown User-Agent with its default link list and a request without an HWID with a 404. Every installation sends the same HWID.
- Servers are saved, encrypted when configuration encryption is on, so the app starts without network. They refresh on the provider's `profile-update-interval`.
- The server menu shows the subscription's `profile-title`, with its `announce` as a tooltip.
- Configure > Import from link or subscription URL adds an http(s) link as a subscription. It replaces the three separate link import items.
- Full Xray configs ([Incy format](https://docs.incy.cc/en/full-xray-config/)): each config is a server named by its `remarks` or its first proxy outbound. It runs with its own outbounds, routing, balancers, observatory and DNS, plus the app's inbounds.

Code: [ConfigImporter.m](V2RayX/ConfigImporter.m), [SubscriptionStore.m](V2RayX/SubscriptionStore.m), [SubscriptionRouting.m](V2RayX/SubscriptionRouting.m)

## Routing

- A Happ/Incy routing profile in the subscription becomes the routing rules and DNS, FakeDNS included. The Routing menu (formerly Routing Rule) chooses it or a manual rule set.
- `IPIfNonMatch` rule sets: a final catch-all rule becomes the default outbound, so IP rules are still checked for domains that match no domain rule.
- One server at a time: the "Use All" mode and the `balance` route are gone; rules that used it go to the selected server.

Code: [SubscriptionRouting.m](V2RayX/SubscriptionRouting.m), [AppDelegate.m](V2RayX/AppDelegate.m)

## Core and geodata

- Xray 26.9.9 (a prerelease) and Loyalsoldier geodata are bundled, pinned by checksum in [dlcorex.sh](V2RayX/dlcorex.sh).
- A subscription's routing profile gets its own geodata, from the profile's source or the latest Loyalsoldier release, updated daily into `~/Library/Application Support/V2RayXS/geodata` once Xray accepts it with the profile's rules. A full Xray config uses the geodata of its subscription's profile.
- `xray`, `geoip.dat` and `geosite.dat` in `~/Library/Application Support/V2RayXS/xray-core/` replace the bundled core. It must be Xray 26.9.9 or later: older cores silently ignore settings the app generates. `geoip.dat` and `geosite.dat` alone replace only the geodata.
- Advanced > Core > Update Geodata installs the latest Loyalsoldier geodata into `xray-core/` once Xray accepts it with the manual rule sets.

## TUN mode

- The core's connections are bound to the physical interface instead of routing server addresses around the tunnel, so a shared address such as Cloudflare's cannot carry other sites past the proxy. Only a custom JSON config still gets host routes for its servers.
- A new network (interface or gateway) rebuilds the TUN setup. Domain rules work through sniffing.
- IPv6 does not go through the tunnel, so TUN mode rejects it (`::/1` and `8000::/1`) and apps fall back to IPv4.
- While TUN is on, the helper points the system resolver at public resolvers through the tunnel, as a VPN's DNS settings would, and keeps the network's resolvers for the servers' domains. It restores them when TUN stops, including what a crashed helper left behind.
- Another VPN that sends all names to its own DNS server takes precedence over these resolvers. Limit that VPN's DNS to its own domains in its client.

Check that TUN left nothing behind once it is off. The first two print nothing, the third shows the network's own resolvers:

```shell
netstat -rn -f inet | grep -E '^(0/1|128.0/1)'
netstat -rn -f inet6 | grep -E '^(::/1|8000::/1)'
scutil --dns | head -8
```

If something is left, turn TUN on and off again, reconnect to the network or restart the Mac.

Code: [tun_dns.m](v2rayx_sysconf/tun_dns.m), [tun_session_controller.m](v2rayx_sysconf/tun_session_controller.m)

## Build and release

- macOS 13 or later for all targets.
- Release CI only; the upstream preview workflow is removed. Update checks, release links and the build instructions point to ykvlv/V2RayXS.
- Checks: the build commands at the top of [tests/check_routing.m](tests/check_routing.m) and [tests/check_subscriptions.m](tests/check_subscriptions.m).
