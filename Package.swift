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
    .plugin(
      name: "RimeDeployPlugin",
      targets: ["RimeDeployPlugin"]),
  ],
  dependencies: [
    .package(
      url: "https://github.com/ghostflyby/RimeKit.git",
      branch: "feat/rime-deploy",
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
    .plugin(
      name: "RimeDeployPlugin",
      capability: .buildTool(),
      dependencies: ["RimeDeploy"],
      path: "Plugins/RimeDeployPlugin"
    ),
    // 每个用例一个进程:退出测试矩阵 + spawn 真实二进制的冒烟用例。
    .testTarget(
      name: "RimeDeployToolTests",
      dependencies: ["RimeDeployCore"],
      path: "Tests/RimeDeployToolTests"
    ),
    // 插件附着到本包自己的数据目录(惯例名 + 非常规名并存),断言编译数据
    // 进 bundle、布局保留,并经 RimeKit(静态)进程内加载验证。
    .testTarget(
      name: "RimeDeployPluginTests",
      dependencies: [.product(name: "RimeKit", package: "RimeKit")],
      path: "Tests/RimeDeployPluginTests",
      exclude: ["RimeData", "MyRimeData"],
      plugins: [.plugin(name: "RimeDeployPlugin")]
    ),
  ]
)
