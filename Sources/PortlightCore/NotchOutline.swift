import CoreGraphics

/// A cutout attached to the screen edge: concave shoulders, vertical walls,
/// convex bottom corners. One path topology is used throughout the resize.
public enum NotchOutline {
    public static func path(in rect: CGRect, shoulderRadius: CGFloat = 8, bottomRadius: CGFloat = 22) -> CGPath {
        let path = CGMutablePath()
        guard rect.width > 0, rect.height > 0 else { return path }
        let shoulder = max(0, min(shoulderRadius, rect.width / 4, rect.height / 3))
        let bottom = max(0, min(bottomRadius, (rect.width - 2 * shoulder) / 2, rect.height - shoulder))
        let k: CGFloat = 0.5522847498307936
        let left = rect.minX, right = rect.maxX, top = rect.maxY, base = rect.minY
        let wallLeft = left + shoulder, wallRight = right - shoulder
        path.move(to: CGPoint(x: left, y: top))
        path.addCurve(to: CGPoint(x: wallLeft, y: top - shoulder),
                      control1: CGPoint(x: left + shoulder * k, y: top),
                      control2: CGPoint(x: wallLeft, y: top - shoulder + shoulder * k))
        path.addLine(to: CGPoint(x: wallLeft, y: base + bottom))
        path.addCurve(to: CGPoint(x: wallLeft + bottom, y: base),
                      control1: CGPoint(x: wallLeft, y: base + bottom * (1 - k)),
                      control2: CGPoint(x: wallLeft + bottom * (1 - k), y: base))
        path.addLine(to: CGPoint(x: wallRight - bottom, y: base))
        path.addCurve(to: CGPoint(x: wallRight, y: base + bottom),
                      control1: CGPoint(x: wallRight - bottom * (1 - k), y: base),
                      control2: CGPoint(x: wallRight, y: base + bottom * (1 - k)))
        path.addLine(to: CGPoint(x: wallRight, y: top - shoulder))
        path.addCurve(to: CGPoint(x: right, y: top),
                      control1: CGPoint(x: wallRight, y: top - shoulder + shoulder * k),
                      control2: CGPoint(x: right - shoulder * k, y: top))
        path.closeSubpath()
        return path
    }

    public static func surfacePath(in bounds: CGRect, topInset: CGFloat) -> CGPath {
        let bodyHeight = bounds.height - topInset
        let progress = max(0, min(1, (bodyHeight - 6) / (568 - 6)))
        let baseInset = 6 * progress
        let shape = CGRect(x: bounds.minX, y: bounds.minY + baseInset,
                           width: bounds.width, height: max(0, bounds.height - baseInset))
        // The six-point shoulder makes the compact vertical walls exactly match
        // the measured cutout (window width = notch width + 12). No narrow stem.
        return path(in: shape, shoulderRadius: 6, bottomRadius: 8 + 14 * progress)
    }
}
