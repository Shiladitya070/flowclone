import Foundation
import ServiceManagement

/// Launch-at-login via SMAppService. Only meaningful when the app runs from /Applications,
/// because macOS registers the bundle path it was launched from.
enum LoginItem {
    static var isAvailable: Bool {
        Bundle.main.bundlePath.hasPrefix("/Applications/")
    }

    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    static func set(_ on: Bool) throws {
        if on {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }
}
