import AppKit
import QuartzCore
import CoreImage

/// Hover-only, compositor-driven light. No timer or redraw loop when the notch is idle.
final class NotchLighting {
    let layer = CALayer()
    private let halo = CALayer()
    private let haloColors = CAGradientLayer()
    private let edgeColors = CAGradientLayer()
    private let haloMask = CAShapeLayer()
    private let edgeMask = CAShapeLayer()
    private let haloContent = CALayer()
    private let edgeContent = CALayer()
    init() {
        layer.opacity = 0; layer.masksToBounds = true
        let palette: [CGColor] = [
            NSColor(calibratedRed: 0.35, green: 0.72, blue: 1, alpha: 1).cgColor,
            NSColor(calibratedRed: 0.62, green: 0.47, blue: 1, alpha: 1).cgColor,
            NSColor(calibratedRed: 0.95, green: 0.49, blue: 0.75, alpha: 1).cgColor,
            NSColor(calibratedRed: 1, green: 0.73, blue: 0.59, alpha: 1).cgColor,
            NSColor(calibratedRed: 0.35, green: 0.72, blue: 1, alpha: 1).cgColor
        ]
        for gradient in [haloColors, edgeColors] {
            gradient.type = .conic; gradient.colors = palette
            gradient.locations = [0, 0.25, 0.5, 0.75, 1]
            gradient.startPoint = CGPoint(x: 0.5, y: 0.5); gradient.endPoint = CGPoint(x: 1, y: 0.5)
        }
        for mask in [haloMask, edgeMask] {
            mask.fillColor = nil; mask.strokeColor = NSColor.white.cgColor
            mask.lineCap = .round; mask.lineJoin = .round
        }
        edgeMask.lineWidth = 1.25; haloMask.lineWidth = 5
        haloContent.addSublayer(haloColors); haloContent.mask = haloMask
        halo.addSublayer(haloContent); halo.opacity = 0.24
        if let blur = CIFilter(name: "CIGaussianBlur") {
            blur.setValue(3, forKey: kCIInputRadiusKey); halo.filters = [blur]
        }
        edgeContent.addSublayer(edgeColors); edgeContent.mask = edgeMask
        layer.addSublayer(halo); layer.addSublayer(edgeContent)
    }
    func layout(contentBounds: CGRect, outline: CGPath, scale: CGFloat) {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        layer.frame = contentBounds
        let rect = layer.bounds
        halo.frame = rect; haloContent.frame = rect; edgeContent.frame = rect
        let side = max(rect.width, rect.height) * 2
        let gradientFrame = CGRect(x: rect.midX - side / 2, y: rect.midY - side / 2, width: side, height: side)
        haloColors.frame = gradientFrame; edgeColors.frame = gradientFrame
        for mask in [haloMask, edgeMask] { mask.frame = rect; mask.contentsScale = scale }
        // The hover edge follows the same cutout outline as the black body.
        // The parent clips it to the visible lip below the hardware notch.
        haloMask.path = outline; edgeMask.path = outline
        CATransaction.commit()
    }
    func setActive(_ value: Bool, animated: Bool) {
        let reduced = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let oldOpacity = layer.presentation()?.opacity ?? layer.opacity
        CATransaction.begin(); CATransaction.setDisableActions(true)
        layer.opacity = value ? 0.9 : 0
        CATransaction.commit()
        if animated && !reduced {
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = oldOpacity; fade.toValue = layer.opacity; fade.duration = value ? 0.16 : 0.18
            layer.add(fade, forKey: "visibility")
        }
        for gradient in [haloColors, edgeColors] {
            if value && animated && !reduced {
                if gradient.animation(forKey: "flow") == nil {
                    let rotation = CABasicAnimation(keyPath: "transform.rotation.z")
                    rotation.fromValue = 0; rotation.toValue = 2 * Double.pi; rotation.duration = 7
                    rotation.repeatCount = .infinity; rotation.timingFunction = CAMediaTimingFunction(name: .linear)
                    gradient.add(rotation, forKey: "flow")
                }
            } else { gradient.removeAnimation(forKey: "flow") }
        }
    }
}
