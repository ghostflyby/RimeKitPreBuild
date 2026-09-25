// swift-tools-version: 6.2
import PackageDescription

// RimeKit 的构建期部署工具(静态自包含发行):
// 依赖声明整组锁定 librimeStatic——RimeKit/RimeC 无桩、librime 静态直链,
// 工具二进制零 @rpath、零动态框架,对 swift build / xcodebuild、任何目的地
// 均为同一形态。
let package = Package(
  name: "RimeKitPreBuild",
  platforms: [
    .macOS(.v15)
  ],
  products: [
    .executable(name: "RimeDeploy", targets: ["RimeDeploy"]),
  ],
  dependencies: [
    .package(
      url: "https://github.com/ghostflyby/RimeKit.git",
      from: "0.0.17",
      traits: ["librimeStatic"]
    ),
  ],
  targets: [
    // 引擎驱动:经 RimeKit 进程内 API(setup/initializeDeployer/prebuild/
    // deploy/finalize + logsink 错误收集),静态 traits 下工具自包含。
    .target(
      name: "RimeDeployCore",
      dependencies: [.product(name: "RimeKit", package: "RimeKit")]
    ),
    // 命令行外壳:解析 argv、执行、报告。全部逻辑在库里以便测试直接调用。
    .executableTarget(
      name: "RimeDeploy",
      dependencies: ["RimeDeployCore"],
      linkerSettings: [
        // 静态 librime 为 C++ 产物,不携带 C++ 运行时。
        .linkedLibrary("c++")
      ]
    ),
    // 每个用例一个进程:退出测试矩阵 + spawn 真实二进制的冒烟用例。
    .testTarget(
      name: "RimeDeployToolTests",
      dependencies: ["RimeDeployCore"],
      path: "Tests/RimeDeployToolTests"
    ),
  ]
)
