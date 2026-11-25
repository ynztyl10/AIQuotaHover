// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "AIQuotaHover",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "AIQuotaHover", targets: ["AIQuotaHover"])
    ],
    targets: [
        .target(
            name: "QuotaAdapters",
            path: "Sources/CodexBarLocalBridge"
        ),
        .executableTarget(
            name: "AIQuotaHover",
            dependencies: ["QuotaAdapters"],
            path: "Sources/AIQuotaHover"
        )
    ]
)
