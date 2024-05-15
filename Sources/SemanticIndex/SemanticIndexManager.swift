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
import LSPLogging
import LanguageServerProtocol
import SKCore

/// Describes the state of indexing for a single source file
private enum FileIndexStatus {
  /// The index is up-to-date.
  case upToDate
  /// The file is not up to date and we have scheduled a task to index it but that index operation hasn't been started
  /// yet.
  case scheduled(Task<Void, Never>)
  /// We are currently actively indexing this file, ie. we are running a subprocess that indexes the file.
  case executing(Task<Void, Never>)

  var description: String {
    switch self {
    case .upToDate:
      return "upToDate"
    case .scheduled:
      return "scheduled"
    case .executing:
      return "executing"
    }
  }
}

/// Schedules index tasks and keeps track of the index status of files.
public final actor SemanticIndexManager {
  /// The underlying index. This is used to check if the index of a file is already up-to-date, in which case it doesn't
  /// need to be indexed again.
  private let index: CheckedIndex

  /// The build system manager that is used to get compiler arguments for a file.
  private let buildSystemManager: BuildSystemManager

  /// The index status of the source files that the `SemanticIndexManager` knows about.
  ///
  /// Files that have never been indexed are not in this dictionary.
  private var indexStatus: [DocumentURI: FileIndexStatus] = [:]

  /// The task to generate the build graph (resolving package dependencies, generating the build description,
  /// ...). `nil` if no build graph is currently being generated.
  private var generateBuildGraphTask: Task<Void, Never>?

  /// The `TaskScheduler` that manages the scheduling of index tasks. This is shared among all `SemanticIndexManager`s
  /// in the process, to ensure that we don't schedule more index operations than processor cores from multiple
  /// workspaces.
  private let indexTaskScheduler: TaskScheduler<AnyIndexTaskDescription>

  /// Called when files are scheduled to be indexed.
  ///
  /// The parameter is the number of files that were scheduled to be indexed.
  private let indexTasksWereScheduled: @Sendable (_ numberOfFileScheduled: Int) -> Void

  /// Callback that is called when an index task has finished.
  ///
  /// An object observing this property probably wants to check `inProgressIndexTasks` when the callback is called to
  /// get the current list of in-progress index tasks.
  ///
  /// The number of `indexTaskDidFinish` calls does not have to relate to the number of `indexTasksWereScheduled` calls.
  private let indexTaskDidFinish: @Sendable () -> Void

  // MARK: - Public API

  /// The files that still need to be indexed.
  ///
  /// See `FileIndexStatus` for the distinction between `scheduled` and `executing`.
  public var inProgressIndexTasks: (scheduled: [DocumentURI], executing: [DocumentURI]) {
    let scheduled = indexStatus.compactMap { (uri: DocumentURI, status: FileIndexStatus) in
      if case .scheduled = status {
        return uri
      }
      return nil
    }
    let inProgress = indexStatus.compactMap { (uri: DocumentURI, status: FileIndexStatus) in
      if case .executing = status {
        return uri
      }
      return nil
    }
    return (scheduled, inProgress)
  }

  public init(
    index: UncheckedIndex,
    buildSystemManager: BuildSystemManager,
    indexTaskScheduler: TaskScheduler<AnyIndexTaskDescription>,
    indexTasksWereScheduled: @escaping @Sendable (Int) -> Void,
    indexTaskDidFinish: @escaping @Sendable () -> Void
  ) {
    self.index = index.checked(for: .modifiedFiles)
    self.buildSystemManager = buildSystemManager
    self.indexTaskScheduler = indexTaskScheduler
    self.indexTasksWereScheduled = indexTasksWereScheduled
    self.indexTaskDidFinish = indexTaskDidFinish
  }

  /// Schedules a task to index all files in `files` that don't already have an up-to-date index.
  /// Returns immediately after scheduling that task.
  ///
  /// Indexing is being performed with a low priority.
  public func scheduleBackgroundIndex(files: some Collection<DocumentURI>) async {
    await self.index(files: files, priority: .low)
  }

  /// Regenerate the build graph (also resolving package dependencies) and then index all the source files known to the
  /// build system.
  public func scheduleBuildGraphGenerationAndBackgroundIndexAllFiles() async {
    generateBuildGraphTask = Task(priority: .low) {
      await orLog("Generating build graph") { try await self.buildSystemManager.generateBuildGraph() }
      await scheduleBackgroundIndex(files: await self.buildSystemManager.sourceFiles().map(\.uri))
      generateBuildGraphTask = nil
    }
  }

  /// Wait for all in-progress index tasks to finish.
  public func waitForUpToDateIndex() async {
    logger.info("Waiting for up-to-date index")
    // Wait for a build graph update first, if one is in progress. This will add all index tasks to `indexStatus`, so we
    // can await the index tasks below.
    await generateBuildGraphTask?.value

    await withTaskGroup(of: Void.self) { taskGroup in
      for (_, status) in indexStatus {
        switch status {
        case .scheduled(let task), .executing(let task):
          taskGroup.addTask {
            await task.value
          }
        case .upToDate:
          break
        }
      }
      await taskGroup.waitForAll()
    }
    index.pollForUnitChangesAndWait()
    logger.debug("Done waiting for up-to-date index")
  }

  /// Ensure that the index for the given files is up-to-date.
  ///
  /// This tries to produce an up-to-date index for the given files as quickly as possible. To achieve this, it might
  /// suspend previous target-wide index tasks in favor of index tasks that index a fewer files.
  public func waitForUpToDateIndex(for uris: some Collection<DocumentURI>) async {
    logger.info(
      "Waiting for up-to-date index for \(uris.map { $0.fileURL?.lastPathComponent ?? $0.stringValue }.joined(separator: ", "))"
    )
    // If there's a build graph update in progress wait for that to finish so we can discover new files in the build
    // system.
    await generateBuildGraphTask?.value

    // Create a new index task for the files that aren't up-to-date. The newly scheduled index tasks will
    // - Wait for the existing index operations to finish if they have the same number of files.
    // - Reschedule the background index task in favor of an index task with fewer source files.
    await self.index(files: uris, priority: nil).value
    index.pollForUnitChangesAndWait()
    logger.debug("Done waiting for up-to-date index")
  }

  // MARK: - Helper functions

  /// Prepare the given targets for indexing
  private func prepare(targets: [ConfiguredTarget], priority: TaskPriority?) async {
    let taskDescription = AnyIndexTaskDescription(
      PreparationTaskDescription(
        targetsToPrepare: targets,
        buildSystemManager: self.buildSystemManager
      )
    )
    await self.indexTaskScheduler.schedule(priority: priority, taskDescription).value
    self.indexTaskDidFinish()
  }

  /// Update the index store for the given files, assuming that their targets have already been prepared.
  private func updateIndexStore(for files: [DocumentURI], priority: TaskPriority?) async {
    let taskDescription = AnyIndexTaskDescription(
      UpdateIndexStoreTaskDescription(
        filesToIndex: Set(files),
        buildSystemManager: self.buildSystemManager,
        index: self.index.unchecked
      )
    )
    let updateIndexStoreTask = await self.indexTaskScheduler.schedule(priority: priority, taskDescription) { newState in
      switch newState {
      case .executing:
        for file in files {
          if case .scheduled(let task) = self.indexStatus[file] {
            self.indexStatus[file] = .executing(task)
          } else {
            logger.fault(
              """
              Index status of \(file) is in an unexpected state \
              '\(self.indexStatus[file]?.description ?? "<nil>", privacy: .public)' when update index store task \
              started executing
              """
            )
          }
        }
      case .cancelledToBeRescheduled:
        for file in files {
          if case .executing(let task) = self.indexStatus[file] {
            self.indexStatus[file] = .scheduled(task)
          } else {
            logger.fault(
              """
              Index status of \(file) is in an unexpected state \
              '\(self.indexStatus[file]?.description ?? "<nil>", privacy: .public)' when update index store task \
              is cancelled to be rescheduled.
              """
            )
          }
        }
      case .finished:
        for file in files {
          self.indexStatus[file] = .upToDate
        }
        self.indexTaskDidFinish()
      }
    }
    await updateIndexStoreTask.value
  }

  /// Index the given set of files at the given priority.
  ///
  /// The returned task finishes when all files are indexed.
  @discardableResult
  private func index(files: some Collection<DocumentURI>, priority: TaskPriority?) async -> Task<Void, Never> {
    let outOfDateFiles = files.filter {
      if case .upToDate = indexStatus[$0] {
        return false
      }
      return true
    }
    .sorted(by: { $0.stringValue < $1.stringValue })  // sort files to get deterministic indexing order

    // Sort the targets in topological order so that low-level targets get built before high-level targets, allowing us
    // to index the low-level targets ASAP.
    var filesByTarget: [ConfiguredTarget: [DocumentURI]] = [:]
    for file in outOfDateFiles {
      guard let target = await buildSystemManager.canonicalConfiguredTarget(for: file) else {
        logger.error("Not indexing \(file.forLogging) because the target could not be determined")
        continue
      }
      filesByTarget[target, default: []].append(file)
    }

    var sortedTargets: [ConfiguredTarget] =
      await orLog("Sorting targets") { try await buildSystemManager.topologicalSort(of: Array(filesByTarget.keys)) }
      ?? Array(filesByTarget.keys).sorted(by: {
        ($0.targetID, $0.runDestinationID) < ($1.targetID, $1.runDestinationID)
      })

    if Set(sortedTargets) != Set(filesByTarget.keys) {
      logger.fault(
        """
        Sorting targets topologically changed set of targets:
        \(sortedTargets.map(\.targetID).joined(separator: ", ")) != \(filesByTarget.keys.map(\.targetID).joined(separator: ", "))
        """
      )
      sortedTargets = Array(filesByTarget.keys).sorted(by: {
        ($0.targetID, $0.runDestinationID) < ($1.targetID, $1.runDestinationID)
      })
    }

    var indexTasks: [Task<Void, Never>] = []

    // TODO (indexing): When we can index multiple targets concurrently in SwiftPM, increase the batch size to half the
    // processor count, so we can get parallelism during preparation.
    // https://github.com/apple/sourcekit-lsp/issues/1262
    for targetsBatch in sortedTargets.partition(intoBatchesOfSize: 1) {
      let indexTask = Task(priority: priority) {
        // First prepare the targets.
        await prepare(targets: targetsBatch, priority: priority)

        // And after preparation is done, index the files in the targets.
        await withTaskGroup(of: Void.self) { taskGroup in
          for target in targetsBatch {
            // TODO (indexing): Once swiftc supports indexing of multiple files in a single invocation, increase the
            // batch size to allow it to share AST builds between multiple files within a target.
            // https://github.com/apple/sourcekit-lsp/issues/1268
            for fileBatch in filesByTarget[target]!.partition(intoBatchesOfSize: 1) {
              taskGroup.addTask {
                await self.updateIndexStore(for: fileBatch, priority: priority)
              }
            }
          }
          await taskGroup.waitForAll()
        }
      }
      indexTasks.append(indexTask)

      let filesToIndex = targetsBatch.flatMap({ filesByTarget[$0]! })
      for file in filesToIndex {
        // indexStatus will get set to `.upToDate` by `updateIndexStore`. Setting it to `.upToDate` cannot race with
        // setting it to `.scheduled` because we don't have an `await` call between the creation of `indexTask` and
        // this loop, so we still have exclusive access to the `SemanticIndexManager` actor and hence `updateIndexStore`
        // can't execute until we have set all index statuses to `.scheduled`.
        indexStatus[file] = .scheduled(indexTask)
      }
      indexTasksWereScheduled(filesToIndex.count)
    }
    let indexTasksImmutable = indexTasks

    return Task(priority: priority) {
      await withTaskGroup(of: Void.self) { taskGroup in
        for indexTask in indexTasksImmutable {
          taskGroup.addTask {
            await indexTask.value
          }
        }
        await taskGroup.waitForAll()
      }
    }
  }
}
