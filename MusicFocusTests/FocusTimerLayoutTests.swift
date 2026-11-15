import OSLog
import SwiftUI
import XCTest
@testable import MusicFocus

final class FocusTimerLayoutTests: XCTestCase {
    /// Navigation transitions can briefly propose zero or less than the 40-point
    /// horizontal inset. Render the real timer in both states, then check SwiftUI's
    /// runtime diagnostics; a successful build alone does not catch this warning.
    @MainActor
    func testTimerResizesThroughZeroWithoutInvalidFrameWarnings() throws {
        let start = Date()
        let suite = "FocusTimerLayout.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let manager = FocusManager(historyDefaults: defaults, settingsDefaults: defaults)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let previousWindow = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        let container = UIViewController()
        window.rootViewController = container
        window.makeKeyAndVisible()
        defer { window.isHidden = true; previousWindow?.makeKey() }

        for active in [false, true] {
            manager.currentSession = active ? FocusSession(startTime: Date(), distractions: []) : nil
            manager.isActive = active // No microphone or session persistence in this layout test.
            let host = UIHostingController(rootView: FocusTimerView(showsLibraryEntry: false)
                .environmentObject(manager).environmentObject(ScoreLibrary()))
            container.addChild(host)
            container.view.addSubview(host.view)
            host.didMove(toParent: container)
            for width in [0.0, 20, 39, 40, 375, 834, 1194, 0, 375] {
                host.view.frame = CGRect(x: 0, y: 0, width: width, height: 800)
                host.view.setNeedsLayout()
                host.view.layoutIfNeeded()
                RunLoop.main.run(until: Date().addingTimeInterval(0.04))
                XCTAssertTrue(host.view.bounds.width.isFinite)
                XCTAssertEqual(host.view.bounds.width, width)
            }
            host.willMove(toParent: nil)
            host.view.removeFromSuperview()
            host.removeFromParent()
        }
        manager.isActive = false
        manager.currentSession = nil

        // The marker proves the log query is working, so an empty log is not a pass.
        let marker = UUID().uuidString
        Logger(subsystem: "MusicFocus.LayoutTests", category: "validation").notice("Layout complete \(marker, privacy: .public)")
        RunLoop.main.run(until: Date().addingTimeInterval(0.25))
        let logs = try OSLogStore(scope: .currentProcessIdentifier)
        let messages = try logs.getEntries(at: logs.position(date: start)).compactMap {
            ($0 as? OSLogEntryLog)?.composedMessage
        }
        XCTAssertTrue(messages.contains { $0.contains(marker) }, "Runtime log capture must include its marker")
        XCTAssertFalse(messages.contains { $0.contains("Invalid frame dimension") },
                       "SwiftUI reported an invalid frame while the timer resized")
    }
}
