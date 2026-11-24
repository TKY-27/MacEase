import CoreFoundation
import Foundation

enum FinderStorageBarGeometry {
    // From Finder's nib; calibrate on a real Mac.
    enum Calibration {
        static let statusBarHeight: CGFloat = 20
        static let bottomInset: CGFloat = 0
    }

    static let minimumWidth: CGFloat = 160

    struct Placement: Equatable {
        let frame: CGRect
        let roundsLeadingCorner: Bool
        let roundsTrailingCorner: Bool
    }

    static func placement(
        window: CGRect, preview: FinderPreviewGeometry.Placement?, statusBarShown: Bool
    ) -> Placement? {
        guard statusBarShown, window.height > Calibration.statusBarHeight + Calibration.bottomInset else {
            return nil
        }
        var strip = CGRect(
            x: window.minX, y: window.minY + Calibration.bottomInset,
            width: window.width, height: Calibration.statusBarHeight)
        if let covered = preview?.frame, covered.intersects(strip) {
            let leading = covered.minX - strip.minX
            let trailing = strip.maxX - covered.maxX
            guard max(leading, trailing) > 0 else { return nil }
            strip =
                leading >= trailing
                ? CGRect(x: strip.minX, y: strip.minY, width: leading, height: strip.height)
                : CGRect(x: covered.maxX, y: strip.minY, width: trailing, height: strip.height)
        }
        guard strip.width >= minimumWidth else { return nil }
        return Placement(
            frame: strip, roundsLeadingCorner: strip.minX == window.minX,
            roundsTrailingCorner: strip.maxX == window.maxX)
    }

    static func finderShowsStatusBar() -> Bool {
        let finder = "com.apple.finder" as CFString
        CFPreferencesAppSynchronize(finder)
        return CFPreferencesGetAppBooleanValue("ShowStatusBar" as CFString, finder, nil)
    }
}
