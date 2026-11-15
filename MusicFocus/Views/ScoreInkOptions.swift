import SwiftUI

struct ScoreInkOptions: View {
    @ObservedObject var reader: ScoreReaderController
    @Environment(\.dismiss) private var dismiss
    @State private var width = 2.0
    @State private var opacity = 1.0

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text((reader.tool.isPen ? "score.penGroup" : reader.tool == .select ? "score.selectedInk" : "score." + reader.tool.rawValue).localized)
                    .font(.headline)
                Spacer()
                Button { dismiss() } label: {
                    Text("Done".localized).frame(minWidth: 44, minHeight: 44).contentShape(Rectangle())
                }
                .buttonStyle(.plain).foregroundStyle(Color.accentColor)
                .accessibilityIdentifier("scoreInkDone")
            }.padding(.horizontal, 20)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if reader.tool.isPen {
                        Picker("score.penMode".localized, selection: $reader.tool) {
                            Text("score.pressurePen".localized).tag(ScoreInkTool.pen)
                            Text("score.uniformPen".localized).tag(ScoreInkTool.monoline)
                        }.pickerStyle(.segmented).accessibilityIdentifier("scorePenMode")
                    }
                    preview
                    if reader.tool == .fingering {
                        fingeringSizeControls
                        ScoreFingeringCoverControls(enabled: Binding(get: { reader.fingeringCoverEnabled }, set: { reader.setFingeringCoverEnabled($0) }),
                            style: Binding(get: { reader.fingeringCoverStyle }, set: { reader.setFingeringCoverStyle($0) }))
                    }
                    if reader.tool.inkType != nil { widthControls }
                    Divider()
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 4), spacing: 4) {
                        ForEach(ScoreInkPalette.colors.indices, id: \.self) { index in
                            let color = ScoreAnnotationColor(ScoreInkPalette.colors[index])
                            Button { reader.chooseColor(index) } label: {
                                ScoreInkSwatch(color: color, selected: isSelected(color))
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(ScoreInkPalette.names[index].localized)
                            .accessibilityAddTraits(isSelected(color) ? .isSelected : [])
                            .accessibilityIdentifier("scoreInkColor-\(index)")
                        }
                    }
                    ColorPicker("score.customColor".localized, selection: Binding(
                        get: { Color(uiColor: reader.currentColor) },
                        set: { reader.chooseColor(UIColor($0)) }), supportsOpacity: false)
                        .frame(minHeight: 44)
                        .accessibilityIdentifier("scoreCustomColor")
                    if reader.canSetOpacity { opacityControls }
                    if reader.tool.inkType != nil {
                        Text(("score." + reader.tool.rawValue + "Hint").localized)
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }.padding(20)
            }.accessibilityIdentifier("scoreInkOptionsScroll")
        }
        .frame(width: 340).frame(idealHeight: 700, maxHeight: 700)
        .onAppear { width = reader.inkStyle.width; opacity = reader.currentOpacity }
        .onChange(of: reader.tool) { _, _ in width = reader.inkStyle.width; opacity = reader.currentOpacity }
    }

    private var fingeringSizeControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("score.fingeringSize".localized).font(.subheadline.weight(.semibold))
            Picker("score.fingeringSize".localized, selection: Binding(
                get: { reader.fingeringSizeMode }, set: { reader.setFingeringSizeMode($0) })) {
                ForEach(ScoreFingeringSizeMode.allCases, id: \.self) { mode in
                    Text(mode.title).tag(mode).accessibilityIdentifier("scoreFingeringSizeMode-" + mode.rawValue)
                }
            }.pickerStyle(.segmented).accessibilityIdentifier("scoreFingeringSizeMode")
            if reader.fingeringSizeMode == .first {
                if let height = reader.fingeringHeight {
                    HStack {
                        Text("score.fingeringSizeHeight".localized).font(.subheadline)
                        Spacer()
                        Text(height.formatted(.number.precision(.fractionLength(1))) + " pt")
                            .monospacedDigit().accessibilityIdentifier("scoreFingeringHeight")
                    }
                    Button("score.resetFingeringSize".localized) { reader.resetFingeringSize() }
                        .frame(minHeight: 44).accessibilityIdentifier("scoreResetFingeringSize")
                }
                Text((reader.fingeringHeight == nil ? "score.fingeringSizeWaiting" : "score.fingeringSizeLocked").localized)
                    .font(.caption).foregroundStyle(.secondary)
                    .accessibilityIdentifier("scoreFingeringSizeHint")
            } else if reader.fingeringSizeMode == .fixed {
                Stepper(value: Binding(get: { reader.fixedFingeringHeight }, set: { reader.setFixedFingeringHeight($0) }),
                        in: ScoreFingeringSizing.fixedHeightRange, step: 1) {
                    Text("score.fingeringSizeHeight".localized + " · " + reader.fixedFingeringHeight.formatted(.number.precision(.fractionLength(0))) + " pt")
                        .monospacedDigit().accessibilityIdentifier("scoreFixedFingeringHeight")
                }.accessibilityIdentifier("scoreFixedFingeringStepper")
                    .accessibilityValue(reader.fixedFingeringHeight.formatted(.number.precision(.fractionLength(0))) + " pt")
                Text("score.fingeringFixedHint".localized).font(.caption).foregroundStyle(.secondary)
            } else {
                Text("score.fingeringHandwrittenHint".localized).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var widthControls: some View {
        VStack(spacing: 8) {
            HStack {
                Text("score.inkWidth".localized).font(.subheadline.weight(.semibold))
                Spacer()
                Text(width.formatted(.number.precision(.fractionLength(1)))).monospacedDigit()
            }
            HStack(spacing: 8) {
                ForEach(Array(reader.tool.widthPresets.enumerated()), id: \.offset) { index, value in
                    Button { width = value } label: {
                        Capsule().fill(Color(uiColor: reader.currentColor))
                            .frame(width: 34, height: min(value, 22))
                            .frame(maxWidth: .infinity, minHeight: 44)
                            .background(abs(width - value) < 0.01 ? Color.accentColor.opacity(0.14) : Color.primary.opacity(0.05),
                                        in: RoundedRectangle(cornerRadius: 10))
                            .overlay(RoundedRectangle(cornerRadius: 10)
                                .stroke(abs(width - value) < 0.01 ? Color.accentColor : .clear, lineWidth: 1.5))
                    }.buttonStyle(.plain)
                        .accessibilityLabel("score.inkWidth".localized + " " + value.formatted())
                        .accessibilityAddTraits(abs(width - value) < 0.01 ? .isSelected : [])
                        .accessibilityIdentifier("scoreInkWidthPreset-\(index)")
                }
            }
            Slider(value: $width, in: reader.tool.widthRange, step: 0.5)
                .frame(minHeight: 44)
                .accessibilityLabel("score.inkWidth".localized)
                .accessibilityIdentifier("scoreInkWidth")
                .onChange(of: width) { _, value in reader.chooseWidth(value) }
        }
    }

    private var opacityControls: some View {
        VStack(spacing: 8) {
            HStack {
                Text("score.inkOpacity".localized).font(.subheadline.weight(.semibold))
                Spacer()
                Text(opacity.formatted(.percent.precision(.fractionLength(0)))).monospacedDigit()
            }
            Slider(value: $opacity, in: 0.1...1, step: 0.05) { editing in
                // One annotation edit per drag keeps Undo useful for imported notes.
                if !editing { reader.chooseOpacity(opacity) }
            }
            .frame(minHeight: 44)
            .accessibilityLabel("score.inkOpacity".localized)
            .accessibilityIdentifier("scoreInkOpacity")
            .onChange(of: opacity) { _, value in
                if reader.tool.inkType != nil { reader.chooseOpacity(value) }
            }
            HStack(spacing: 8) {
                ForEach([0.25, 0.5, 0.75, 1.0], id: \.self) { value in
                    Button {
                        opacity = value; reader.chooseOpacity(value)
                    } label: {
                        Text(value.formatted(.percent.precision(.fractionLength(0))))
                            .font(.subheadline).frame(maxWidth: .infinity, minHeight: 44)
                            .background(abs(opacity - value) < 0.01 ? Color.accentColor.opacity(0.14) : Color.primary.opacity(0.05),
                                        in: RoundedRectangle(cornerRadius: 10))
                    }.buttonStyle(.plain)
                }
            }
        }
    }

    private var preview: some View {
        Canvas { context, size in
            for y in stride(from: 12.0, through: 52.0, by: 10.0) {
                var staff = Path(); staff.move(to: CGPoint(x: 12, y: y)); staff.addLine(to: CGPoint(x: size.width - 12, y: y))
                context.stroke(staff, with: .color(.black.opacity(0.25)), lineWidth: 0.5)
            }
            var line = Path(); line.move(to: CGPoint(x: 24, y: 40))
            line.addCurve(to: CGPoint(x: size.width - 24, y: 26), control1: CGPoint(x: size.width * 0.35, y: 4), control2: CGPoint(x: size.width * 0.6, y: 60))
            context.stroke(line, with: .color(Color(uiColor: reader.currentColor).opacity(opacity)),
                           style: StrokeStyle(lineWidth: reader.tool == .select ? 6 : width, lineCap: .round))
        }
        .frame(height: 64).background(.white, in: RoundedRectangle(cornerRadius: 8))
        .accessibilityLabel("score.inkPreview".localized)
    }

    private func isSelected(_ color: ScoreAnnotationColor) -> Bool {
        ScoreAnnotationColor(reader.currentColor) == color
    }
}

