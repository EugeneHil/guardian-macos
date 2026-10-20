import ProjectDescription

let adhoc: SettingsDictionary = [
    "CODE_SIGN_STYLE": "Manual",
    "CODE_SIGN_IDENTITY": "-",
    "DEVELOPMENT_TEAM": "",
    "ENABLE_HARDENED_RUNTIME": "NO",
    "SWIFT_VERSION": "5.0",
    "MACOSX_DEPLOYMENT_TARGET": "15.0",
]

let project = Project(
    name: "Spike",
    targets: [
        .target(
            name: "SpikeApp",
            destinations: .macOS,
            product: .app,
            bundleId: "dev.warden.spike",
            infoPlist: .extendingDefault(with: [
                "NSSystemExtensionUsageDescription": "Spike: proves an ad-hoc signed Endpoint Security extension activates.",
            ]),
            sources: ["App/**"],
            entitlements: .file(path: "App/SpikeApp.entitlements"),
            dependencies: [.target(name: "SpikeExt")],
            settings: .settings(base: adhoc)
        ),
        .target(
            name: "SpikeExt",
            destinations: .macOS,
            product: .systemExtension,
            bundleId: "dev.warden.spike.ext",
            infoPlist: .file(path: "Ext/Info.plist"),
            sources: ["Ext/**/*.swift"],
            entitlements: .file(path: "Ext/SpikeExt.entitlements"),
            settings: .settings(base: adhoc.merging(["OTHER_LDFLAGS": "-lEndpointSecurity"]) { $1 })
        ),
    ]
)
