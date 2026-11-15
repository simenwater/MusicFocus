import PDFKit
import PencilKit
import XCTest
@testable import MusicFocus

final class ScorePedalEditingTests: XCTestCase {
    private final class PageKey: UIKey {
        let code: UIKeyboardHIDUsage
        init(_ code: UIKeyboardHIDUsage) { self.code = code; super.init() }
        required init?(coder: NSCoder) { fatalError("test key") }
        override var keyCode: UIKeyboardHIDUsage { code }
        override var modifierFlags: UIKeyModifierFlags { [] }
        override var characters: String { "" }
        override var charactersIgnoringModifiers: String { "" }
    }
    private final class PagePress: UIPress {
        let pageKey: UIKey
        init(_ code: UIKeyboardHIDUsage) { pageKey = PageKey(code); super.init() }
        override var key: UIKey? { pageKey }
    }

    @MainActor
    func testDedicatedPageHIDKeysTurnOnceAndKeepModifiedShortcuts() {
        let pdf = ScorePDFViewport(), canvas = ScoreCanvas(pageNumber: 1)
        var turns: [Int] = []
        pdf.onPageKey = { turns.append($0) }
        canvas.onPageKey = { turns.append($0) }
        for view in [pdf as UIView, canvas] {
            let down: Set<UIPress> = [PagePress(.keyboardPageDown)]
            let up: Set<UIPress> = [PagePress(.keyboardPageUp)]
            view.pressesBegan(down, with: nil)
            view.pressesEnded(down, with: nil)
            view.pressesBegan(up, with: nil)
            view.pressesCancelled(up, with: nil)
        }
        XCTAssertEqual(turns, [1, -1, 1, -1], "Key-up/cancellation never turns a second page")
        for modifiers: UIKeyModifierFlags in [.command, .control, .alternate, .shift] {
            XCTAssertNil(ScorePageKeys.direction(for: .keyboardPageDown, modifiers: modifiers))
            XCTAssertNil(ScorePageKeys.direction(for: .keyboardPageUp, modifiers: modifiers))
        }
        XCTAssertEqual(ScorePageKeys.direction(for: .keyboardPageDown, modifiers: .numericPad), 1)
        XCTAssertNil(ScorePageKeys.direction(for: .keyboardA, modifiers: []))
    }

    @MainActor
    func testCanvasFocusKeepsPedalsThroughEveryDrawingToolAndDetach() async throws {
        let device = try await ScoreSyncFixture.Device(pdf: ScoreSyncFixture.pdf(pages: 3))
        defer { device.cleanUp() }
        let suite = "PedalEditing-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let reader = ScoreReaderController(inkDefaults: defaults)
        await reader.load(score: device.score, disk: device.disk)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene), host = UIViewController()
        window.rootViewController = host; window.makeKeyAndVisible()
        defer { reader.detach(); window.isHidden = true }
        let pdf = ScorePDFViewport(frame: CGRect(x: 0, y: 70, width: 600, height: 730))
        host.view.addSubview(pdf); reader.attach(pdf); reader.editing = true
        try await Task.sleep(for: .milliseconds(300))
        let document = try XCTUnwrap(reader.document)
        var turns = 0
        reader.onUserNavigation = { turns += 1 }
        var retainedCanvases: [ScoreCanvas] = []
        for tool in [ScoreInkTool.pen, .monoline, .marker, .eraser, .fingering] {
            reader.tool = tool
            for (input, current, expected) in [(UIKeyCommand.inputDownArrow, 1, 2), (UIKeyCommand.inputUpArrow, 2, 1)] {
                let page = try XCTUnwrap(document.page(at: current - 1))
                let overlay = try XCTUnwrap(reader.pdfView(pdf, overlayViewFor: page) as? ScorePageOverlay)
                // PDFKit normally installs it. Explicitly attach if the fixture's viewport
                // hasn't displayed this page yet, so UIKit can give its canvas focus.
                if overlay.window == nil { pdf.addSubview(overlay) }
                let canvas = overlay.canvas
                retainedCanvases.append(canvas)
                XCTAssertTrue(canvas.becomeFirstResponder())
                XCTAssertTrue(canvas.isFirstResponder)
                for key in ScorePDFViewport.nextPageInputs + ScorePDFViewport.previousPageInputs {
                    let command = try XCTUnwrap(canvas.keyCommands?.first { $0.input == key && $0.modifierFlags.isEmpty })
                    XCTAssertTrue(command.wantsPriorityOverSystemBehavior)
                    XCTAssertTrue(canvas.canPerformAction(command.action!, withSender: command))
                }
                let command = try XCTUnwrap(canvas.keyCommands?.first { $0.input == input && $0.modifierFlags.isEmpty })
                let before = turns
                XCTAssertTrue(UIApplication.shared.sendAction(command.action!, to: nil, from: command, for: nil))
                try await Task.sleep(for: .milliseconds(150))
                XCTAssertEqual(turns, before + 1, "A canvas key must not also trigger the PDF's command")
                XCTAssertEqual(reader.pages.first, expected, "tool=\(tool), key=\(input)")
                XCTAssertTrue(canvas.undoManager === reader.undoBridge)
            }
        }
        let input = UITextField(frame: CGRect(x: 10, y: 10, width: 220, height: 44))
        host.view.addSubview(input)
        XCTAssertTrue(input.becomeFirstResponder())
        reader.chooseColor(.systemBlue); reader.chooseWidth(3)
        XCTAssertTrue(input.isFirstResponder, "Color entry keeps its keyboard focus")
        XCTAssertFalse(UIApplication.shared.sendAction(#selector(ScorePDFViewport.nextPageKey), to: nil, from: nil, for: nil))
        reader.focusKeys()
        XCTAssertTrue(pdf.isFirstResponder)
        reader.detach()
        XCTAssertFalse(pdf.canPerformAction(#selector(ScorePDFViewport.nextPageKey), withSender: nil))
        for canvas in retainedCanvases {
            XCTAssertNil(canvas.onPageKey)
            XCTAssertFalse(canvas.canPerformAction(#selector(ScoreCanvas.nextPageKey), withSender: nil))
        }
    }
}
