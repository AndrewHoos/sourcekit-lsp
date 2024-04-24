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

/// Debounces calls to a function/closure. If multiple calls to the closure are made, it allows aggregating the
/// parameters.
public actor Debouncer<Parameter> {
  /// How long to wait for further `scheduleCall` calls before committing to actually calling `makeCall`.
  private let debounceDuration: Duration

  /// When `scheduleCall` is called while another `scheduleCall` was waiting to commit its call, combines the parameters
  /// of those two calls.
  ///
  /// ### Example
  ///
  /// Two `scheduleCall` calls that are made within a time period shorter than `debounceDuration` like the following
  /// ```swift
  /// debouncer.scheduleCall(5)
  /// debouncer.scheduleCall(10)
  /// ```
  /// will call `combineParameters(5, 10)`
  private let combineParameters: (Parameter, Parameter) -> Parameter

  /// After the debounce duration has elapsed, commit the call.
  private let makeCall: (Parameter) async -> Void

  /// In the time between the call to `scheduleCall` and the call actually being committed (ie. in the time that the
  /// call can be debounced), the task that would commit the call (unless cancelled) and the parameter with which this
  /// call should be made.
  private var inProgressData: (Parameter, Task<Void, Never>)?

  public init(
    debounceDuration: Duration,
    combineResults: @escaping (Parameter, Parameter) -> Parameter,
    _ makeCall: @escaping (Parameter) async -> Void
  ) {
    self.debounceDuration = debounceDuration
    self.combineParameters = combineResults
    self.makeCall = makeCall
  }

  /// Schedule a debounced call. If `scheduleCall` is called within `debounceDuration`, the parameters of the two
  /// `scheduleCall` calls will be combined using `combineParameters` and the new debounced call will be scheduled
  /// `debounceDuration` after the second `scheduleCall` call.
  public func scheduleCall(_ parameter: Parameter) {
    var parameter = parameter
    if let (inProgressParameter, inProgressTask) = inProgressData {
      inProgressTask.cancel()
      parameter = combineParameters(inProgressParameter, parameter)
    }
    let task = Task {
      do {
        try await Task.sleep(for: debounceDuration)
        try Task.checkCancellation()
      } catch {
        return
      }
      inProgressData = nil
      await makeCall(parameter)
    }
    inProgressData = (parameter, task)
  }
}

extension Debouncer<Void> {
  public init(debounceDuration: Duration, _ makeCall: @escaping () async -> Void) {
    self.init(debounceDuration: debounceDuration, combineResults: { _, _ in }, makeCall)
  }

  public func scheduleCall() {
    self.scheduleCall(())
  }
}
