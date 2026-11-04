import ProjectDescription

// Identifiers are duplicated from Shared/BundleIDs.swift; BundleIDsTests keeps them consistent.
let appID = "io.github.eugenehil.guardian"
let extID = "io.github.eugenehil.guardian.ext"

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

/// Consumers of the CoreBridge static framework link the CMake-built guardian-core archive themselves.
let coreLib = "$(SRCROOT)/build/corecpp/libguardian_core.a -lc++"

/// System frameworks used by the app's services (also compiled into GuardianAppTests).
let appFrameworks: [TargetDependency] = [
    .sdk(name: "SystemExtensions", type: .framework),
    .sdk(name: "UserNotifications", type: .framework),
]

let project = Project(
    name: "Guardian",
    targets: [
        .target(
            name: "GuardianApp",
            destinations: .macOS,
            product: .app,
            // Finder labels a bundle with its file name, not CFBundleDisplayName, so the product
            // is "Guardian.app" while the target and scheme stay "GuardianApp".
            productName: "Guardian",
            bundleId: appID,
            infoPlist: .extendingDefault(with: [
                "LSUIElement": true,
                "CFBundleDisplayName": "Guardian",
                // ATS would reject the self-signed server certificate despite the SPKI pin (ADR-0003).
                "NSAppTransportSecurity": ["NSAllowsArbitraryLoads": true],
                "NSSystemExtensionUsageDescription": "Guardian installs a system extension that enforces DLP policy.",
            ]),
            sources: ["GuardianApp/Sources/**", "Shared/**"],
            resources: ["GuardianApp/Resources/**"],
            entitlements: .file(path: "GuardianApp/GuardianApp.entitlements"),
            dependencies: [.target(name: "DlpExtension")] + appFrameworks,
            settings: .settings(base: adhoc.merging(["ASSETCATALOG_COMPILER_APPICON_NAME": "AppIcon"]) { $1 })
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
            settings: .settings(base: adhoc.merging(["OTHER_LDFLAGS": .string(coreLib)]) { $1 })
        ),
        .target(
            name: "GuardianAppTests",
            destinations: .macOS,
            product: .unitTests,
            bundleId: "\(appID).tests",
            sources: [
                "Shared/**",
                .glob(
                    "GuardianApp/Sources/**",
                    excluding: ["GuardianApp/Sources/Entry/**", "GuardianApp/Sources/Views/**"]
                ),
                "GuardianApp/Tests/**",
            ],
            dependencies: [.target(name: "CoreBridge")] + appFrameworks,
            settings: .settings(base: adhoc.merging(["OTHER_LDFLAGS": .string(coreLib)]) { $1 })
        ),
        // Hosts the CMake pre-build script alone: its unsandboxed script phase must not share a
        // target with CoreBridge's "Copy Headers" phase (Xcode warns about that combination).
        .target(
            name: "GuardianCoreLib",
            destinations: .macOS,
            product: .staticLibrary,
            bundleId: "\(appID).corelib",
            sources: ["CoreBridge/CoreLib/**"],
            scripts: [
                .pre(
                    script: "\"$SRCROOT/scripts/build-corecpp.sh\"",
                    name: "Build guardian-core",
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
            dependencies: [.target(name: "GuardianCoreLib")],
            settings: .settings(base: adhoc.merging([
                "DEFINES_MODULE": "YES",
                "CLANG_CXX_LANGUAGE_STANDARD": "c++17",
                "CLANG_ENABLE_OBJC_ARC": "YES",
                "HEADER_SEARCH_PATHS": "$(SRCROOT)/external/guardian-core/include",
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
        .scheme(name: "GuardianApp", shared: true, buildAction: .buildAction(targets: ["GuardianApp"])),
        .scheme(
            name: "DlpExtensionTests", shared: true,
            buildAction: .buildAction(targets: ["DlpExtensionTests"]),
            testAction: .targets(["DlpExtensionTests"])
        ),
        .scheme(
            name: "GuardianAppTests", shared: true,
            buildAction: .buildAction(targets: ["GuardianAppTests"]),
            testAction: .targets(["GuardianAppTests"])
        ),
        .scheme(
            name: "CoreBridgeTests", shared: true,
            buildAction: .buildAction(targets: ["CoreBridgeTests"]),
            testAction: .targets(["CoreBridgeTests"])
        ),
    ]
)
