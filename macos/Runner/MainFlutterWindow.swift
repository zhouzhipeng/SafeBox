import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    RegisterGeneratedPlugins(registry: flutterViewController)
    MacAuthorizedDirectoryPlugin.register(
      with: flutterViewController.registrar(forPlugin: "SafeBoxAuthorizedDirectoryPlugin")
    )

    super.awakeFromNib()
  }
}

private final class MacAuthorizedDirectoryPlugin: NSObject {
  private static let channelName = "com.zhouzhipeng.safebox/authorized_directory"
  private static var retainedInstance: MacAuthorizedDirectoryPlugin?
  private let worker = DispatchQueue(label: "com.zhouzhipeng.safebox.authorized-directory")

  static func register(with registrar: FlutterPluginRegistrar) {
    let instance = MacAuthorizedDirectoryPlugin()
    retainedInstance = instance
    FlutterMethodChannel(name: channelName, binaryMessenger: registrar.messenger)
      .setMethodCallHandler(instance.handle)
  }

  private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "chooseDirectory": chooseDirectory(result: result)
    case "mirrorCiphertext": mirrorCiphertext(arguments: call.arguments, result: result)
    case "releaseDirectory": result(nil)
    case "protectTemporaryPlaintext":
      protectTemporaryPlaintext(arguments: call.arguments, result: result)
    case "exportFile": result(false)
    default: result(FlutterMethodNotImplemented)
    }
  }

  private func protectTemporaryPlaintext(arguments: Any?, result: @escaping FlutterResult) {
    guard
      let arguments = arguments as? [String: Any],
      let path = arguments["path"] as? String
    else {
      result(FlutterError(code: "arguments", message: "Missing temporary plaintext path", details: nil))
      return
    }
    do {
      let root = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
      let temporary = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true).standardizedFileURL
      guard Self.isDescendant(root, of: temporary) else {
        throw MacDirectoryError.destinationEscaped
      }
      try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
      var values = URLResourceValues()
      values.isExcludedFromBackup = true
      var mutableRoot = root
      try mutableRoot.setResourceValues(values)
      try FileManager.default.setAttributes(
        [.posixPermissions: 0o700],
        ofItemAtPath: root.path
      )
      result(nil)
    } catch {
      result(FlutterError(code: "protection", message: "Unable to protect temporary plaintext", details: nil))
    }
  }

  private func chooseDirectory(result: @escaping FlutterResult) {
    let panel = NSOpenPanel()
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.allowsMultipleSelection = false
    panel.canCreateDirectories = false
    panel.prompt = "选择此 SBOX 目录"
    let completion: (NSApplication.ModalResponse) -> Void = { response in
      guard response == .OK, let url = panel.url else {
        result(nil)
        return
      }
      guard url.startAccessingSecurityScopedResource() else {
        result(FlutterError(code: "permission", message: "Directory access was denied", details: nil))
        return
      }
      defer { url.stopAccessingSecurityScopedResource() }
      do {
        let bookmark = try url.bookmarkData(
          options: [.withSecurityScope],
          includingResourceValuesForKeys: nil,
          relativeTo: nil
        )
        result([
          "reference": bookmark.base64EncodedString(),
          "platform": "macos",
          "display_name": url.lastPathComponent.isEmpty ? "macOS 系统目录" : url.lastPathComponent,
        ])
      } catch {
        result(FlutterError(code: "bookmark", message: "Unable to save directory authorization", details: nil))
      }
    }
    if let window = NSApp.keyWindow ?? NSApp.mainWindow {
      panel.beginSheetModal(for: window, completionHandler: completion)
    } else {
      completion(panel.runModal())
    }
  }

  private func mirrorCiphertext(arguments: Any?, result: @escaping FlutterResult) {
    guard
      let arguments = arguments as? [String: Any],
      let reference = arguments["reference"] as? String,
      let destinationPath = arguments["destination_root"] as? String,
      let maximumDepth = (arguments["maximum_depth"] as? NSNumber)?.intValue,
      let maximumFiles = (arguments["maximum_files"] as? NSNumber)?.intValue,
      let maximumFileBytes = (arguments["maximum_file_bytes"] as? NSNumber)?.int64Value
    else {
      result(FlutterError(code: "arguments", message: "Missing mirror arguments", details: nil))
      return
    }
    worker.async {
      do {
        let output = try self.mirror(
          reference: reference,
          destinationPath: destinationPath,
          maximumDepth: maximumDepth,
          maximumFiles: maximumFiles,
          maximumFileBytes: maximumFileBytes
        )
        DispatchQueue.main.async { result(output) }
      } catch {
        DispatchQueue.main.async {
          result(FlutterError(code: "mirror", message: error.localizedDescription, details: nil))
        }
      }
    }
  }

  private func mirror(
    reference: String,
    destinationPath: String,
    maximumDepth: Int,
    maximumFiles: Int,
    maximumFileBytes: Int64
  ) throws -> [String: Any] {
    guard
      (1...64).contains(maximumDepth),
      (1...200_000).contains(maximumFiles),
      maximumFileBytes > 0,
      let bookmark = Data(base64Encoded: reference)
    else { throw MacDirectoryError.invalidArguments }
    var stale = false
    let source = try URL(
      resolvingBookmarkData: bookmark,
      options: [.withSecurityScope, .withoutUI],
      relativeTo: nil,
      bookmarkDataIsStale: &stale
    )
    guard !stale else { throw MacDirectoryError.staleBookmark }
    guard source.startAccessingSecurityScopedResource() else {
      throw MacDirectoryError.revokedPermission
    }
    defer { source.stopAccessingSecurityScopedResource() }

    let manager = FileManager.default
    let destination = URL(fileURLWithPath: destinationPath, isDirectory: true).standardizedFileURL
    let support = try manager.url(
      for: .applicationSupportDirectory,
      in: .userDomainMask,
      appropriateFor: nil,
      create: true
    ).standardizedFileURL
    guard Self.isDescendant(destination, of: support) else {
      throw MacDirectoryError.destinationEscaped
    }
    try manager.createDirectory(at: destination, withIntermediateDirectories: true)
    var coordinatorError: NSError?
    var operationError: Error?
    var output: [String: Any]?
    NSFileCoordinator().coordinate(readingItemAt: source, options: [], error: &coordinatorError) {
      coordinatedSource in
      do {
        output = try self.copyTree(
          source: coordinatedSource,
          destination: destination,
          maximumDepth: maximumDepth,
          maximumFiles: maximumFiles,
          maximumFileBytes: maximumFileBytes
        )
      } catch { operationError = error }
    }
    if let coordinatorError { throw coordinatorError }
    if let operationError { throw operationError }
    guard let output else { throw MacDirectoryError.enumerationFailed }
    return output
  }

  private func copyTree(
    source: URL,
    destination: URL,
    maximumDepth: Int,
    maximumFiles: Int,
    maximumFileBytes: Int64
  ) throws -> [String: Any] {
    let manager = FileManager.default
    let keys: [URLResourceKey] = [
      .isDirectoryKey,
      .isRegularFileKey,
      .isSymbolicLinkKey,
      .isAliasFileKey,
      .fileSizeKey,
    ]
    var enumerationError: Error?
    guard let enumerator = manager.enumerator(
      at: source,
      includingPropertiesForKeys: keys,
      options: [],
      errorHandler: { _, error in
        enumerationError = error
        return false
      }
    ) else { throw MacDirectoryError.enumerationFailed }
    let sourcePath = source.standardizedFileURL.path
    var fileCount = 0
    var totalBytes: Int64 = 0
    var catalogPresent = false
    while let item = enumerator.nextObject() as? URL {
      if enumerator.level > maximumDepth {
        enumerator.skipDescendants()
        throw MacDirectoryError.tooDeep
      }
      let values = try item.resourceValues(forKeys: Set(keys))
      if values.isSymbolicLink == true || values.isAliasFile == true {
        enumerator.skipDescendants()
        continue
      }
      let path = item.standardizedFileURL.path
      guard path.hasPrefix(sourcePath + "/") else { throw MacDirectoryError.sourceEscaped }
      let relative = String(path.dropFirst(sourcePath.count + 1))
      let segments = relative.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
      try segments.forEach(Self.validateSegment)
      if values.isDirectory == true {
        if item.lastPathComponent == ".sbox-staging" || item.lastPathComponent == ".sbox-sync" {
          enumerator.skipDescendants()
        }
        continue
      }
      guard values.isRegularFile == true, item.pathExtension.lowercased() == "sbox" else { continue }
      fileCount += 1
      guard fileCount <= maximumFiles else { throw MacDirectoryError.tooManyFiles }
      if let size = values.fileSize {
        guard size > 0 && Int64(size) <= maximumFileBytes else {
          throw MacDirectoryError.fileTooLarge
        }
      }
      let isCatalog = segments.count == 1 && segments[0] == "catalog.sbox"
      let copied = try copyOne(
        source: item,
        destinationRoot: destination,
        segments: segments,
        maximumFileBytes: maximumFileBytes,
        replaceCatalog: isCatalog
      )
      let (next, overflow) = totalBytes.addingReportingOverflow(copied)
      guard !overflow else { throw MacDirectoryError.fileTooLarge }
      totalBytes = next
      if isCatalog { catalogPresent = true }
    }
    if let enumerationError { throw enumerationError }
    return ["file_count": fileCount, "total_bytes": totalBytes, "catalog_present": catalogPresent]
  }

  private func copyOne(
    source: URL,
    destinationRoot: URL,
    segments: [String],
    maximumFileBytes: Int64,
    replaceCatalog: Bool
  ) throws -> Int64 {
    let manager = FileManager.default
    let target = segments.reduce(destinationRoot) { $0.appendingPathComponent($1) }.standardizedFileURL
    guard Self.isDescendant(target, of: destinationRoot) else {
      throw MacDirectoryError.destinationEscaped
    }
    try manager.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
    let temporary = target.deletingLastPathComponent().appendingPathComponent(
      ".\(target.lastPathComponent).\(UUID().uuidString).part"
    )
    defer { try? manager.removeItem(at: temporary) }
    guard let input = InputStream(url: source), let output = OutputStream(url: temporary, append: false) else {
      throw MacDirectoryError.openFailed
    }
    input.open()
    output.open()
    defer { input.close(); output.close() }
    var copied: Int64 = 0
    var buffer = [UInt8](repeating: 0, count: 1024 * 1024)
    while true {
      let read = input.read(&buffer, maxLength: buffer.count)
      if read < 0 { throw input.streamError ?? MacDirectoryError.readFailed }
      if read == 0 { break }
      let (next, overflow) = copied.addingReportingOverflow(Int64(read))
      guard !overflow && next <= maximumFileBytes else { throw MacDirectoryError.fileTooLarge }
      copied = next
      var offset = 0
      while offset < read {
        let written = buffer.withUnsafeBufferPointer {
          output.write($0.baseAddress! + offset, maxLength: read - offset)
        }
        if written <= 0 { throw output.streamError ?? MacDirectoryError.writeFailed }
        offset += written
      }
    }
    guard copied > 0 else { throw MacDirectoryError.emptyFile }
    if manager.fileExists(atPath: target.path) && !replaceCatalog {
      guard try Self.filesEqual(temporary, target) else {
        throw MacDirectoryError.immutableObjectChanged
      }
      try manager.removeItem(at: temporary)
    } else if manager.fileExists(atPath: target.path) {
      _ = try manager.replaceItemAt(target, withItemAt: temporary)
    } else {
      try manager.moveItem(at: temporary, to: target)
    }
    return copied
  }

  private static func filesEqual(_ left: URL, _ right: URL) throws -> Bool {
    let manager = FileManager.default
    let leftSize = try manager.attributesOfItem(atPath: left.path)[.size] as? NSNumber
    let rightSize = try manager.attributesOfItem(atPath: right.path)[.size] as? NSNumber
    guard leftSize == rightSize else { return false }
    guard let a = InputStream(url: left), let b = InputStream(url: right) else {
      throw MacDirectoryError.openFailed
    }
    a.open(); b.open()
    defer { a.close(); b.close() }
    var ab = [UInt8](repeating: 0, count: 1024 * 1024)
    var bb = [UInt8](repeating: 0, count: 1024 * 1024)
    while true {
      let ac = a.read(&ab, maxLength: ab.count)
      let bc = b.read(&bb, maxLength: bb.count)
      guard ac >= 0, bc >= 0 else { throw MacDirectoryError.readFailed }
      guard ac == bc else { return false }
      if ac == 0 { return true }
      guard ab[0..<ac].elementsEqual(bb[0..<bc]) else { return false }
    }
  }

  private static func validateSegment(_ value: String) throws {
    guard
      !value.isEmpty, value != ".", value != "..",
      value.lengthOfBytes(using: .utf8) <= 255,
      !value.contains("/"), !value.contains("\\"),
      !value.unicodeScalars.contains(where: { $0.value == 0 || $0.value < 0x20 || $0.value == 0x7f })
    else { throw MacDirectoryError.unsafeName }
  }

  private static func isDescendant(_ candidate: URL, of root: URL) -> Bool {
    candidate.standardizedFileURL.path.hasPrefix(root.standardizedFileURL.path + "/")
  }
}

