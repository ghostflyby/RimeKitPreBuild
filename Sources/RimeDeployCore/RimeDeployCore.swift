// SPDX-FileCopyrightText: 2025-2026 ghostflyby
// SPDX-License-Identifier: MPL-2.0
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import RimeKit

/// 构建期 Rime 部署工具:把 YAML 源编译成客户端运行期加载的二进制产物——
/// 编译后的 schema 配置,以及每本词典的 table/prism/reverse 数据库。
///
/// 它是上游 `rime_deployer` 的 Swift 对应物,引擎操作全部走 RimeKit 的进程内
/// 共享根(`Rime.localShared`)——与运行期消费方同一套 Swift API,这条工具链
/// 本身就是该 API 的生产验证。
///
/// 逻辑放在库里而不是直接写在可执行文件里,是为了让测试能在进程内调用失败路径:
/// 构建命令非零退出会中断构建,应用插件的 target 无法对失败做断言。可执行文件
/// 只是这层的参数解析外壳。

public let rimeDeployToolName = "rime-deploy"

public enum RimeDeployMode: String, Sendable {
  /// 编译数据目录里每一个 `*.schema.yaml`;不产出 workspace 配置,
  /// 因此除数据本身之外不需要别的东西。
  case prebuild
  /// 另外编译 `default.yaml`,这要求其中有 `schema_list`。
  case deploy
}

public struct RimeDeployRequest: Sendable {
  /// 源数据:`*.schema.yaml`、`*.dict.yaml` 及其引用的一切。作为 librime 的
  /// `shared_data_dir` 传入,绝不写入。
  public var dataDirectory: String
  /// 编译产物目录,作为 librime 的 `staging_dir` 传入。
  public var outputDirectory: String
  /// 可写草稿目录,作为 `user_data_dir` 传入;默认 `<outputDirectory>-work`。
  public var workDirectory: String?
  public var mode: RimeDeployMode
  /// 调用方期望的产物,相对 `outputDirectory`。它们会被断言存在,
  /// 同时共同定义了"输出目录里哪些文件属于本次数据"——其余一律清除。
  public var expected: [String]
  /// 原样复制而非编译的数据,相对 `dataDirectory`。用于 librime 在**运行期**
  /// 读取的东西:`default.yaml`,或它按路径解析的 `opencc/` 之类目录。
  public var alsoCopy: [String]
  /// 以 INFO 而非 WARNING 级别记录日志。
  public var verbose: Bool

  public init(
    dataDirectory: String,
    outputDirectory: String,
    workDirectory: String? = nil,
    mode: RimeDeployMode = .prebuild,
    expected: [String] = [],
    alsoCopy: [String] = [],
    verbose: Bool = false
  ) {
    self.dataDirectory = dataDirectory
    self.outputDirectory = outputDirectory
    self.workDirectory = workDirectory
    self.mode = mode
    self.expected = expected
    self.alsoCopy = alsoCopy
    self.verbose = verbose
  }
}

public struct RimeDeployOutcome: Sendable {
  /// 因数据不再声明而被清除的文件数。
  public let removedStaleFiles: Int
  /// 已声明并通过校验的产物数。
  public let verifiedArtifacts: Int
}

public struct RimeDeployError: Error, CustomStringConvertible {
  public let description: String

  init(_ description: String) {
    self.description = description
  }
}

/// 部署门:进程级 librime 状态与本地共享根的 async 串行域。
///
/// librime 的引擎状态(`RimeApi`、部署目录)进程级全局,`Rime.localShared`
/// 是它唯一的本地执行域——两个部署同时进行就会写进彼此的目录;根 actor 串行化
/// 的是单次调用,不是一轮部署的调用组,门以 FIFO 保证整轮原子。命令行工具一进程
/// 一次,永远遇不到;任何在进程内驱动它的东西(测试,或在多任务上部署的宿主)
/// 都会。await 只挂起协作线程,不占线程(形态同 RimeSessionGate)。
private final class DeploymentGate: @unchecked Sendable {
  private final class State: @unchecked Sendable {
    let lock = NSLock()
    var busy = false
    var waiters: [CheckedContinuation<Void, Never>] = []

    /// 快路径立即 resume(直接获得);慢路径入队等待 release 唤醒。
    func acquire(with continuation: CheckedContinuation<Void, Never>) {
      lock.lock()
      defer { lock.unlock() }
      if !busy {
        busy = true
        continuation.resume()
        return
      }
      waiters.append(continuation)
    }

    /// 返回需唤醒的下一等待者(nil = 门空闲)。
    func release() -> CheckedContinuation<Void, Never>? {
      lock.lock()
      defer { lock.unlock() }
      if waiters.isEmpty {
        busy = false
        return nil
      }
      return waiters.removeFirst()  // busy 保持 true:所有权移交
    }
  }

