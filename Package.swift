// swift-tools-version: 6.2
import PackageDescription

// RimeKit 的构建期部署工具(静态自包含发行):
// 挂 RimeKitStatic product——librime(含 C++ 运行时传播)静态并入工具二进制,
// 零 @rpath、零动态框架,对 swift build / xcodebuild、任何目的地均为同一形态。
let package = Package(
  name: "RimeKitPreBuild",
  platforms: [
    .macOS(.v15)
  ],
  products: [
    .executable(name: "RimeDeploy", targets: ["RimeDeployCLI"]),
  ],
  dependencies: [
    .package(
      url: "https://github.com/ghostflyby/RimeKit.git",
      from: "0.0.31"
    ),
  ],
  targets: [
    // 引擎驱动:经 RimeKit 进程内 API(setup/initializeDeployer/prebuild/
    // deploy/finalize + logsink 错误收集),RimeKitStatic 下工具自包含。
    .target(
      name: "RimeDeployCore",
      dependencies: [.product(name: "RimeKitStatic", package: "RimeKit")]
    ),
    // 命令行外壳:解析 argv、执行、报告。全部逻辑在库里以便测试直接调用。
    // target 名不可与 RimeKit 的 binaryTarget `RimeDeploy` 同名——RimeKit 0.0.31
    // 起 traits 移除,消费方构建会急切物化依赖包全部 target 并强校验跨包唯一;
    // 产品名保持 RimeDeploy,链接产物名跟产品走,发布物与测试定位均不受影响。
    .executableTarget(
      name: "RimeDeployCLI",
      dependencies: ["RimeDeployCore"],
      path: "Sources/RimeDeploy",
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
