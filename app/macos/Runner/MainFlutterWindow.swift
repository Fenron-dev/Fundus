import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  private var securityScopedURLs: [URL] = []

  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    RegisterGeneratedPlugins(registry: flutterViewController)

    let bookmarks = FlutterMethodChannel(
      name: "dev.fundus/security_scoped_bookmarks",
      binaryMessenger: flutterViewController.engine.binaryMessenger
    )
    bookmarks.setMethodCallHandler { [weak self] call, result in
      guard let arguments = call.arguments as? [String: Any] else {
        result(FlutterError(code: "invalid_arguments", message: nil, details: nil))
        return
      }
      do {
        switch call.method {
        case "create":
          guard let path = arguments["path"] as? String else {
            throw BookmarkError.missingValue
          }
          let data = try URL(fileURLWithPath: path).bookmarkData(
            options: .withSecurityScope,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
          )
          result(data.base64EncodedString())
        case "startAccess":
          guard
            let encoded = arguments["bookmark"] as? String,
            let data = Data(base64Encoded: encoded)
          else {
            throw BookmarkError.missingValue
          }
          var stale = false
          let url = try URL(
            resolvingBookmarkData: data,
            options: .withSecurityScope,
            relativeTo: nil,
            bookmarkDataIsStale: &stale
          )
          guard url.startAccessingSecurityScopedResource() else {
            throw BookmarkError.accessDenied
          }
          self?.securityScopedURLs.append(url)
          result(url.path)
        default:
          result(FlutterMethodNotImplemented)
        }
      } catch {
        result(FlutterError(
          code: "bookmark_error",
          message: error.localizedDescription,
          details: nil
        ))
      }
    }

    super.awakeFromNib()
  }
}

private enum BookmarkError: LocalizedError {
  case missingValue
  case accessDenied

  var errorDescription: String? {
    switch self {
    case .missingValue: return "Security-Bookmark ist unvollständig."
    case .accessDenied: return "Der Bibliothekszugriff konnte nicht aktiviert werden."
    }
  }
}
