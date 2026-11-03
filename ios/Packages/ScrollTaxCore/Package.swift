// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ScrollTaxCore",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "ScrollTaxCore", targets: ["ScrollTaxCore"]),
    ],
    targets: [
        .target(name: "ScrollTaxCore"),
        .testTarget(name: "ScrollTaxCoreTests", dependencies: ["ScrollTaxCore"]),
    ]
)
