import Cocoa
import FlutterMacOS
import PDFKit

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

    let fileOpener = FlutterMethodChannel(
      name: "dev.fundus/file_opener",
      binaryMessenger: flutterViewController.engine.binaryMessenger
    )
    fileOpener.setMethodCallHandler { call, result in
      guard call.method == "open" else {
        result(FlutterMethodNotImplemented)
        return
      }
      guard
        let arguments = call.arguments as? [String: Any],
        let path = arguments["path"] as? String,
        FileManager.default.fileExists(atPath: path)
      else {
        result(FlutterError(
          code: "missing_file",
          message: "Die Datei ist nicht mehr vorhanden.",
          details: nil
        ))
        return
      }
      result(NSWorkspace.shared.open(URL(fileURLWithPath: path)))
    }

    let pdfRenderer = FlutterMethodChannel(
      name: "dev.fundus/pdf_renderer",
      binaryMessenger: flutterViewController.engine.binaryMessenger
    )
    pdfRenderer.setMethodCallHandler { call, result in
      guard
        let arguments = call.arguments as? [String: Any],
        let path = arguments["path"] as? String,
        let document = PDFDocument(url: URL(fileURLWithPath: path))
      else {
        result(FlutterError(
          code: "pdf_error",
          message: "Die PDF-Datei konnte nicht gelesen werden.",
          details: nil
        ))
        return
      }
      switch call.method {
      case "pageCount":
        result(document.pageCount)
      case "renderPage":
        guard
          let pageIndex = arguments["page"] as? Int,
          pageIndex >= 0,
          let page = document.page(at: pageIndex)
        else {
          result(FlutterError(
            code: "pdf_page_error",
            message: "Die PDF-Seite existiert nicht.",
            details: nil
          ))
          return
        }
        let requestedWidth = (arguments["maxWidth"] as? Int) ?? 1800
        let width = CGFloat(min(max(requestedWidth, 600), 2400))
        let bounds = page.bounds(for: .mediaBox)
        let height = min(
          CGFloat(3600),
          max(CGFloat(1), width * bounds.height / max(bounds.width, CGFloat(1)))
        )
        let image = page.thumbnail(of: NSSize(width: width, height: height), for: .mediaBox)
        guard
          let tiff = image.tiffRepresentation,
          let bitmap = NSBitmapImageRep(data: tiff),
          let png = bitmap.representation(using: .png, properties: [:])
        else {
          result(FlutterError(
            code: "pdf_render_error",
            message: "Die PDF-Seite konnte nicht dargestellt werden.",
            details: nil
          ))
          return
        }
        result(FlutterStandardTypedData(bytes: png))
      default:
        result(FlutterMethodNotImplemented)
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
