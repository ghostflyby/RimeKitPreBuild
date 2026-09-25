// SPDX-FileCopyrightText: 2025-2026 ghostflyby
// SPDX-License-Identifier: MPL-2.0
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import RimeDeployCore

/// `RimeDeployCore` 的命令行前端:解析 argv、执行、报告。全部逻辑都在库里,
/// 以便测试直接调用——构建命令非零退出会中断构建,仅作为可执行文件存在的工具
/// 只能覆盖成功路径。
///
/// 用 `@main` 而不是顶层代码:Swift 6 语言模式下 `main.swift` 的顶层变量属于
/// `MainActor`,任何嵌套函数都不得碰它们。
@main
enum RimeDeployCommand {
  static let usage = """
    usage: \(rimeDeployToolName) --data-dir <dir> --out-dir <dir> [options]

    Compiles the Rime data in --data-dir into --out-dir.

    options:
      --data-dir <dir>    Source data: *.schema.yaml, *.dict.yaml and their inputs.
                          Passed to librime as shared_data_dir; never written to.
      --out-dir <dir>     Output directory for compiled artifacts. Passed to librime
                          as staging_dir, so artifacts already there that are still
                          current are reused rather than rebuilt.
      --work-dir <dir>    Writable scratch directory (user_data_dir). Defaults to
                          <out-dir>-work.
      --mode <mode>       prebuild (default) compiles every *.schema.yaml found in
                          --data-dir and produces no workspace config.
                          deploy additionally compiles default.yaml, which requires
                          a schema_list in it.
      --expect <name>     Assert that <name>, relative to --out-dir, exists
                          afterwards. Repeat for every artifact the caller declared;
                          the set also tells the tool which files in --out-dir belong
                          to this data, so anything else left there is removed.
      --also-copy <name>  Copy <name> from --data-dir into --out-dir unchanged,
                          creating parent directories. For data librime reads at run
                          time rather than compiling, such as default.yaml or an
                          opencc/ directory. Repeat as needed.
      --verbose           Log at INFO instead of WARNING.
      -h, --help          Show this message.

    Exit status is 0 only when the mode succeeded and every --expect name is present.
    """

  static func main() async {
    var dataDirectory: String?
    var outputDirectory: String?
    var workDirectory: String?
    var mode = RimeDeployMode.prebuild
    var verbose = false
    var expected: [String] = []
    var alsoCopy: [String] = []

    let arguments = Array(CommandLine.arguments.dropFirst())
    var index = 0
    func nextValue(_ flag: String) -> String {
      index += 1
      guard index < arguments.count else { fail("\(flag) requires a value") }
      return arguments[index]
    }

    while index < arguments.count {
      let argument = arguments[index]
      switch argument {
      case "--data-dir": dataDirectory = nextValue(argument)
      case "--out-dir": outputDirectory = nextValue(argument)
      case "--work-dir": workDirectory = nextValue(argument)
      case "--mode":
        let value = nextValue(argument)
        guard let parsed = RimeDeployMode(rawValue: value) else {
          fail("--mode must be 'prebuild' or 'deploy', not '\(value)'")
        }
        mode = parsed
      case "--expect": expected.append(nextValue(argument))
      case "--also-copy": alsoCopy.append(nextValue(argument))
      case "--verbose": verbose = true
      case "-h", "--help":
        print(usage)
        exit(0)
      default:
        fail("unrecognized argument '\(argument)'\n\n\(usage)")
      }
      index += 1
    }

    guard let dataDirectory else {
      fail("--data-dir is required\n\n\(usage)")
    }
    guard let outputDirectory else {
      fail("--out-dir is required\n\n\(usage)")
    }

    let request = RimeDeployRequest(
      dataDirectory: dataDirectory,
      outputDirectory: outputDirectory,
      workDirectory: workDirectory,
      mode: mode,
      expected: expected,
      alsoCopy: alsoCopy,
      verbose: verbose
    )

    do {
      let outcome = try await runRimeDeploy(request)
      if expected.isEmpty {
        // 没有 --expect 就没有校验过产物;明确说出来,而不是报告一个可能被读成
        // "产物都在"的成功。
        let listing = relativeFilePaths(in: request.outputDirectory).sorted()
        let body = listing.map { "  " + $0 }.joined(separator: "\n")
        note(
          """
          compilation succeeded, but no --expect names were given, so nothing was \
          checked; \(request.outputDirectory) holds \(listing.count) file(s):
          \(body)
          """)
      } else {
        let swept =
          outcome.removedStaleFiles > 0
          ? ", removed \(outcome.removedStaleFiles) stale file(s)" : ""
        note(
          "deployed \(outcome.verifiedArtifacts) artifact(s) into "
            + "\(request.outputDirectory)\(swept)")
      }
    } catch let error as RimeDeployError {
      fail(error.description)
    } catch {
      fail("\(error)")
    }
  }

  static func note(_ message: String) {
    FileHandle.standardError.write(Data("\(rimeDeployToolName): \(message)\n".utf8))
  }

  static func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("\(rimeDeployToolName): error: \(message)\n".utf8))
    exit(1)
  }
}
