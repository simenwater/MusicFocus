import PencilKit

enum ScoreInkTool: String, CaseIterable {
    case pen, monoline, marker, fingering, cover, voice, eraser, select
    static let toolbarTools: [Self] = [.pen, .marker, .fingering, .cover, .voice, .eraser, .select]
    var isPen: Bool { self == .pen || self == .monoline }
    var symbol: String {
        switch self {
        case .pen: return "pencil.tip"
        case .fingering: return "hand.point.up.left"
        case .cover: return "rectangle.inset.filled"
        case .voice: return "speaker.wave.2"
        case .monoline: return "pencil.line"
        case .marker: return "paintbrush.pointed"
        case .eraser: return "eraser"
        case .select: return "cursorarrow"
        }
    }
    var inkType: PKInkingTool.InkType? {
        switch self {
        case .pen: return .pen
        case .monoline, .fingering: return .monoline
        // A broad, constant-width translucent stroke gives PDF editors the same
        // geometry as our on-screen brush. PencilKit's textured marker uses a
        // private nib shape that cannot be represented faithfully by PDF InkList.
        case .marker: return .monoline
        default: return nil
        }
    }
    var widthRange: ClosedRange<Double> {
        switch self {
        case .marker: return 7.5...40
        case .monoline, .fingering: return 0.5...4
        default: return 1...12
        }
    }

    var widthPresets: [Double] {
        switch self {
        case .marker: return [8, 14, 24, 36]
        case .monoline, .fingering: return [0.5, 1, 2, 4]
        default: return [1, 2, 4, 8]
        }
    }
}

struct ScoreInkStyle: Codable, Equatable {
    var color: ScoreAnnotationColor
    var width: Double
    var opacity: Double

    static func initial(for tool: ScoreInkTool) -> Self {
        switch tool {
        case .marker: return .init(color: .init(.systemYellow), width: 14, opacity: 0.4)
        case .monoline, .fingering: return .init(color: .init(.black), width: 1.5, opacity: 1)
        default: return .init(color: .init(.systemRed), width: 2, opacity: 1)
        }
    }

    func validated(for tool: ScoreInkTool) -> Self {
        let fallback = Self.initial(for: tool)
        func unit(_ x: Double, fallback: Double) -> Double { x.isFinite ? min(1, max(0, x)) : fallback }
        return .init(color: .init(UIColor(red: unit(color.red, fallback: fallback.color.red),
                                          green: unit(color.green, fallback: fallback.color.green),
                                          blue: unit(color.blue, fallback: fallback.color.blue), alpha: 1)),
                     width: width.isFinite ? min(tool.widthRange.upperBound, max(tool.widthRange.lowerBound, width)) : fallback.width,
                     opacity: max(0.1, unit(opacity, fallback: fallback.opacity)))
    }

    func inkingTool(for tool: ScoreInkTool) -> PKInkingTool {
        let value = validated(for: tool)
        return PKInkingTool(tool.inkType ?? .pen, color: value.color.uiColor.withAlphaComponent(value.opacity), width: value.width)
    }
}

enum ScoreInkPalette {
    // Keep the original first three indices compatible with existing callers.
    static let colors: [UIColor] = [.systemRed, .systemBlue, .black, .systemGreen, .systemPurple, .systemYellow, .systemOrange, .gray]
    static let names = ["score.red", "score.blue", "score.black", "score.green", "score.purple", "score.yellow", "score.orange", "score.gray"]
    static let defaultsKey = "score.inkPalette.v1"
    static var initialPresets: [ScoreAnnotationColor] { Array(colors.prefix(6)).map(ScoreAnnotationColor.init) }

    static func validated(_ saved: [ScoreAnnotationColor]) -> [ScoreAnnotationColor] {
        initialPresets.enumerated().map { index, fallback in
            guard saved.indices.contains(index) else { return fallback }
            let color = saved[index]
            guard [color.red, color.green, color.blue].allSatisfy({ $0.isFinite && (0...1).contains($0) }) else { return fallback }
            return color
        }
    }

    static func label(for color: ScoreAnnotationColor) -> String {
        if let index = colors.firstIndex(where: { ScoreAnnotationColor($0) == color }) {
            return names[index].localized
        }
        return String(format: "#%02X%02X%02X", Int((color.red * 255).rounded()), Int((color.green * 255).rounded()), Int((color.blue * 255).rounded()))
    }
}
