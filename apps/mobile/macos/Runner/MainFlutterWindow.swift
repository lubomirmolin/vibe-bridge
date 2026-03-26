import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    RegisterGeneratedPlugins(registry: flutterViewController)

    titleVisibility = .hidden
    titlebarAppearsTransparent = true
    styleMask.insert(.fullSizeContentView)
    isMovableByWindowBackground = true

    if #available(macOS 11.0, *) {
      let unifiedToolbar = NSToolbar(identifier: NSToolbar.Identifier("CodexWindowToolbar"))
      unifiedToolbar.showsBaselineSeparator = false
      toolbar = unifiedToolbar
      toolbarStyle = .unifiedCompact
    }

    super.awakeFromNib()
  }
}
