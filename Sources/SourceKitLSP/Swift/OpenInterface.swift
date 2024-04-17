//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift.org open source project
//
// Copyright (c) 2014 - 2022 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See https://swift.org/LICENSE.txt for license information
// See https://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//

import Foundation
import LSPLogging
import LanguageServerProtocol
import SKSupport
import SourceKitD

struct InterfaceInfo {
  var contents: String
}

extension SwiftLanguageService {
  public func openInterface(_ request: OpenInterfaceRequest) async throws -> InterfaceDetails? {
    let uri = request.textDocument.uri
    let moduleName = request.moduleName
    let name = request.name
    let symbol = request.symbolUSR
    let interfaceFilePath = self.generatedInterfacesPath.appendingPathComponent("\(name).swiftinterface")
    let interfaceDocURI = DocumentURI(interfaceFilePath)
    // has interface already been generated
    if let snapshot = try? self.documentManager.latestSnapshot(interfaceDocURI) {
      return await self.interfaceDetails(request: request, uri: interfaceDocURI, snapshot: snapshot, symbol: symbol)
    } else {
      // generate interface
      let interfaceInfo = try await self.openInterface(
        request: request,
        uri: uri,
        name: moduleName,
        interfaceURI: interfaceDocURI
      )
      do {
        // write to file
        try interfaceInfo.contents.write(to: interfaceFilePath, atomically: true, encoding: String.Encoding.utf8)
        // store snapshot
        let snapshot = try self.documentManager.open(
          interfaceDocURI,
          language: .swift,
          version: 0,
          text: interfaceInfo.contents
        )
        return await self.interfaceDetails(request: request, uri: interfaceDocURI, snapshot: snapshot, symbol: symbol)
      } catch {
        throw ResponseError.unknown(error.localizedDescription)
      }
    }
  }

  /// Open the Swift interface for a module.
  ///
  /// - Parameters:
  ///   - request: The OpenInterfaceRequest.
  ///   - uri: The document whose compiler arguments should be used to generate the interface.
  ///   - name: The name of the module whose interface should be generated.
  ///   - interfaceURI: The file where the generated interface should be written.
  private func openInterface(
    request: OpenInterfaceRequest,
    uri: DocumentURI,
    name: String,
    interfaceURI: DocumentURI
  ) async throws -> InterfaceInfo {
    let keys = self.keys
    let skreq = sourcekitd.dictionary([
      keys.request: requests.editorOpenInterface,
      keys.moduleName: name,
      keys.groupName: request.groupNames.isEmpty ? nil : request.groupNames as [SKDRequestValue],
      keys.name: interfaceURI.pseudoPath,
      keys.synthesizedExtension: 1,
      keys.compilerArgs: await self.buildSettings(for: uri)?.compilerArgs as [SKDRequestValue]?,
    ])

    let dict = try await self.sourcekitd.send(skreq, fileContents: nil)
    return InterfaceInfo(contents: dict[keys.sourceText] ?? "")
  }

  private func interfaceDetails(
    request: OpenInterfaceRequest,
    uri: DocumentURI,
    snapshot: DocumentSnapshot,
    symbol: String?
  ) async -> InterfaceDetails {
    do {
      guard let symbol = symbol else {
        return InterfaceDetails(uri: uri, position: nil)
      }
      let keys = self.keys
      let skreq = sourcekitd.dictionary([
        keys.request: requests.editorFindUSR,
        keys.sourceFile: uri.pseudoPath,
        keys.usr: symbol,
      ])

      let dict = try await self.sourcekitd.send(skreq, fileContents: snapshot.text)
      if let offset: Int = dict[keys.offset] {
        return InterfaceDetails(uri: uri, position: snapshot.positionOf(utf8Offset: offset))
      } else {
        return InterfaceDetails(uri: uri, position: nil)
      }
    } catch {
      return InterfaceDetails(uri: uri, position: nil)
    }
  }
}
