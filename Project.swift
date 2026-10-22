import ProjectDescription

// Identifiers are duplicated from Shared/BundleIDs.swift; BundleIDsTests keeps them consistent.
let appID = "io.github.eugenehil.warden"
let extID = "io.github.eugenehil.warden.ext"

/// Ad-hoc signing per ADR-0001: Xcode never signs; scripts/sign.sh signs inside-out with codesign.
let adhoc: SettingsDictionary = [
    "CODE_SIGN_STYLE": "Manual",
    "CODE_SIGN_IDENTITY": "-",
    "DEVELOPMENT_TEAM": "",
    "ENABLE_HARDENED_RUNTIME": "NO",
    "SWIFT_VERSION": "6.0",
    "SWIFT_STRICT_CONCURRENCY": "complete",
    "SWIFT_TREAT_WARNINGS_AS_ERRORS": "YES",
    "GCC_TREAT_WARNINGS_AS_ERRORS": "YES",
    "OTHER_CPLUSPLUSFLAGS": "$(inherited) -Wall -Wextra -Wpedantic",
    "MACOSX_DEPLOYMENT_TARGET": "15.0",
]

/// Consumers of the CoreBridge static framework link the CMake-built warden-core archive themselves.
let coreLib = "$(SRCROOT)/build/corecpp/libwarden_core.a -lc++"

let project = Project(
    name: "Warden",
    targets: [
        .target(
            name: "WardenApp",
            destinations: .macOS,
            product: .app,
            bundleId: appID,
            infoPlist: .extendingDefault(with: [
                "LSUIElement": true,
                "NSSystemExtensionUsageDescription": "Warden installs a system extension that enforces DLP policy.",
            ]),
            sources: ["WardenApp/Sources/**", "Shared/**"],
            entitlements: .file(path: "WardenApp/WardenApp.entitlements"),
            dependencies: [.target(name: "DlpExtension")],
            settings: .settings(base: adhoc)
        ),
        .target(
            name: "DlpExtension",
            destinations: .macOS,
            product: .systemExtension,
            bundleId: extID,
            infoPlist: .file(path: "DlpExtension/Info.plist"),
            sources: ["DlpExtension/Sources/**", "Shared/**"],
            entitlements: .file(path: "DlpExtension/DlpExtension.entitlements"),
            dependencies: [.target(name: "CoreBridge")],
            settings: .settings(base: adhoc.merging([
                "OTHER_LDFLAGS": .string("-lEndpointSecurity \(coreLib)"),
                "PRODUCT_NAME": .string(extID),
            ]) { $1 })
        ),
        .target(
            name: "DlpExtensionTests",
            destinations: .macOS,
            product: .unitTests,
            bundleId: "\(extID).tests",
            sources: ["Shared/**", "DlpExtension/Sources/Logic/**", "DlpExtension/Tests/**"],
            dependencies: [.target(name: "CoreBridge")],
            settings: .settings(base: adhoc)
        ),
        .target(
            name: "WardenAppTests",
            destinations: .macOS,
            product: .unitTests,
            bundleId: "\(appID).tests",
            sources: ["Shared/**", "WardenApp/Sources/Logic/**", "WardenApp/Tests/**"],
            dependencies: [.target(name: "CoreBridge")],
            settings: .settings(base: adhoc)
        ),
        // Hosts the CMake pre-build script alone: its unsandboxed script phase must not share a
        // target with CoreBridge's "Copy Headers" phase (Xcode warns about that combination).
        .target(
            name: "WardenCoreLib",
            destinations: .macOS,
            product: .staticLibrary,
            bundleId: "\(appID).corelib",
            sources: ["CoreBridge/CoreLib/**"],
            scripts: [
                .pre(
                    script: "\"$SRCROOT/scripts/build-corecpp.sh\"",
                    name: "Build warden-core",
                    basedOnDependencyAnalysis: false
                ),
            ],
            settings: .settings(base: adhoc.merging(["ENABLE_USER_SCRIPT_SANDBOXING": "NO"]) { $1 })
        ),
        .target(
            name: "CoreBridge",
            destinations: .macOS,
            product: .staticFramework,
            bundleId: "\(appID).corebridge",
            sources: ["CoreBridge/Sources/**"],
            headers: .headers(public: ["CoreBridge/Sources/**/*.h"]),
            dependencies: [.target(name: "WardenCoreLib")],
            settings: .settings(base: adhoc.merging([
                "DEFINES_MODULE": "YES",
                "CLANG_CXX_LANGUAGE_STANDARD": "c++17",
                "CLANG_ENABLE_OBJC_ARC": "YES",
                "HEADER_SEARCH_PATHS": "$(SRCROOT)/external/warden-core/include",
                "OTHER_LDFLAGS": .string(coreLib),
            ]) { $1 })
        ),
        .target(
            name: "CoreBridgeTests",
            destinations: .macOS,
            product: .unitTests,
            bundleId: "\(appID).corebridge.tests",
            sources: ["CoreBridge/Tests/**"],
            dependencies: [.target(name: "CoreBridge")],
            settings: .settings(base: adhoc.merging(["OTHER_LDFLAGS": .string(coreLib)]) { $1 })
        ),
    ],
    schemes: [
        .scheme(name: "WardenApp", shared: true, buildAction: .buildAction(targets: ["WardenApp"])),
        .scheme(
            name: "DlpExtensionTests", shared: true,
            buildAction: .buildAction(targets: ["DlpExtensionTests"]),
            testAction: .targets(["DlpExtensionTests"])
        ),
        .scheme(
            name: "WardenAppTests", shared: true,
            buildAction: .buildAction(targets: ["WardenAppTests"]),
            testAction: .targets(["WardenAppTests"])
        ),
        .scheme(
            name: "CoreBridgeTests", shared: true,
            buildAction: .buildAction(targets: ["CoreBridgeTests"]),
            testAction: .targets(["CoreBridgeTests"])
        ),
    ]
)
