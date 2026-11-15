import PencilKit

/// A request owns its recognizer: one request cannot replace another drawing
/// while PencilKit is suspended inside recognizedText(). All work stays local.
@available(iOS 27.0, *)
struct ScoreAppleDigitRecognizer: Sendable {
    static var isSupported: Bool { !PKStrokeRecognizer.supportedLanguages.isEmpty }
    private let native: PKStrokeRecognizer

    init() {
        let english = PKStrokeRecognizer.supportedLanguages.filter { $0.languageCode?.identifier == "en" }
        native = PKStrokeRecognizer(preferredLanguages: english.isEmpty ? nil : [Locale.Language(identifier: "en-US")])
    }

    /// Candidate ink only; the PDF and neighboring printed notation are excluded.
    /// Called from the controller's cancellable utility worker.
    func recognize(_ strokes: [PKStroke]) async -> String? {
        guard !Task.isCancelled, (1...4).contains(strokes.count) else { return nil }
        let paths = strokes.map { ScoreFingeringBeautifier.samples($0, count: 96) }
        let points = paths.flatMap { $0 }
        guard (2...4096).contains(points.count), points.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else { return nil }
        let box = points.reduce(CGRect.null) { $0.union(CGRect(origin: $1, size: .zero)) }
        guard box.height.isFinite, box.width.isFinite, box.height > 0.001,
              box.width >= 0, box.width < box.height*1.5 else { return nil }
        let scale = 32 / box.height
        let normalized = PKDrawing(strokes: paths.enumerated().map { index, path in
            let points = path.enumerated().map { i, point in
                PKStrokePoint(location: CGPoint(x: 20+(point.x-box.minX)*scale,
                                               y: 20+(point.y-box.minY)*scale),
                              timeOffset: Double(i)*0.01, size: CGSize(width: 1.5, height: 1.5),
                              opacity: 1, force: 1, azimuth: 0, altitude: .pi/2)
            }
            return PKStroke(ink: PKInk(.pen, color: .black), path: PKStrokePath(
                controlPoints: points, creationDate: Date(timeIntervalSinceReferenceDate: Double(index))))
        })
        await native.updateDrawing(normalized)
        guard !Task.isCancelled else { return nil }
        let text = await native.recognizedText()
        return Task.isCancelled ? nil : text
    }
}
