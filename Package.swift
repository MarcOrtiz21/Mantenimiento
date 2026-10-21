// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "Mantenimiento",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "Mantenimiento", targets: ["Mantenimiento"]),
        .executable(name: "mantenimiento-fanctl", targets: ["MantenimientoFanTool"]),
        .executable(name: "mantenimiento-helper", targets: ["MantenimientoHelper"])
    ],
    targets: [
        .target(
            name: "MantenimientoCore",
            path: "Sources/MantenimientoCore"
        ),
        .executableTarget(
            name: "Mantenimiento",
            dependencies: ["MantenimientoCore"],
            path: "Sources/Mantenimiento"
        ),
        .executableTarget(
            name: "MantenimientoFanTool",
            dependencies: ["MantenimientoCore"],
            path: "Sources/MantenimientoFanTool"
        ),
        .executableTarget(
            name: "MantenimientoHelper",
            dependencies: ["MantenimientoCore"],
            path: "Sources/MantenimientoHelper"
        ),
        .testTarget(
            name: "MantenimientoTests",
            dependencies: ["Mantenimiento", "MantenimientoCore"],
            path: "Tests/MantenimientoTests"
        )
    ]
)