private enum MacDirectoryError: LocalizedError {
  case invalidArguments, staleBookmark, revokedPermission, destinationEscaped
  case enumerationFailed, tooDeep, sourceEscaped, tooManyFiles, fileTooLarge
  case openFailed, readFailed, writeFailed, emptyFile, immutableObjectChanged, unsafeName

  var errorDescription: String? {
    switch self {
    case .invalidArguments: return "Invalid authorized-directory arguments"
    case .staleBookmark: return "The saved directory authorization is stale; select it again"
    case .revokedPermission: return "The system directory permission was revoked"
    case .destinationEscaped: return "The mirror destination escaped application support"
    case .enumerationFailed: return "Unable to enumerate the selected directory"
    case .tooDeep: return "The selected directory is nested too deeply"
    case .sourceEscaped: return "A selected directory item escaped its root"
    case .tooManyFiles: return "The selected directory contains too many SBOX files"
    case .fileTooLarge: return "A selected SBOX file exceeds the configured limit"
    case .openFailed: return "Unable to open a selected SBOX file"
    case .readFailed: return "Unable to read a selected SBOX file"
    case .writeFailed: return "Unable to write the permanent ciphertext mirror"
    case .emptyFile: return "An empty SBOX file is invalid"
    case .immutableObjectChanged: return "An immutable mirrored SBOX path changed content"
    case .unsafeName: return "The file provider returned an unsafe name"
    }
  }
}