struct ScoreInkSwatch: View {
    let color: ScoreAnnotationColor
    var selected = false

    var body: some View {
        Circle().fill(Color(uiColor: color.uiColor))
            .frame(width: 28, height: 28)
            .overlay(Circle().strokeBorder(.gray.opacity(0.3), lineWidth: 0.5))
            .overlay(Circle().stroke(Color.primary.opacity(selected ? 0.7 : 0), lineWidth: 2).padding(-4))
            .frame(width: 44, height: 44).contentShape(Rectangle())
    }
}

struct ScoreInkToolbarButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .frame(minWidth: 44, minHeight: 44).contentShape(Rectangle())
            .background(configuration.isPressed ? Color.primary.opacity(0.08) : .clear,
                        in: RoundedRectangle(cornerRadius: 10))
            .opacity(isEnabled ? 1 : 0.35)
    }
}


struct ScoreInkPresetSelection: Identifiable {
    let index: Int
    var id: Int { index }
}

/// Opens the system color grid/spectrum/sliders directly for one favorite slot.
/// Every selected color replaces that slot immediately and is saved locally.
struct ScoreInkPresetEditor: View {
    @ObservedObject var reader: ScoreReaderController
    let index: Int
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScoreInkPresetColorPicker(reader: reader, index: index)
                .navigationTitle("score.colorPresetNumber".localizedFormat(index + 1))
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done".localized) { dismiss() }
                            .accessibilityIdentifier("scorePresetEditorDone")
                    }
                }
        }
    }
}

private struct ScoreInkPresetColorPicker: UIViewControllerRepresentable {
    @ObservedObject var reader: ScoreReaderController
    let index: Int
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> UIColorPickerViewController {
        let picker = UIColorPickerViewController()
        picker.supportsAlpha = false
        picker.selectedColor = reader.inkColorPresets[index].uiColor
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ picker: UIColorPickerViewController, context: Context) {
        context.coordinator.onSelect = { reader.setInkColorPreset($0, at: index) }
        context.coordinator.onFinish = { dismiss() }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onSelect: { reader.setInkColorPreset($0, at: index) }, onFinish: { dismiss() })
    }

    final class Coordinator: NSObject, UIColorPickerViewControllerDelegate {
        var onSelect: (UIColor) -> Void
        var onFinish: () -> Void
        init(onSelect: @escaping (UIColor) -> Void, onFinish: @escaping () -> Void) {
            self.onSelect = onSelect; self.onFinish = onFinish
        }
        func colorPickerViewControllerDidSelectColor(_ viewController: UIColorPickerViewController) {
            onSelect(viewController.selectedColor)
        }
        func colorPickerViewControllerDidFinish(_ viewController: UIColorPickerViewController) { onFinish() }
    }
}
