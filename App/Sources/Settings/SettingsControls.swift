import AppKit
import Engine
import SwiftUI
import os

struct QualitySlider: View {
    let title: Text
    @Binding var value: Int

    private static let range = 0.0...100.0
    private static let valueWidth: CGFloat = 32

    var body: some View {
        LabeledContent {
            HStack {
                Slider(value: sliderValue, in: Self.range) { title }
                    .labelsHidden()
                Text(value, format: .number)
                    .monospacedDigit()
                    .frame(width: Self.valueWidth, alignment: .trailing)
                    .accessibilityHidden(true)
            }
        } label: {
            title
        }
    }

    private var sliderValue: Binding<Double> {
        Binding {
            Double(value)
        } set: {
            value = Int($0.rounded())
        }
    }
}

struct NumberField: View {
    let title: Text
    @Binding var value: Int
    let range: ClosedRange<Int>
    var step = 1

    private static let fieldWidth: CGFloat = 64
    private static let stepperSpacing: CGFloat = 4

    var body: some View {
        LabeledContent {
            HStack(spacing: Self.stepperSpacing) {
                TextField(value: clamped, format: .number.grouping(.never)) { title }
                    .labelsHidden()
                    .multilineTextAlignment(.trailing)
                    .frame(width: Self.fieldWidth)
                Stepper(value: clamped, in: range, step: step) { title }
                    .labelsHidden()
            }
        } label: {
            title
        }
    }

    private var clamped: Binding<Int> {
        Binding {
            value
        } set: {
            value = min(max($0, range.lowerBound), range.upperBound)
        }
    }
}

/// Form DisclosureGroups ignore accessibility presses.
struct MoreOptionsRow: View {
    let title: String
    @Binding var isExpanded: Bool

    var body: some View {
        Button {
            isExpanded.toggle()
        } label: {
            HStack {
                Text(title)
                Spacer()
                Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                    .foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(
            isExpanded
                ? Text("Hide \(title)", comment: "Collapse a group of options")
                : Text("Show \(title)", comment: "Expand a group of options"))
    }
}

struct ProblemLabel: View {
    let text: String

    var body: some View {
        Label(text, systemImage: "exclamationmark.triangle.fill")
            .foregroundStyle(.red)
    }
}

struct ChecklistSheet<Content: View>: View {
    let resetTitle: LocalizedStringKey
    let canReset: Bool
    let reset: () -> Void
    @ViewBuilder let content: Content
    @Environment(\.dismiss) private var dismiss

    private static var width: CGFloat { 440 }
    /// Sheets taller than their tab overhang it.
    private static var height: CGFloat { 360 }

    var body: some View {
        VStack(spacing: 0) {
            Form { content }
                .formStyle(.grouped)
            Divider()
            HStack {
                Button(resetTitle, action: reset)
                    .disabled(!canReset)
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding()
        }
        .frame(width: Self.width, height: Self.height)
    }
}

extension Binding {
    /// Binding(optional) traps when nil arrives mid-update.
    func unwrapped<Wrapped: Sendable>(or fallback: Wrapped) -> Binding<Wrapped> where Value == Wrapped? {
        Binding<Wrapped> {
            wrappedValue ?? fallback
        } set: {
            wrappedValue = $0
        }
    }
}

extension Binding where Value == Engine.RGBColor {
    var color: Binding<Color> {
        Binding<Color> {
            wrappedValue.color
        } set: { color in
            guard let rgb = Engine.RGBColor(color) else {
                Logger(category: "settings").error("Picked color has no sRGB form")
                return
            }
            wrappedValue = rgb
        }
    }
}

extension Engine.RGBColor {
    private static let channelMax = 255.0

    var color: Color {
        Color(
            .sRGB, red: Double(red) / Self.channelMax, green: Double(green) / Self.channelMax,
            blue: Double(blue) / Self.channelMax)
    }

    /// Nil when no sRGB form exists.
    init?(_ color: Color) {
        guard let srgb = NSColor(color).usingColorSpace(.sRGB) else { return nil }
        func channel(_ component: CGFloat) -> UInt8 {
            UInt8((min(max(component, 0), 1) * Self.channelMax).rounded())
        }
        self.init(
            red: channel(srgb.redComponent), green: channel(srgb.greenComponent), blue: channel(srgb.blueComponent))
    }
}

func isPresent<Value: Sendable>(_ value: Binding<Value?>) -> Binding<Bool> {
    Binding {
        value.wrappedValue != nil
    } set: { shown in
        if !shown { value.wrappedValue = nil }
    }
}
