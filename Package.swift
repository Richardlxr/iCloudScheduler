// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "iCloudScheduler",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "iCloudScheduler", targets: ["SchedulerApp"]),
        .executable(name: "SchedulerChecks", targets: ["SchedulerChecks"])
    ],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.9.6")
    ],
    targets: [
        .target(name: "SchedulerCore"),
        .executableTarget(name: "SchedulerApp", dependencies: ["SchedulerCore", .product(name: "Sparkle", package: "Sparkle")],
                          linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]),
        .executableTarget(name: "SchedulerChecks", dependencies: ["SchedulerCore"])
    ]
)
