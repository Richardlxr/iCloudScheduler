// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "iCloudScheduler",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "iCloudScheduler", targets: ["SchedulerApp"]),
        .executable(name: "SchedulerChecks", targets: ["SchedulerChecks"])
    ],
    targets: [
        .target(name: "SchedulerCore"),
        .executableTarget(name: "SchedulerApp", dependencies: ["SchedulerCore"]),
        .executableTarget(name: "SchedulerChecks", dependencies: ["SchedulerCore"])
    ]
)
