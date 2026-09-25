# RimeKitPreBuild

Rime 数据的**构建期部署工具**与配套 build tool 插件:把 target 内附带的
Rime 数据(`*.schema.yaml`、`*.dict.yaml` 及其引用的一切)在**构建期**编译
成运行期直载的二进制产物,以目录资源的形式交回 target——应用永远不需要
在首次启动时部署。

工具静态链接 librime(自包含,零 `@rpath` 动态框架依赖),对
swift build / xcodebuild、任何目的地、任何 traits 选型均为同一形态。

## 结构

- `RimeDeployCore`:引擎驱动(经 RimeKit 进程内 API,librimeStatic
  traits 下静态自包含;logsink 错误收集使「link 失败仍报成功」类
  librime 缺陷变为可编程判据)
- `RimeDeploy`:命令行外壳(argv 解析、执行、报告)
- `RimeDeployPlugin`:build tool 插件——按内容(`*.schema.yaml`)发现
  target 内**全部**数据目录,各编译一份、各以目录名进 bundle

## 消费方

在依赖 RimeKit 的同时声明本包,并对需要编译数据的 target 附着插件:

```swift
.package(url: "https://github.com/ghostflyby/RimeKit.git", from: "…"),
.package(url: "https://github.com/ghostflyby/RimeKitPreBuild.git", from: "…"),

.executableTarget(
  name: "App",
  dependencies: [.product(name: "RimeKit", package: "RimeKit")],
  exclude: ["RimeData"],
  plugins: [.plugin(name: "RimeDeployPlugin", package: "RimeKitPreBuild")]
)
```

## 发布

推送 `v*` tag → GitHub Actions 构建静态工具、打包 artifactbundle 并
发布到 Releases;消费方经 binary target 的校验和锁定版本。

License: MPL-2.0
