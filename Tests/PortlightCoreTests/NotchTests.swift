import Foundation
import CoreGraphics
import PortlightCore

final class NotchTests {
    func testOutlineHasConcaveShouldersAndKeepsMorphAnchored() {
        let rect = CGRect(x: 0, y: 0, width: 432, height: 600)
        let path = NotchOutline.path(in: rect)
        expectEqual(path.boundingBoxOfPath, rect)
        expectTrue(path.contains(CGPoint(x: rect.midX, y: 599)))
        // An ordinary rounded rectangle includes this point. A native notch's
        // inward shoulder leaves it transparent, then joins a vertical wall.
        expectFalse(path.contains(CGPoint(x: 4, y: 596)))
        expectTrue(path.contains(CGPoint(x: 9, y: 596)))
        expectFalse(path.contains(CGPoint(x: 5, y: 550)))
        expectTrue(path.contains(CGPoint(x: 9, y: 550)))
        expectFalse(path.contains(CGPoint(x: 428, y: 596)))
        expectTrue(path.contains(CGPoint(x: 423, y: 596)))
        expectFalse(path.contains(CGPoint(x: 9, y: 1)))
        expectTrue(path.contains(CGPoint(x: 40, y: 1)))
        expectTrue(path.contains(CGPoint(x: rect.midX, y: 1)))
        var topology: [Int]?
        for t: CGFloat in [0, 0.25, 0.5, 0.75, 1] {
            let bounds = CGRect(x: 0, y: 0, width: 197 + 235 * t, height: 38 + 562 * t)
            let shape = NotchOutline.surfacePath(in: bounds, topInset: 32)
            let box = shape.boundingBoxOfPath
            expectEqual(box.maxY, bounds.maxY)
            expectEqual(box.midX, bounds.midX)
            expectTrue(abs(box.minY - 6 * t) < 0.0001)
            expectEqual(box.minX, bounds.minX)
            expectTrue(shape.contains(CGPoint(x: bounds.midX, y: bounds.maxY - 1)))
            expectFalse(shape.contains(CGPoint(x: 3, y: bounds.maxY - 3)))
            expectTrue(shape.contains(CGPoint(x: 7, y: bounds.maxY - 3)))
            var types: [Int] = []
            shape.applyWithBlock { types.append(Int($0.pointee.type.rawValue)) }
            if let topology { expectEqual(types, topology) } else { topology = types }
        }
        expectTrue(NotchOutline.path(in: .zero).isEmpty)
    }
    func testGeometryKeepsEveryStateBelowCutout() {
        for origin in [CGPoint.zero, CGPoint(x: -1728, y: 300), CGPoint(x: 2000, y: -400)] {
            let screen = CGRect(origin: origin, size: CGSize(width: 1728, height: 1117))
            let geometry = NotchGeometry(screen: screen, topInset: 37, leftAreaMaxX: screen.midX - 100, rightAreaMinX: screen.midX + 100)
            for phase in [NotchPhase.idle, .hover, .expanded] {
                let frame = geometry.frame(phase)
                expectEqual(frame.maxY, screen.maxY)
                expectEqual(geometry.contentFrame(phase).maxY, screen.maxY - 37)
                expectFalse(geometry.contentFrame(phase).intersects(geometry.physicalCutout))
                expectEqual(frame.midX, screen.midX)
                expectTrue(screen.contains(frame))
            }
            expectEqual(geometry.frame(.idle), geometry.frame(.hover))
            expectEqual(geometry.contentFrame(.idle).height, 6)
            expectEqual(geometry.activationFrame.maxY, screen.maxY)
            expectEqual(geometry.activationFrame.minY, geometry.physicalCutout.minY - 6)
            expectEqual(geometry.activationFrame.width, geometry.notchWidth)
            expectTrue(geometry.frame(.idle).contains(geometry.activationFrame))
            expectTrue(geometry.activationFrame.contains(CGPoint(x: screen.midX, y: screen.maxY - 1)))
            expectTrue(geometry.activationFrame.contains(CGPoint(x: screen.midX, y: geometry.physicalCutout.minY - 3)))
            expectFalse(geometry.activationFrame.contains(CGPoint(x: screen.midX, y: geometry.physicalCutout.minY - 7)))
            expectFalse(geometry.activationFrame.contains(CGPoint(x: geometry.physicalCutout.minX - 1, y: screen.maxY - 1)))
            expectEqual(geometry.physicalCutout.midX, geometry.frame(.idle).midX)
            expectEqual(geometry.physicalCutout.width, 200)
            // Every row above the fixed lower edge is active, including the screen edge.
            for y in stride(from: geometry.activationFrame.minY, through: screen.maxY, by: 1) {
                expectTrue(geometry.containsActivationPoint(CGPoint(x: screen.midX, y: y)))
            }
            expectFalse(geometry.containsActivationPoint(CGPoint(x: screen.midX, y: geometry.activationFrame.minY - 0.5)))
            expectFalse(geometry.containsActivationPoint(CGPoint(x: screen.midX, y: screen.maxY + 0.5)))
            expectFalse(geometry.containsActivationPoint(CGPoint(x: geometry.activationFrame.maxX, y: screen.maxY)))
        }
    }
    func testOriginDoesNotUseProjectOrRuntimeNames() {
        for path in ["/project/codex-server.js", "/Projects/Codex/node", "/bin/python3", "/Apps/Codex Helper", "/bin/not-codex"] {
            expectFalse(AttributionPolicy.candidate(path))
        }
        expectTrue(AttributionPolicy.candidate("/somewhere/codex")) // prefilter only, never attribution
        let unknown = AttributionPolicy.classify(verifiedCodexPID: nil, chainValid: true)
        expectEqual(unknown.category, .other); expectFalse(unknown.verified)
        let stale = AttributionPolicy.classify(verifiedCodexPID: 42, chainValid: false)
        expectEqual(stale.category, .other); expectFalse(stale.verified)
        let verified = AttributionPolicy.classify(verifiedCodexPID: 42, chainValid: true)
        expectEqual(verified.category, .codex); expectTrue(verified.verified)
    }
}