  private let state = State()

  func acquire() async {
    await withCheckedContinuation { state.acquire(with: $0) }
  }

  func release() {
    if let next = state.release() {
      next.resume()
    }
  }
}

private let deploymentGate = DeploymentGate()

/// 执行一次部署。
///
/// 任何失败都抛 `RimeDeployError`;其描述就是应展示给用户的信息。
///
/// 进程内的部署是串行的,见 `deploymentGate`。
public func runRimeDeploy(_ request: RimeDeployRequest) async throws -> RimeDeployOutcome {
  await deploymentGate.acquire()
  defer { deploymentGate.release() }

  let dataDir = try requireDirectory(request.dataDirectory, "--data-dir")
  let outDir = try makeDirectory(request.outputDirectory, "--out-dir")
  let workDir = try makeDirectory(
    request.workDirectory ?? (request.outputDirectory + "-work"), "--work-dir")

  let traits = RimeTraits(
    sharedDataDir: dataDir,
    userDataDir: workDir,
    distributionName: rimeDeployToolName,
    distributionCodeName: rimeDeployToolName,
    distributionVersion: "1",
    appName: "rime.deploy",
    minLogLevel: request.verbose ? .info : .warning,
    logDir: "",
    stagingDir: outDir)
  // prebuilt_data_dir 刻意不设置:它指向随发行版分发的**只读**目录,仅在
  // staging 中找不到资源时回退查询——不是本工具的写入目标,把它指向输出目录
  // 等于把只读缓存说成正在写入的东西。不设置时取 librime 默认的
  // <data-dir>/build,在这里是惰性的。

  let root = Rime.localShared

  do {
    try await root.setup(with: traits)

    // 在部署模块加载之前挂上收集器,以免漏掉任何一条。
    let collector = RimeLogSink.installErrorCollector()
    defer { collector?.uninstall() }
    if collector == nil {
      note(
        "this librime has no logsink module, so a schema whose config fails to "
          + "link cannot be detected; only the declared artifacts are checked")
    }

    try await root.initializeDeployer(with: traits)

    // 复制 librime 在运行期而非构建期读取的数据。它们与编译产物进同一目录——
    // 客户端只会把 prebuilt_data_dir 指向那一个目录。
    for name in request.alsoCopy {
      try copyThrough(name: name, from: dataDir, to: outDir)
    }

    let succeeded: Bool
    switch request.mode {
    case .prebuild:
      succeeded = try await root.prebuild()
    case .deploy:
      succeeded = try await root.deploy()
    }

    // 在调用方任务上等待,但 librime 仍可能持有工作线程状态。
    try await root.finalize()

    guard succeeded else {
      throw RimeDeployError("\(request.mode.rawValue) failed; see the librime log above")
    }

    // link 失败会以"成功"返回,因此日志是它唯一的痕迹。先于产物检查上报,
    // 因为它解释了产物为何缺失。
    if let firstError = collector?.firstError {
      throw RimeDeployError(
        """
        librime reported an error while deploying:
          \(firstError)

        这并不总会反映在部署结果里:配置无法 link 的 schema(无法解析的 \
        __include 或 __patch)会让该 schema 与其词典都不落盘,而整轮仍报成功。 \
        请修正数据;收集到的信息指出了失败的文件。
        """)
    }
  } catch let error as RimeDeployError {
    throw error
  } catch {
    throw RimeDeployError("\(error)")
  }

  let removed = try removeStaleFiles(in: outDir, keeping: request.expected + request.alsoCopy)

  let missing = missingArtifacts(in: outDir, expected: request.expected + request.alsoCopy)
  guard missing.isEmpty else {
    throw RimeDeployError(describeMissing(missing, in: outDir))
  }

  return RimeDeployOutcome(
    removedStaleFiles: removed, verifiedArtifacts: request.expected.count)
}

// MARK: - helpers

private func note(_ message: String) {
  FileHandle.standardError.write(Data("\(rimeDeployToolName): \(message)\n".utf8))
}

private func requireDirectory(_ path: String, _ flag: String) throws -> String {
  var isDirectory: ObjCBool = false
  guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else {
    throw RimeDeployError("\(flag) does not exist: \(path)")
  }
  guard isDirectory.boolValue else {
    throw RimeDeployError("\(flag) is not a directory: \(path)")
  }
  return URL(fileURLWithPath: path).standardizedFileURL.path
}

private func makeDirectory(_ path: String, _ flag: String) throws -> String {
  do {
    try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
  } catch {
    throw RimeDeployError("cannot create \(flag) \(path): \(error.localizedDescription)")
  }
  return URL(fileURLWithPath: path).standardizedFileURL.path
}

