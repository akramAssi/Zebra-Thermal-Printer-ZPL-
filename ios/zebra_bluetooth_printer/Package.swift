// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "zebra_bluetooth_printer",
    platforms: [
        .iOS("15.0")
    ],
    products: [
        .library(name: "zebra-bluetooth-printer", targets: ["zebra_bluetooth_printer"])
    ],
    dependencies: [
        .package(name: "FlutterFramework", path: "../FlutterFramework")
    ],
    targets: [
        .target(
            name: "zebra_bluetooth_printer",
            dependencies: [
                .product(name: "FlutterFramework", package: "FlutterFramework")
            ],
            linkerSettings: [
                .linkedFramework("ExternalAccessory"),
                .linkedFramework("Network")
            ]
        )
    ]
)
