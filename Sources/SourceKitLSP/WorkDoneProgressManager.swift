//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift.org open source project
//
// Copyright (c) 2014 - 2020 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See https://swift.org/LICENSE.txt for license information
// See https://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//

import Foundation
import LanguageServerProtocol
import SKSupport

/// Represents a single `WorkDoneProgress` task that gets communicated with the client.
///
/// The work done progress is started when the object is created and ended when the object is destroyed.
/// In between, updates can be sent to the client.
final class WorkDoneProgressManager {
  private let token: ProgressToken
  private let queue = AsyncQueue<Serial>()
  private let server: SourceKitLSPServer

  convenience init?(server: SourceKitLSPServer, title: String, message: String? = nil, percentage: Int? = nil) async {
    guard let capabilityRegistry = await server.capabilityRegistry else {
      return nil
    }
    self.init(server: server, capabilityRegistry: capabilityRegistry, title: title, message: message)
  }

  init?(
    server: SourceKitLSPServer,
    capabilityRegistry: CapabilityRegistry,
    title: String,
    message: String? = nil,
    percentage: Int? = nil
  ) {
    guard capabilityRegistry.clientCapabilities.window?.workDoneProgress ?? false else {
      return nil
    }
    self.token = .string("WorkDoneProgress-\(UUID())")
    self.server = server
    queue.async { [server, token] in
      await server.waitUntilInitialized()
      await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
        _ = server.client.send(CreateWorkDoneProgressRequest(token: token)) { result in
          continuation.resume()
        }
      }
      await server.sendNotificationToClient(
        WorkDoneProgress(
          token: token,
          value: .begin(WorkDoneProgressBegin(title: title, message: message, percentage: percentage))
        )
      )
    }
  }

  func update(message: String? = nil, percentage: Int? = nil) {
    queue.async { [server, token] in
      await server.sendNotificationToClient(
        WorkDoneProgress(
          token: token,
          value: .report(WorkDoneProgressReport(cancellable: false, message: message, percentage: percentage))
        )
      )
    }
  }

  deinit {
    queue.async { [server, token] in
      await server.sendNotificationToClient(WorkDoneProgress(token: token, value: .end(WorkDoneProgressEnd())))
    }
  }
}
