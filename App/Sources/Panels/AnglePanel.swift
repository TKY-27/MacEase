import Engine
import SwiftUI

struct AngleChoice: Codable, Equatable {
    var degrees = 15.0
    var fillsTransparent = true
    var fill = Engine.RGBColor.black
}

/// Video rotation always needs a fill.
struct AnglePanel: View {
    let offersTransparency: Bool
    @State var choice: AngleChoice
    let cancel: () -> Void
    let run: (AngleChoice) -> Void

    private static let degreeRange = -360.0...360.0
    private static let unitSpacing: CGFloat = 2

    var body: some View {
        PanelForm(
            actionTitle: String(localized: "Rotate", comment: "Angle panel action"),
            canRun: Self.degreeRange.contains(choice.degrees) && choice.degrees != 0, cancel: cancel
        ) {
            run(choice)
        } content: {
            HStack {
                Spacer()
                AngleDial(degrees: $choice.degrees)
                Spacer()
            }
            LabeledContent {
                HStack(spacing: Self.unitSpacing) {
                    TextField("Angle", value: $choice.degrees, format: .number.precision(.fractionLength(0...2)))
                        .labelsHidden()
                        .multilineTextAlignment(.trailing)
                    Text(verbatim: "°")
                        .accessibilityHidden(true)
                }
            } label: {
                Text("Angle")
                Text("Clockwise; negative turns left.")
            }
            if offersTransparency {
                Picker("Corners", selection: $choice.fillsTransparent) {
                    Text("Transparent").tag(true)
                    Text("Color").tag(false)
                }
                .pickerStyle(.segmented)
            }
            if !offersTransparency || !choice.fillsTransparent {
                ColorPicker("Fill color", selection: $choice.fill.color, supportsOpacity: false)
            }
        }
    }
}

private struct AngleDial: View {
    @Binding var degrees: Double

    private static let diameter: CGFloat = 96
    private static let lineWidth: CGFloat = 2
    private static let knobDiameter: CGFloat = 12
    private static let keyboardStep = 1.0
    private static let fullTurn = 360.0
    private static let halfTurn = 180.0
    /// Zero points up, like a clock.
    private static let upright = 90.0

    var body: some View {
        ZStack {
            Circle()
                .strokeBorder(.separator, lineWidth: Self.lineWidth)
            Rectangle()
                .fill(.tint)
                .frame(width: Self.lineWidth, height: Self.diameter / 2)
                .offset(y: -Self.diameter / 4)
                .rotationEffect(.degrees(degrees))
            Circle()
                .fill(.tint)
                .frame(width: Self.knobDiameter, height: Self.knobDiameter)
                .offset(y: -Self.diameter / 2 + Self.knobDiameter / 2)
                .rotationEffect(.degrees(degrees))
        }
        .frame(width: Self.diameter, height: Self.diameter)
        .contentShape(Circle())
        .gesture(
            DragGesture(minimumDistance: 0).onChanged { value in
                let center = Self.diameter / 2
                let radians = atan2(value.location.y - center, value.location.x - center)
                let clockwise = (radians * Self.halfTurn / .pi + Self.upright).rounded()
                degrees = clockwise > Self.halfTurn ? clockwise - Self.fullTurn : clockwise
            }
        )
        .accessibilityElement()
        .accessibilityLabel(Text("Angle"))
        .accessibilityValue(Text(degrees, format: .number.precision(.fractionLength(0...2))))
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: degrees += Self.keyboardStep
            case .decrement: degrees -= Self.keyboardStep
            @unknown default: break
            }
        }
    }
}
