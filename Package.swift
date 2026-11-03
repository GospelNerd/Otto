// swift-tools-version: 6.2

import Foundation
import PackageDescription

let package = Package(
  name: "Otto",
  platforms: [.macOS(.v15), .iOS(.v18)],
  products: [
    .executable(name: "Otto", targets: ["OttoApp"]),
    .executable(name: "ottoctl", targets: ["ottoctl"]),
    .executable(name: "otto-mcp", targets: ["otto-mcp"]),
    .executable(name: "otto-hermes-bridge", targets: ["otto-hermes-bridge"]),
    .executable(name: "otto-openai-agent", targets: ["otto-openai-agent"]),
    .executable(name: "otto-hookd", targets: ["otto-hookd"]),
    .executable(name: "otto-release", targets: ["otto-release"]),
    .executable(name: "ottod", targets: ["ottod"]),
    .executable(name: "otto-performance", targets: ["otto-performance"]),
    .executable(name: "otto-voice-benchmark", targets: ["otto-voice-benchmark"]),
    .executable(name: "otto-mobile-demo-host", targets: ["otto-mobile-demo-host"]),
    .library(name: "OttoModels", targets: ["OttoModels"]),
    .library(name: "OttoMemory", targets: ["OttoMemory"]),
    .library(name: "OttoCore", targets: ["OttoCore"]),
    .library(name: "OttoPersistence", targets: ["OttoPersistence"]),
    .library(name: "OttoRuntime", targets: ["OttoRuntime"]),
    .library(name: "OttoHarness", targets: ["OttoHarness"]),
    .library(name: "OttoTools", targets: ["OttoTools"]),
    .library(name: "OttoControl", targets: ["OttoControl"]),
    .library(name: "OttoCLI", targets: ["OttoCLI"]),
    .library(name: "OttoMCP", targets: ["OttoMCP"]),
    .library(name: "OttoApplicationTools", targets: ["OttoApplicationTools"]),
    .library(name: "OttoServices", targets: ["OttoServices"]),
    .library(name: "OttoVoice", targets: ["OttoVoice"]),
    .library(name: "OttoDocuments", targets: ["OttoDocuments"]),
    .library(name: "OttoBrowser", targets: ["OttoBrowser"]),
    .library(name: "OttoMedia", targets: ["OttoMedia"]),
    .library(name: "OttoSecurity", targets: ["OttoSecurity"]),
    .library(name: "OttoWorktrees", targets: ["OttoWorktrees"]),
    .library(name: "OttoCommercial", targets: ["OttoCommercial"]),
    .library(name: "OttoObservability", targets: ["OttoObservability"]),
    .library(name: "OttoRemote", targets: ["OttoRemote"]),
    .library(name: "OttoRPCContracts", targets: ["OttoRPCContracts"]),
    .library(name: "OttoHostRuntime", targets: ["OttoHostRuntime"]),
    .library(name: "OttoHostTransport", targets: ["OttoHostTransport"]),
    .library(name: "OttoMobileClient", targets: ["OttoMobileClient"]),
    .library(name: "OttoHooks", targets: ["OttoHooks"]),
  ],
  dependencies: [
    .package(url: "https://github.com/apple/swift-crypto.git", exact: "4.5.1"),
    .package(url: "https://github.com/hummingbird-project/hummingbird.git", exact: "2.26.0"),
    .package(
      url: "https://github.com/hummingbird-project/hummingbird-websocket.git",
      exact: "2.7.0"
    ),
    .package(url: "https://github.com/migueldeicaza/SwiftTerm.git", exact: "1.15.0"),
    .package(url: "https://github.com/apple/swift-log.git", exact: "1.14.0"),
    .package(url: "https://github.com/apple/swift-nio-ssl.git", exact: "2.37.2"),
    .package(
      url: "https://github.com/livekit/livekit-wakeword",
      revision: "95448a7559c453fcd87645bd67b247ffb45f85b0"
    ),
  ],
  targets: [
    .target(name: "OttoModels"),
    .target(name: "OttoObjCSupport"),
    // Apple SDKs ship a SQLite3 module; elsewhere the system libsqlite3 is wrapped here.
    .systemLibrary(
      name: "CSQLite",
      pkgConfig: "sqlite3",
      providers: [.apt(["libsqlite3-dev"]), .yum(["sqlite-devel"])]
    ),
    .target(
      name: "OttoMemory",
      dependencies: [.target(name: "CSQLite", condition: .when(platforms: [.linux]))],
      linkerSettings: [.linkedLibrary("sqlite3")]
    ),
    .target(
      name: "OttoPersistence",
      dependencies: [
        "OttoModels", "OttoTools",
        .target(name: "CSQLite", condition: .when(platforms: [.linux])),
      ],
      linkerSettings: [.linkedLibrary("sqlite3")]
    ),
    .target(
      name: "OttoCore",
      dependencies: ["OttoModels", "OttoPersistence", "OttoRuntime"]
    ),
    .target(
      name: "OttoRuntime",
      dependencies: [
        "OttoModels",
        // Keychain-backed secrets are macOS-only; the Linux daemon builds the runtime without them.
        .target(name: "OttoSecurity", condition: .when(platforms: [.macOS])),
        .product(name: "Crypto", package: "swift-crypto", condition: .when(platforms: [.linux])),
      ]),
    .target(name: "OttoHarness", dependencies: ["OttoModels", "OttoTools"]),
    .target(name: "OttoTools", dependencies: ["OttoModels"]),
    .target(
      name: "OttoHooks",
      dependencies: [
        "OttoControl", "OttoModels", "OttoSecurity", "OttoTools",
        .product(name: "Crypto", package: "swift-crypto"),
      ]
    ),
    .target(name: "OttoControl", dependencies: ["OttoTools"]),
    .target(name: "OttoCLI", dependencies: ["OttoControl", "OttoTools"]),
    .target(name: "OttoMCP", dependencies: ["OttoControl", "OttoModels", "OttoTools"]),
    .target(name: "OttoDocuments", dependencies: ["OttoModels"]),
    .target(
      name: "OttoBrowser",
      dependencies: ["OttoModels"],
      linkerSettings: [.linkedLibrary("sqlite3")]
    ),
    .target(name: "OttoMedia", dependencies: []),
    .target(
      name: "OttoSecurity",
      dependencies: ["OttoModels", "OttoTools"],
      linkerSettings: [.linkedFramework("Security")]
    ),
    .target(name: "OttoWorktrees", dependencies: ["OttoModels"]),
    .target(
      name: "OttoCommercial",
      dependencies: [
        .target(name: "OttoSecurity", condition: .when(platforms: [.macOS])),
        .product(name: "Crypto", package: "swift-crypto", condition: .when(platforms: [.linux])),
      ],
      linkerSettings: [.linkedFramework("CryptoKit", .when(platforms: [.macOS]))]
    ),
    .target(name: "OttoObservability", dependencies: ["OttoModels", "OttoRuntime", "OttoTools"]),
    .target(name: "OttoRPCContracts", dependencies: ["OttoModels"]),
    .target(
      name: "OttoHostRuntime",
      dependencies: ["OttoModels", "OttoRPCContracts"]
    ),
    .target(
      name: "OttoHostTransport",
      dependencies: [
        "OttoHostRuntime", "OttoModels", "OttoRPCContracts",
        .product(name: "Hummingbird", package: "hummingbird"),
        .product(name: "HummingbirdTLS", package: "hummingbird"),
        .product(name: "HummingbirdWebSocket", package: "hummingbird-websocket"),
      ]
    ),
    .target(
      name: "OttoMobileClient",
      dependencies: [
        "OttoCommercial", "OttoModels", "OttoRPCContracts",
        .product(name: "Crypto", package: "swift-crypto", condition: .when(platforms: [.linux])),
      ],
      linkerSettings: [
        .linkedFramework("Security", .when(platforms: [.iOS, .macOS]))
      ]
    ),
    .target(
      name: "OttoRemote",
      dependencies: [
        "OttoRuntime", "OttoTools",
        "OttoCommercial", "OttoRPCContracts",
        .product(name: "Crypto", package: "swift-crypto", condition: .when(platforms: [.linux])),
      ],
      linkerSettings: [
        .linkedFramework("CryptoKit", .when(platforms: [.macOS])),
        .linkedFramework("Security", .when(platforms: [.macOS])),
      ]
    ),
    .target(
      name: "OttoApplicationTools",
      dependencies: [
        "OttoBrowser", "OttoCore", "OttoDocuments", "OttoMedia", "OttoMemory", "OttoModels",
        "OttoRuntime", "OttoTools", "OttoWorktrees",
      ]
    ),
    .target(
      name: "OttoServices",
      dependencies: [
        "OttoApplicationTools", "OttoBrowser", "OttoCommercial", "OttoControl", "OttoCore",
        "OttoDocuments",
        "OttoMedia", "OttoMemory", "OttoModels", "OttoObservability",
        "OttoRuntime", "OttoTools", "OttoWorktrees", "OttoRemote", "OttoSecurity", "OttoHooks",
        "OttoHostRuntime", "OttoHostTransport", "OttoRPCContracts",
      ],
      resources: [.copy("Resources/PhotonBridge")]
    ),
    .target(
      name: "OttoVoice",
      dependencies: [
        "OttoModels", "OttoObjCSupport", "OttoSecurity", "OttoTools",
        .product(name: "LiveKitWakeWord", package: "livekit-wakeword"),
      ],
      linkerSettings: [.linkedFramework("AVFoundation")]
    ),
    .executableTarget(name: "ottoctl", dependencies: ["OttoCLI", "OttoControl", "OttoModels"]),
    .executableTarget(
      name: "otto-mobile-demo-host",
      dependencies: [
        "OttoHostRuntime", "OttoHostTransport", "OttoModels", "OttoRemote", "OttoRPCContracts",
      ]
    ),
    .executableTarget(name: "otto-mcp", dependencies: ["OttoMCP", "OttoControl", "OttoModels"]),
    .executableTarget(
      name: "otto-hermes-bridge",
      dependencies: [
        "OttoControl", "OttoMCP", "OttoModels", "OttoRuntime", "OttoSecurity", "OttoTools",
      ]),
    .executableTarget(
      name: "otto-openai-agent",
      dependencies: ["OttoControl", "OttoHarness", "OttoModels", "OttoTools"]
    ),
    .executableTarget(
      name: "otto-hookd",
      dependencies: [
        "OttoControl", "OttoHooks", "OttoModels", "OttoSecurity", "OttoTools",
        .product(name: "Hummingbird", package: "hummingbird"),
      ]
    ),
    .executableTarget(
      name: "otto-release",
      dependencies: [
        "OttoCommercial", "OttoModels", "OttoRemote",
        .product(name: "Crypto", package: "swift-crypto", condition: .when(platforms: [.linux])),
      ]
    ),
    .executableTarget(
      name: "ottod",
      dependencies: [
        "OttoModels", "OttoRemote",
        .target(name: "OttoCommercial", condition: .when(platforms: [.macOS])),
      ]
    ),
    .executableTarget(
      name: "otto-performance",
      dependencies: ["OttoCore", "OttoModels"]
    ),
    .executableTarget(
      name: "otto-voice-benchmark",
      dependencies: ["OttoModels", "OttoSecurity", "OttoTools", "OttoVoice"]
    ),
    .executableTarget(
      name: "OttoApp",
      dependencies: [
        "OttoApplicationTools", "OttoBrowser", "OttoCore", "OttoDocuments", "OttoMedia",
        "OttoModels", "OttoPersistence", "OttoRuntime", "OttoSecurity", "OttoServices", "OttoTools",
        "OttoVoice", "OttoWorktrees", "OttoCommercial", "OttoObservability", "OttoRemote",
        .product(name: "SwiftTerm", package: "SwiftTerm"),
      ],
      resources: [
        .copy("Resources/Themes"),
        .copy("Resources/Fonts"),
        .copy("Resources/Deck"),
        .copy("Resources/DiagramRenderer"),
        .copy("Resources/ProviderLogos"),
        .copy("Resources/Brand"),
        .copy("Resources/PluginLogos"),
      ]
    ),
    .testTarget(
      name: "OttoCoreTests",
      dependencies: [
        "OttoCore", "OttoModels", "OttoPersistence",
        .target(name: "CSQLite", condition: .when(platforms: [.linux])),
      ]),
    .testTarget(
      name: "OttoMemoryTests",
      dependencies: ["OttoMemory", .target(name: "CSQLite", condition: .when(platforms: [.linux]))]
    ),
    .testTarget(name: "OttoModelsTests", dependencies: ["OttoModels", "OttoCore"]),
    .testTarget(
      name: "OttoPersistenceTests",
      dependencies: ["OttoModels", "OttoPersistence", "OttoTools"],
      resources: [.copy("Fixtures")]
    ),
    .testTarget(
      name: "OttoRuntimeTests",
      dependencies: ["OttoModels", "OttoRuntime"],
      resources: [.copy("Fixtures")]
    ),
    .testTarget(name: "OttoHarnessTests", dependencies: ["OttoHarness", "OttoTools"]),
    .testTarget(name: "OttoToolsTests", dependencies: ["OttoTools"]),
    .testTarget(name: "OttoControlTests", dependencies: ["OttoControl", "OttoTools"]),
    .testTarget(
      name: "OttoProtocolTests",
      dependencies: ["OttoCLI", "OttoControl", "OttoMCP", "OttoTools"]
    ),
    .testTarget(
      name: "OttoApplicationToolsTests",
      dependencies: [
        "OttoApplicationTools", "OttoControl", "OttoCore", "OttoDocuments", "OttoMCP",
        "OttoModels", "OttoRuntime", "OttoTools", "OttoWorktrees",
      ]
    ),
    .testTarget(
      name: "OttoServicesTests",
      dependencies: [
        "OttoApplicationTools", "OttoCore", "OttoHostRuntime", "OttoModels", "OttoRemote",
        "OttoRPCContracts", "OttoRuntime", "OttoSecurity", "OttoServices", "OttoTools",
      ]
    ),
    .testTarget(
      name: "OttoHooksTests",
      dependencies: [
        "OttoApplicationTools", "OttoControl", "OttoHooks", "OttoModels", "OttoRuntime",
        "OttoSecurity", "OttoServices", "OttoTools", "otto-hookd",
        .product(name: "Crypto", package: "swift-crypto"),
      ]
    ),
    .testTarget(
      name: "OttoVoiceTests",
      dependencies: [
        "OttoApplicationTools", "OttoCore", "OttoModels", "OttoRuntime", "OttoSecurity",
        "OttoTools", "OttoVoice",
      ]
    ),
    .testTarget(name: "OttoDocumentsTests", dependencies: ["OttoDocuments", "OttoModels"]),
    .testTarget(name: "OttoBrowserTests", dependencies: ["OttoBrowser", "OttoModels"]),
    .testTarget(name: "OttoMediaTests", dependencies: ["OttoMedia"]),
    .testTarget(name: "OttoSecurityTests", dependencies: ["OttoSecurity", "OttoTools"]),
    .testTarget(name: "OttoWorktreesTests", dependencies: ["OttoModels", "OttoWorktrees"]),
    .testTarget(name: "OttoCommercialTests", dependencies: ["OttoCommercial"]),
    .testTarget(
      name: "OttoObservabilityTests",
      dependencies: ["OttoModels", "OttoObservability", "OttoRuntime", "OttoTools"]
    ),
    .testTarget(
      name: "OttoRemoteTests",
      dependencies: ["OttoCommercial", "OttoRemote", "OttoTools"]
    ),
    .testTarget(
      name: "OttoRPCContractTests",
      dependencies: ["OttoModels", "OttoRPCContracts"]
    ),
    .testTarget(
      name: "OttoHostRuntimeTests",
      dependencies: ["OttoHostRuntime", "OttoModels", "OttoRPCContracts"]
    ),
    .testTarget(
      name: "OttoHostTransportTests",
      dependencies: [
        "OttoHostRuntime", "OttoHostTransport", "OttoModels", "OttoRPCContracts",
        .product(name: "HummingbirdTesting", package: "hummingbird"),
        .product(name: "HummingbirdWSTesting", package: "hummingbird-websocket"),
      ]
    ),
    .testTarget(
      name: "OttoMobileClientTests",
      dependencies: ["OttoCommercial", "OttoMobileClient", "OttoModels", "OttoRPCContracts"]
    ),
    .testTarget(name: "OttoAppTests", dependencies: ["OttoApp"]),
  ]
)

// SwiftPM otherwise builds every test target even with --filter. This opt-in closure keeps
// messaging/runtime validation usable on hosts with limited disk; ordinary builds are unchanged.
let messagingTestsOnly =
  ProcessInfo.processInfo.environment["OTTO_MESSAGING_TESTS_ONLY"]
  ?? ProcessInfo.processInfo.environment["MUSE_MESSAGING_TESTS_ONLY"]
if messagingTestsOnly == "1" {
  let names: Set = [
    "OttoServicesTests", "OttoServices", "OttoApplicationTools", "OttoBrowser", "OttoCommercial",
    "OttoControl", "OttoCore", "OttoDocuments", "OttoMedia", "OttoMemory", "OttoModels",
    "OttoObservability", "OttoRuntime", "OttoTools", "OttoWorktrees", "OttoRemote",
    "OttoSecurity", "OttoHooks", "OttoHostRuntime", "OttoHostTransport", "OttoRPCContracts",
    "OttoPersistence",
  ]
  package.products.removeAll()
  package.targets.removeAll { !names.contains($0.name) }
}
