import CoreFoundation
import Foundation

enum FinderStorageBarGeometry {
    // Assumed from Finder's nib; calibrate live.
    enum Calibration {
        static let statusBarHeight: CGFloat = 20
        static let bottomInset: CGFloat = 0
        static let iconSliderWidth: CGFloat = 133
        static let iconSliderMargin: CGFloat = 16
        static var iconSliderReserved: CGFloat { iconSliderWidth + iconSliderMargin }
    }

    static let minimumWidth: CGFloat = 160

    struct Placement: Equatable {
        let frame: CGRect
        let roundsLeadingCorner: Bool
        let roundsTrailingCorner: Bool
    }

    static func placement(
        window: CGRect, preview: FinderPreviewGeometry.Placement?, statusBarShown: Bool, view: FinderWindowView
    ) -> Placement? {
        guard statusBarShown, window.height > Calibration.statusBarHeight + Calibration.bottomInset else {
            return nil
        }
        var strip = CGRect(
            x: window.minX, y: window.minY + Calibration.bottomInset,
            width: window.width, height: Calibration.statusBarHeight)
        var roundsLeadingCorner = true
        var roundsTrailingCorner = true
        if view.showsIconSizeSlider {
            let remaining = strip.width - Calibration.iconSliderReserved
            guard remaining > 0 else { return nil }
            strip.size.width = remaining
            roundsTrailingCorner = false
        }
        if let covered = preview?.frame, covered.intersects(strip) {
            let leading = covered.minX - strip.minX
            let trailing = strip.maxX - covered.maxX
            guard max(leading, trailing) > 0 else { return nil }
            if leading >= trailing {
                strip = CGRect(x: strip.minX, y: strip.minY, width: leading, height: strip.height)
                roundsTrailingCorner = false
            } else {
                strip = CGRect(x: covered.maxX, y: strip.minY, width: trailing, height: strip.height)
                roundsLeadingCorner = false
            }
        }
        guard strip.width >= minimumWidth else { return nil }
        return Placement(
            frame: strip, roundsLeadingCorner: roundsLeadingCorner,
            roundsTrailingCorner: roundsTrailingCorner)
    }

    static func finderShowsStatusBar() -> Bool {
        let finder = "com.apple.finder" as CFString
        CFPreferencesAppSynchronize(finder)
        return CFPreferencesGetAppBooleanValue("ShowStatusBar" as CFString, finder, nil)
    }
}
