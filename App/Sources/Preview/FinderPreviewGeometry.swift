import Foundation

enum FinderPreviewGeometry {
    static let defaultWidth: CGFloat = 360
    static let minimumWidth: CGFloat = 280

    enum Dock: Equatable {
        case right, left, inset
    }

    struct Placement: Equatable {
        let frame: CGRect
        let dock: Dock
    }

    static func appKitFrame(axFrame: CGRect, primaryScreenTop: CGFloat) -> CGRect {
        CGRect(
            x: axFrame.minX, y: primaryScreenTop - axFrame.maxY,
            width: axFrame.width, height: axFrame.height)
    }

    static func placement(window: CGRect, screen: CGRect, width: CGFloat) -> Placement {
        let maximumWidth = screen.width / 2
        let resolved = min(maximumWidth, max(minimumWidth, width))
        let x: CGFloat
        let dock: Dock
        if window.maxX + resolved <= screen.maxX {
            x = window.maxX
            dock = .right
        } else if window.minX - resolved >= screen.minX {
            x = window.minX - resolved
            dock = .left
        } else {
            x = min(screen.maxX - resolved, max(screen.minX, window.maxX - resolved))
            dock = .inset
        }
        return Placement(
            frame: CGRect(x: x, y: window.minY, width: resolved, height: window.height), dock: dock)
    }
}
