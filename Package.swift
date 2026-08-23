// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "TaxKit",
    platforms: [.iOS(.v26), .macOS(.v26), .watchOS(.v26)],
    products: [
        .library(name: "TaxKit", targets: ["TaxKit"])
    ],
    targets: [
        .target(
            name: "TaxKit",
            resources: [.copy("Resources/Rules")],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .executableTarget(
            name: "ReliefCodeGenerator",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .plugin(
            name: "GenerateReliefCodes",
            capability: .command(
                intent: .custom(
                    verb: "generate-relief-codes",
                    description: "Regenerate ReliefCode constants from the rulebook JSON"
                ),
                permissions: [
                    .writeToPackageDirectory(reason: "Writes Sources/TaxKit/Rules/ReliefCode+Generated.swift")
                ]
            ),
            dependencies: ["ReliefCodeGenerator"]
        ),
        .testTarget(
            name: "TaxKitTests",
            dependencies: ["TaxKit"],
            resources: [.copy("Fixtures")],
            swiftSettings: [.swiftLanguageMode(.v6)]
        )
    ]
)
