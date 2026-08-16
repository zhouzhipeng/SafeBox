import Flutter
import UIKit
import UniformTypeIdentifiers

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    AuthorizedDirectoryPlugin.register(with: engineBridge.pluginRegistry)
  }
}

private final class AuthorizedDirectoryPlugin: NSObject, UIDocumentPickerDelegate {
  private enum PendingPicker {
    case directory(FlutterResult)
    case export(FlutterResult)
  }

  private static let channelName = "com.zhouzhipeng.safebox/authorized_directory"
  private static var retainedInstance: AuthorizedDirectoryPlugin?

  private var pendingPicker: PendingPicker?
  private let worker = DispatchQueue(label: "com.zhouzhipeng.safebox.authorized-directory")

  static func register(with registry: FlutterPluginRegistry) {
    guard let registrar = registry.registrar(forPlugin: "SafeBoxAuthorizedDirectoryPlugin") else {
      return
    }
    let instance = AuthorizedDirectoryPlugin()
    retainedInstance = instance
    FlutterMethodChannel(name: channelName, binaryMessenger: registrar.messenger())
      .setMethodCallHandler(instance.handle)
  }

  private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "chooseDirectory":
      chooseDirectory(result: result)
    case "mirrorCiphertext":
      mirrorCiphertext(arguments: call.arguments, result: result)
    case "releaseDirectory":
      result(nil)
    case "protectTemporaryPlaintext":
      protectTemporaryPlaintext(arguments: call.arguments, result: result)
    case "exportFile":
      exportFile(arguments: call.arguments, result: result)
    default:
      result(FlutterMethodNotImplemented)
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
        throw SafeBoxDirectoryError.destinationEscaped
      }
      try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
      var values = URLResourceValues()
      values.isExcludedFromBackup = true
      var mutableRoot = root
      try mutableRoot.setResourceValues(values)
      try FileManager.default.setAttributes(
        [.protectionKey: FileProtectionType.complete],
        ofItemAtPath: root.path
      )
      result(nil)
    } catch {
      result(FlutterError(code: "protection", message: "Unable to protect temporary plaintext", details: nil))
    }
  }

  private func chooseDirectory(result: @escaping FlutterResult) {
    guard pendingPicker == nil else {
      result(FlutterError(code: "busy", message: "A directory picker is already active", details: nil))
      return
    }
    guard let presenter = Self.presentingViewController() else {
      result(FlutterError(code: "picker", message: "No active view controller", details: nil))
      return
    }
    pendingPicker = .directory(result)
    let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.folder], asCopy: false)
    picker.delegate = self
    picker.allowsMultipleSelection = false
    presenter.present(picker, animated: true)
  }

  func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
    let pending = pendingPicker
    pendingPicker = nil
    guard let pending else { return }
    switch pending {
    case .directory(let result): result(nil)
    case .export(let result): result(false)
    }
  }

  func documentPicker(
    _ controller: UIDocumentPickerViewController,
    didPickDocumentsAt urls: [URL]
  ) {
    let pending = pendingPicker
    pendingPicker = nil
    guard let pending else { return }
    if case .export(let result) = pending {
      result(!urls.isEmpty)
      return
    }
    guard case .directory(let result) = pending, let url = urls.first else {
      if case .directory(let result) = pending { result(nil) }
      return
    }
    guard url.startAccessingSecurityScopedResource() else {
      result(FlutterError(code: "permission", message: "Directory access was denied", details: nil))
      return
    }
    defer { url.stopAccessingSecurityScopedResource() }
    do {
      let bookmark = try url.bookmarkData(
        options: .minimalBookmark,
        includingResourceValuesForKeys: nil,
        relativeTo: nil
      )
      result([
        "reference": bookmark.base64EncodedString(),
        "platform": "ios",
        "display_name": url.lastPathComponent.isEmpty ? "iOS 系统目录" : url.lastPathComponent,
      ])
    } catch {
      result(FlutterError(code: "bookmark", message: "Unable to save directory authorization", details: nil))
    }
  }

  private func exportFile(arguments: Any?, result: @escaping FlutterResult) {
    guard pendingPicker == nil else {
      result(FlutterError(code: "busy", message: "A system file picker is already active", details: nil))
      return
    }
    guard
      let arguments = arguments as? [String: Any],
      let sourcePath = arguments["source_path"] as? String,
      let suggestedName = arguments["suggested_name"] as? String,
      let mimeType = arguments["mime_type"] as? String
    else {
      result(FlutterError(code: "arguments", message: "Missing export arguments", details: nil))
      return
    }
    do {
      try Self.validateSegment(suggestedName)
      guard !mimeType.isEmpty, mimeType.utf8.count <= 255, !mimeType.contains("\0") else {
        throw SafeBoxDirectoryError.invalidArguments
      }
      let source = URL(fileURLWithPath: sourcePath).standardizedFileURL
      let container = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true).standardizedFileURL
      var isDirectory: ObjCBool = false
      guard
        Self.isDescendant(source, of: container),
        FileManager.default.fileExists(atPath: source.path, isDirectory: &isDirectory),
        !isDirectory.boolValue
      else {
        throw SafeBoxDirectoryError.openFailed
      }
      guard let presenter = Self.presentingViewController() else {
        throw SafeBoxDirectoryError.openFailed
      }
      pendingPicker = .export(result)
      let picker = UIDocumentPickerViewController(forExporting: [source], asCopy: true)
      picker.delegate = self
      presenter.present(picker, animated: true)
    } catch {
      pendingPicker = nil
      result(FlutterError(code: "export", message: error.localizedDescription, details: nil))
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
        let value = try self.mirror(
          reference: reference,
          destinationPath: destinationPath,
          maximumDepth: maximumDepth,
          maximumFiles: maximumFiles,
          maximumFileBytes: maximumFileBytes
        )
        DispatchQueue.main.async { result(value) }
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
    else {
      throw SafeBoxDirectoryError.invalidArguments
    }
    var stale = false
    let selectedURL = try URL(
      resolvingBookmarkData: bookmark,
      options: [.withoutUI],
      relativeTo: nil,
      bookmarkDataIsStale: &stale
    )
    guard !stale else { throw SafeBoxDirectoryError.staleBookmark }
    guard selectedURL.startAccessingSecurityScopedResource() else {
      throw SafeBoxDirectoryError.revokedPermission
    }
    defer { selectedURL.stopAccessingSecurityScopedResource() }

    let fileManager = FileManager.default
    let destination = URL(fileURLWithPath: destinationPath, isDirectory: true).standardizedFileURL
    let support = try fileManager.url(
      for: .applicationSupportDirectory,
      in: .userDomainMask,
      appropriateFor: nil,
      create: true
    ).standardizedFileURL
    guard Self.isDescendant(destination, of: support) else {
      throw SafeBoxDirectoryError.destinationEscaped
    }
    try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)

    var coordinationError: NSError?
    var operationError: Error?
    var output: [String: Any]?
    NSFileCoordinator().coordinate(
      readingItemAt: selectedURL,
      options: [],
      error: &coordinationError
    ) { coordinatedURL in
      do {
        output = try self.copyCiphertextTree(
          source: coordinatedURL,
          destination: destination,
          maximumDepth: maximumDepth,
          maximumFiles: maximumFiles,
          maximumFileBytes: maximumFileBytes
        )
      } catch {
        operationError = error
      }
    }
    if let coordinationError { throw coordinationError }
    if let operationError { throw operationError }
    guard let output else { throw SafeBoxDirectoryError.enumerationFailed }
    return output
  }

  private func copyCiphertextTree(
    source: URL,
    destination: URL,
    maximumDepth: Int,
    maximumFiles: Int,
    maximumFileBytes: Int64
  ) throws -> [String: Any] {
    let fileManager = FileManager.default
    let keys: [URLResourceKey] = [
      .isDirectoryKey,
      .isRegularFileKey,
      .isSymbolicLinkKey,
      .fileSizeKey,
    ]
    var enumerationError: Error?
    guard let enumerator = fileManager.enumerator(
      at: source,
      includingPropertiesForKeys: keys,
      options: [],
      errorHandler: { _, error in
        enumerationError = error
        return false
      }
    ) else {
      throw SafeBoxDirectoryError.enumerationFailed
    }
    var fileCount = 0
    var totalBytes: Int64 = 0
    var catalogPresent = false
    let sourcePath = source.standardizedFileURL.path

    while let item = enumerator.nextObject() as? URL {
      if enumerator.level > maximumDepth {
        enumerator.skipDescendants()
        throw SafeBoxDirectoryError.tooDeep
      }
      let values = try item.resourceValues(forKeys: Set(keys))
      if values.isSymbolicLink == true {
        enumerator.skipDescendants()
        continue
      }
      let standardized = item.standardizedFileURL
      guard standardized.path.hasPrefix(sourcePath + "/") else {
        throw SafeBoxDirectoryError.sourceEscaped
      }
      let relativeText = String(standardized.path.dropFirst(sourcePath.count + 1))
      let segments = relativeText.split(separator: "/", omittingEmptySubsequences: false)
        .map(String.init)
      try segments.forEach(Self.validateSegment)
      if values.isDirectory == true {
        if item.lastPathComponent == ".sbox-staging" || item.lastPathComponent == ".sbox-sync" {
          enumerator.skipDescendants()
        }
        continue
      }
      guard values.isRegularFile == true, item.pathExtension.lowercased() == "sbox" else {
        continue
      }
      fileCount += 1
      guard fileCount <= maximumFiles else { throw SafeBoxDirectoryError.tooManyFiles }
      if let declared = values.fileSize {
        guard declared > 0 && Int64(declared) <= maximumFileBytes else {
          throw SafeBoxDirectoryError.fileTooLarge
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
      let (nextTotal, overflow) = totalBytes.addingReportingOverflow(copied)
      guard !overflow else { throw SafeBoxDirectoryError.fileTooLarge }
      totalBytes = nextTotal
      if isCatalog { catalogPresent = true }
    }
    if let enumerationError { throw enumerationError }
    return [
      "file_count": fileCount,
      "total_bytes": totalBytes,
      "catalog_present": catalogPresent,
    ]
  }

  private func copyOne(
    source: URL,
    destinationRoot: URL,
    segments: [String],
    maximumFileBytes: Int64,
    replaceCatalog: Bool
  ) throws -> Int64 {
    let fileManager = FileManager.default
    let target = segments.reduce(destinationRoot) { $0.appendingPathComponent($1) }
      .standardizedFileURL
    guard Self.isDescendant(target, of: destinationRoot) else {
      throw SafeBoxDirectoryError.destinationEscaped
    }
    try fileManager.createDirectory(
      at: target.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    let temporary = target.deletingLastPathComponent().appendingPathComponent(
      ".\(target.lastPathComponent).\(UUID().uuidString).part"
    )
    defer { try? fileManager.removeItem(at: temporary) }
    let input = InputStream(url: source)
    let output = OutputStream(url: temporary, append: false)
    guard let input, let output else { throw SafeBoxDirectoryError.openFailed }
    input.open()
    output.open()
    defer {
      input.close()
      output.close()
    }
    var copied: Int64 = 0
    var buffer = [UInt8](repeating: 0, count: 1024 * 1024)
    while true {
      let read = input.read(&buffer, maxLength: buffer.count)
      if read < 0 { throw input.streamError ?? SafeBoxDirectoryError.readFailed }
      if read == 0 { break }
      let (next, overflow) = copied.addingReportingOverflow(Int64(read))
      guard !overflow && next <= maximumFileBytes else {
        throw SafeBoxDirectoryError.fileTooLarge
      }
      copied = next
      var offset = 0
      while offset < read {
        let written = buffer.withUnsafeBufferPointer { pointer in
          output.write(pointer.baseAddress! + offset, maxLength: read - offset)
        }
        if written <= 0 { throw output.streamError ?? SafeBoxDirectoryError.writeFailed }
        offset += written
      }
    }
    guard copied > 0 else { throw SafeBoxDirectoryError.emptyFile }

    if fileManager.fileExists(atPath: target.path) && !replaceCatalog {
      guard try Self.filesEqual(temporary, target) else {
        throw SafeBoxDirectoryError.immutableObjectChanged
      }
      try fileManager.removeItem(at: temporary)
    } else if fileManager.fileExists(atPath: target.path) {
      _ = try fileManager.replaceItemAt(target, withItemAt: temporary)
    } else {
      try fileManager.moveItem(at: temporary, to: target)
    }
    return copied
  }

  private static func filesEqual(_ left: URL, _ right: URL) throws -> Bool {
    let manager = FileManager.default
    let leftSize = try manager.attributesOfItem(atPath: left.path)[.size] as? NSNumber
    let rightSize = try manager.attributesOfItem(atPath: right.path)[.size] as? NSNumber
    guard leftSize == rightSize else { return false }
    guard let leftInput = InputStream(url: left), let rightInput = InputStream(url: right) else {
      throw SafeBoxDirectoryError.openFailed
    }
    leftInput.open()
    rightInput.open()
    defer {
      leftInput.close()
      rightInput.close()
    }
    var leftBuffer = [UInt8](repeating: 0, count: 1024 * 1024)
    var rightBuffer = [UInt8](repeating: 0, count: 1024 * 1024)
    while true {
      let leftCount = leftInput.read(&leftBuffer, maxLength: leftBuffer.count)
      let rightCount = rightInput.read(&rightBuffer, maxLength: rightBuffer.count)
      guard leftCount >= 0, rightCount >= 0 else { throw SafeBoxDirectoryError.readFailed }
      guard leftCount == rightCount else { return false }
      if leftCount == 0 { return true }
      guard leftBuffer[0..<leftCount].elementsEqual(rightBuffer[0..<rightCount]) else {
        return false
      }
    }
  }

  private static func validateSegment(_ value: String) throws {
    guard
      !value.isEmpty,
      value != ".",
      value != "..",
      value.lengthOfBytes(using: .utf8) <= 255,
      !value.contains("/"),
      !value.contains("\\"),
      !value.unicodeScalars.contains(where: { $0.value == 0 || $0.value < 0x20 || $0.value == 0x7f })
    else {
      throw SafeBoxDirectoryError.unsafeName
    }
  }

  private static func isDescendant(_ candidate: URL, of root: URL) -> Bool {
    let candidatePath = candidate.standardizedFileURL.path
    let rootPath = root.standardizedFileURL.path
    return candidatePath.hasPrefix(rootPath + "/")
  }

  private static func presentingViewController() -> UIViewController? {
    let root = UIApplication.shared.connectedScenes
      .compactMap { $0 as? UIWindowScene }
      .flatMap(\.windows)
      .first(where: \.isKeyWindow)?
      .rootViewController
    var current = root
    while let presented = current?.presentedViewController { current = presented }
    return current
  }
}

private enum SafeBoxDirectoryError: LocalizedError {
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
    case .unsafeName: return "The document provider returned an unsafe name"
    }
  }
}
