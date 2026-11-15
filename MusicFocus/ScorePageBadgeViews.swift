import PDFKit
import PencilKit
import SwiftUI
import Combine

/// Only the visible tags receive touches. Blank space passes through to PDFKit,
/// preserving its scrolling, pinch gestures, Pencil navigation and keyboard focus.
final class ScorePageBadgeLayer: UIView {
    var onTap: ((Int) -> Void)?
    private var badges: [Int: ScorePageBadgeView] = [:]
    override init(frame: CGRect) {
        super.init(frame: frame)
        clipsToBounds = true
        isAccessibilityElement = false
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func update(_ placements: [Int: (ScorePageBadgeInfo, CGRect)]) {
        for page in Array(badges.keys) where placements[page] == nil {
            badges.removeValue(forKey: page)?.removeFromSuperview()
        }
        for (page, (info, rect)) in placements {
            let badge: ScorePageBadgeView
            if let existing = badges[page] { badge = existing }
            else {
                badge = ScorePageBadgeView()
                badge.accessibilityIdentifier = "scorePageBadge-\(page)"
                badge.addAction(UIAction { [weak self] _ in self?.onTap?(page) }, for: .touchUpInside)
                badges[page] = badge
                addSubview(badge)
            }
            badge.configure(info)
            let size = badge.fittingSize
            badge.frame = CGRect(x: rect.maxX - size.width - 8, y: rect.minY + 8, width: size.width, height: size.height)
            badge.isHidden = !bounds.intersects(badge.frame)
        }
        accessibilityElements = badges.keys.sorted().compactMap { page in
            badges[page].flatMap { $0.isHidden ? nil : $0 }
        }
    }

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard !isHidden, isUserInteractionEnabled, bounds.contains(point) else { return nil }
        for badge in badges.values where !badge.isHidden && badge.frame.insetBy(dx: -6, dy: -6).contains(point) {
            return badge
        }
        return nil
    }
}

/// Compact translucent tag: heat dot + "Yesterday · 1h 30m  ♩30m".
final class ScorePageBadgeView: UIControl {
    private let dot = UIView()
    private let label = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = UIColor.systemBackground.withAlphaComponent(0.82)
        layer.cornerRadius = 9
        layer.borderWidth = 0.5
        layer.borderColor = UIColor.separator.cgColor
        dot.layer.cornerRadius = 4
        label.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        label.textColor = .secondaryLabel
        for view in [dot, label] { view.isUserInteractionEnabled = false; addSubview(view) }
        isAccessibilityElement = true
        accessibilityTraits = .button
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (view: ScorePageBadgeView, _: UITraitCollection) in
            view.layer.borderColor = UIColor.separator.resolvedColor(with: view.traitCollection).cgColor
        }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(_ info: ScorePageBadgeInfo) {
        label.text = info.text
        accessibilityLabel = info.accessibilityLabel
        dot.backgroundColor = UIColor { traits in
            guard info.level > 0 else { return .systemGray4 }
            let ramp = traits.userInterfaceStyle == .dark ? ScorePageHeatmap.darkRamp : ScorePageHeatmap.lightRamp
            let value = UInt32(ramp[info.level - 1].dropFirst(), radix: 16) ?? 0
            return UIColor(red: CGFloat(value >> 16 & 0xff) / 255, green: CGFloat(value >> 8 & 0xff) / 255,
                           blue: CGFloat(value & 0xff) / 255, alpha: 1)
        }
        setNeedsLayout()
    }

    var fittingSize: CGSize {
        let text = label.intrinsicContentSize
        return CGSize(width: ceil(8 + 8 + 5 + text.width + 9), height: max(18, ceil(text.height + 6)))
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        dot.frame = CGRect(x: 8, y: (bounds.height - 8) / 2, width: 8, height: 8)
        label.frame = CGRect(x: 21, y: 0, width: bounds.width - 21 - 8, height: bounds.height)
    }

}
