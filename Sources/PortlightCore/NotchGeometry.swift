import Foundation
import CoreGraphics

public enum NotchPhase: Sendable { case idle, hover, expanded }

/// Screen coordinates are points, with origin at the lower left (also on displays left of the main display).
public struct NotchGeometry {
    public let screen: CGRect
    public let topInset: CGFloat
    public let centerX: CGFloat
    public let notchWidth: CGFloat
    public init(screen: CGRect, topInset: CGFloat, leftAreaMaxX: CGFloat, rightAreaMinX: CGFloat) {
        self.screen = screen; self.topInset = topInset
        centerX = (leftAreaMaxX + rightAreaMinX) / 2
        notchWidth = max(1, rightAreaMinX - leftAreaMaxX)
    }
    public var physicalCutout: CGRect {
        CGRect(x: centerX - notchWidth / 2, y: screen.maxY - topInset, width: notchWidth, height: topInset)
    }
    public func contentFrame(_ phase: NotchPhase) -> CGRect {
        let window = frame(phase)
        return CGRect(x: window.minX, y: window.minY, width: window.width, height: window.height - topInset)
    }
    /// Only the cutout footprint and a six-point lip beneath it activate the compact control.
    /// Idle and hover share a frame, so hovering never reaches down into browser tabs.
    public var activationFrame: CGRect {
        CGRect(x: physicalCutout.minX, y: physicalCutout.minY - 6,
               width: notchWidth, height: topInset + 6)
    }
    public func containsActivationPoint(_ point: CGPoint) -> Bool {
        let area = activationFrame
        // A pointer pushed against the physical top edge may report exactly screen.maxY.
        return point.x >= area.minX && point.x < area.maxX && point.y >= area.minY && point.y <= area.maxY
    }
    public func frame(_ phase: NotchPhase) -> CGRect {
        let width: CGFloat = phase == .expanded ? 432 : notchWidth + 12
        let bodyHeight: CGFloat = phase == .expanded ? 568 : 6
        let height = topInset + bodyHeight
        return CGRect(x: min(max(centerX - width / 2, screen.minX), screen.maxX - width),
                      y: screen.maxY - height, width: width, height: height)
    }
}
