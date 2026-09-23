// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "RoamPiCore",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "RoamPiCore", targets: ["RoamPiCore"]),
        .executable(name: "RoamPiConfigValidator", targets: ["RoamPiConfigValidator"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-nio.git", exact: "2.103.0"),
        .package(url: "https://github.com/apple/swift-nio-ssh.git", exact: "0.15.0"),
        .package(url: "https://github.com/apple/swift-crypto.git", exact: "4.5.2"),
    ],
    targets: [
        .target(
            name: "RoamPiCore",
            dependencies: [
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "NIOSSH", package: "swift-nio-ssh"),
                .product(name: "Crypto", package: "swift-crypto"),
            ]
        ),
        .executableTarget(
            name: "RoamPiConfigValidator",
            dependencies: ["RoamPiCore"]
        ),
    ]
)
