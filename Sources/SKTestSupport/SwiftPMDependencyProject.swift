//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift.org open source project
//
// Copyright (c) 2014 - 2024 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See https://swift.org/LICENSE.txt for license information
// See https://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//

import Foundation
import ISDBTibs
import XCTest

import struct TSCBasic.AbsolutePath
import class TSCBasic.Process
import enum TSCBasic.ProcessEnv
import struct TSCBasic.ProcessResult

/// A SwiftPM package that gets written to disk and for which a Git repository is initialized with a commit tagged
/// `1.0.0`. This repository can then be used as a dependency for another package, usually a `SwiftPMTestProject`.
public class SwiftPMDependencyProject {
  /// The directory in which the repository lives.
  public let packageDirectory: URL

  private func runCommand(_ toolName: String, _ arguments: [String], workingDirectory: URL) async throws {
    enum Error: Swift.Error {
      case cannotFindTool(toolName: String)
      case processedTerminatedWithNonZeroExitCode(ProcessResult)
    }
    guard let toolUrl = findTool(name: toolName) else {
      if ProcessEnv.block["SWIFTCI_USE_LOCAL_DEPS"] == nil {
        // Never skip the test in CI, similar to what SkipUnless does.
        throw XCTSkip("\(toolName) cannot be found")
      }
      throw Error.cannotFindTool(toolName: toolName)
    }
    print([toolUrl.path] + arguments)
    let process = TSCBasic.Process(
      arguments: [toolUrl.path] + arguments,
      workingDirectory: try AbsolutePath(validating: workingDirectory.path)
    )
    try process.launch()
    let processResult = try await process.waitUntilExit()
    guard processResult.exitStatus == .terminated(code: 0) else {
      throw Error.processedTerminatedWithNonZeroExitCode(processResult)
    }
  }

  public static let defaultPackageManifest: String = """
    // swift-tools-version: 5.7

    import PackageDescription

    let package = Package(
      name: "MyDependency",
      products: [.library(name: "MyDependency", targets: ["MyDependency"])],
      targets: [.target(name: "MyDependency")]
    )
    """

  public init(
    files: [RelativeFileLocation: String],
    manifest: String = defaultPackageManifest,
    testName: String = #function
  ) async throws {
    packageDirectory = try testScratchDir(testName: testName).appendingPathComponent("MyDependency")

    var files = files
    files["Package.swift"] = manifest

    for (fileLocation, contents) in files {
      let fileURL = fileLocation.url(relativeTo: packageDirectory)
      try FileManager.default.createDirectory(
        at: fileURL.deletingLastPathComponent(),
        withIntermediateDirectories: true
      )
      try contents.write(to: fileURL, atomically: true, encoding: .utf8)
    }

    try await runCommand("git", ["init"], workingDirectory: packageDirectory)
    try await runCommand(
      "git",
      ["add"] + files.keys.map { $0.url(relativeTo: packageDirectory).path },
      workingDirectory: packageDirectory
    )
    try await runCommand(
      "git",
      ["-c", "user.name=Dummy", "-c", "user.email=noreply@swift.org", "commit", "-m", "Initial commit"],
      workingDirectory: packageDirectory
    )
    try await runCommand("git", ["tag", "1.0.0"], workingDirectory: packageDirectory)
  }

  deinit {
    if cleanScratchDirectories {
      try? FileManager.default.removeItem(at: packageDirectory)
    }
  }

  /// Function that makes sure the project stays alive until this is called. Otherwise, the `SwiftPMDependencyProject`
  /// might get deinitialized, which deletes the package on disk.
  public func keepAlive() {
    withExtendedLifetime(self) { _ in }
  }
}
