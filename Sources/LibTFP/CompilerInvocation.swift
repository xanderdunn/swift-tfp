// Copyright 2019 Google LLC
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     https://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

import Foundation
import SIL

public enum CompilerInvocationError : Error {
  case fileCreationError
  case invocationError
  case parseError(Error)
}

fileprivate func makeTemporaryFile() -> URL? {
  let tmpDir: URL
  if #available(macOS 10.12, *) {
    tmpDir = FileManager.default.temporaryDirectory
  } else {
    tmpDir = URL(fileURLWithPath: "/tmp", isDirectory: true)
  }
  let dirPath = tmpDir.appendingPathComponent("test.XXXXXX.swift")
  return dirPath.withUnsafeFileSystemRepresentation { maybePath in
    guard let path = maybePath else { return nil }
    var mutablePath = Array(repeating: Int8(0), count: Int(PATH_MAX))
    mutablePath.withUnsafeMutableBytes { mutablePathBufferPtr in
      mutablePathBufferPtr.baseAddress!.copyMemory(
        from: path, byteCount: Int(strlen(path)) + 1)
    }
    guard mkstemps(&mutablePath, Int32(".swift".count)) != -1 else { return nil }
    return URL(
      fileURLWithFileSystemRepresentation: mutablePath, isDirectory: false, relativeTo: nil)
  }
}

public func withTemporaryFile(_ f: (URL) throws -> ()) throws {
  guard let tmp = makeTemporaryFile() else {
    throw CompilerInvocationError.fileCreationError
  }
  defer { try? FileManager.default.removeItem(atPath: tmp.path) }
  try f(tmp)
}

@available(macOS 10.13, *)
public func withSIL(forFile: String, _ f: (Module, URL) throws -> ()) throws {
  try withTemporaryFile { tempFile in
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = [
      "swiftc", "-emit-sil", "-Onone",
      // We disable the mandatory inlining pass to avoid inlining asserts
      "-Xllvm", "-sil-disable-pass", "-Xllvm", "Mandatory",
      // This flag enables printing the debug location
      "-Xllvm", "-sil-print-debuginfo",
      "-o", tempFile.path,
      forFile]
    do {
      try process.run()
      process.waitUntilExit()
    } catch {
      throw CompilerInvocationError.invocationError
    }
    do {
      let module = try Module.parse(fromSILPath: tempFile.path)
      try f(module, tempFile)
    } catch {
      throw CompilerInvocationError.parseError(error)
    }
  }
}

@available(macOS 10.13, *)
public func withAST(forSILPath path: URL, _ f: (SExpr) throws -> ()) throws {
  try withTemporaryFile { tempFile in
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = ["swiftc", "-dump-ast", "-o", tempFile.path, "-parse-sil", path.path]
    do {
      try process.run()
      process.waitUntilExit()
    } catch {
      throw CompilerInvocationError.invocationError
    }
    do {
      try f(try SExpr.parse(fromPath: tempFile.path))
    } catch {
      throw CompilerInvocationError.parseError(error)
    }
  }
}