private func copyThrough(name: String, from dataDir: String, to outDir: String) throws {
  let source = "\(dataDir)/\(name)"
  let destination = "\(outDir)/\(name)"
  guard FileManager.default.fileExists(atPath: source) else {
    throw RimeDeployError("--also-copy \(name): no such file in \(dataDir)")
  }
  do {
    let parent = (destination as NSString).deletingLastPathComponent
    if !parent.isEmpty {
      try FileManager.default.createDirectory(atPath: parent, withIntermediateDirectories: true)
    }
    if FileManager.default.fileExists(atPath: destination) {
      try FileManager.default.removeItem(atPath: destination)
    }
    try FileManager.default.copyItem(atPath: source, toPath: destination)
  } catch {
    throw RimeDeployError("cannot copy \(name) into \(outDir): \(error.localizedDescription)")
  }
}

/// `directory` 下任意深度的全部文件,以相对路径表示。
public func relativeFilePaths(in directory: String) -> [String] {
  guard let walker = FileManager.default.enumerator(atPath: directory) else { return [] }
  var relative: [String] = []
  while let entry = walker.nextObject() as? String {
    var isDirectory: ObjCBool = false
    let path = "\(directory)/\(entry)"
    guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
      !isDirectory.boolValue
    else { continue }
    relative.append(entry)
  }
  return relative
}

/// `directory` 下的全部目录,最深的在前——这样被清空的子目录先于其父目录
/// 被移除。
private func relativeDirectories(in directory: String) -> [String] {
  guard let walker = FileManager.default.enumerator(atPath: directory) else { return [] }
  var relative: [String] = []
  while let entry = walker.nextObject() as? String {
    var isDirectory: ObjCBool = false
    let path = "\(directory)/\(entry)"
    guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
      isDirectory.boolValue
    else { continue }
    relative.append(entry)
  }
  return relative.sorted { $0.split(separator: "/").count > $1.split(separator: "/").count }
}

/// 清除输出目录里本次数据未声明的一切,返回清除的文件数。
///
/// librime 既不写也不删源已消失的产物,没有这一步它们就会留在输出目录里并
/// 随包分发。调用方声明过的文件绝不触碰:基于校验和复用最新产物正是编译器的
/// 本分,什么都没变的重新构建不应该重写任何东西。
///
/// 什么都没声明的调用方完全不做清除:声明是区分"产物"与"早于本次数据集的
/// 东西"的唯一依据,空的声明会让每个文件都显得陈旧——包括刚写出来的那些。
private func removeStaleFiles(in outDir: String, keeping declared: [String]) throws -> Int {
  guard !declared.isEmpty else { return 0 }
  let expected = Set(declared)
  var removed = 0
  for relative in relativeFilePaths(in: outDir).sorted() where !expected.contains(relative) {
    do {
      try FileManager.default.removeItem(atPath: "\(outDir)/\(relative)")
      removed += 1
    } catch {
      throw RimeDeployError(
        "cannot remove the stale \(relative): \(error.localizedDescription)")
    }
  }
  for relative in relativeDirectories(in: outDir) {
    let path = "\(outDir)/\(relative)"
    if (try? FileManager.default.contentsOfDirectory(atPath: path))?.isEmpty == true {
      try? FileManager.default.removeItem(atPath: path)
    }
  }
  return removed
}

private func missingArtifacts(in outDir: String, expected: [String]) -> [String] {
  expected
    .filter { !FileManager.default.fileExists(atPath: "\(outDir)/\($0)") }
    .sorted()
}

private func describeMissing(_ missing: [String], in outDir: String) -> String {
  let listing = relativeFilePaths(in: outDir).sorted()
  return """
    compilation reported success but these artifacts are missing:
    \(missing.map { "  " + $0 }.joined(separator: "\n"))
    produced in \(outDir):
    \(listing.map { "  " + $0 }.joined(separator: "\n"))

    A declared artifact is named after the file it came from, so the build can
    know it before running the compiler. librime names its output after the
    identifiers found *inside* the data, which means every name used in the
    data has to match the file it lives in:

      * a schema's schema_id must equal its file name
        (<id>.schema.yaml holds "schema_id: <id>")
      * a schema's translator/dictionary must equal the dictionary's file
        name (<id>.dict.yaml holds "name: <id>"), and a defaulted prism
        follows the same name
      * every *.dict.yaml must be the primary dictionary of some schema. One
        reached only through another dictionary's import_tables, or used only
        as an entry in a schema's translator/packs list, compiles to a table
        alone (or to nothing), with no prism and no reverse database, so the
        names this build declared for it cannot all exist
    """
}
