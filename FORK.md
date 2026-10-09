# Fork differences

Compared with [tzmax/V2RayXS at 247e771](https://github.com/tzmax/V2RayXS/commit/247e7713b48d1ed3dec2646f9a6afb64e3b28dff).

| Difference | Code |
|---|---|
| Subscription HWID/device headers and neutral User-Agent; one fixed HWID across installations. | [ConfigImporter.m](V2RayX/ConfigImporter.m) |
| `IPIfNonMatch`: omit the bare final catch-all and use its outbound as default in single-server mode. | [AppDelegate.m](V2RayX/AppDelegate.m) |
| Minimum macOS 12.0 for all targets. | [project.pbxproj](V2RayXS.xcodeproj/project.pbxproj) |
| Release CI only; upstream preview workflow omitted. | [build-actions.yml](.github/workflows/build-actions.yml) |
