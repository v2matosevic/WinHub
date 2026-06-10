import SwiftUI

/// The notch silhouette: flares out to full width at the very top so it meets
/// the menu bar like the real cutout, and rounds the bottom corners. The body
/// of the shape is inset by `topRadius` on each side; callers size the frame
/// `2 × topRadius` wider than the area they want fully covered.
struct NotchShape: Shape {
    var topRadius: CGFloat
    var bottomRadius: CGFloat

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(topRadius, bottomRadius) }
        set {
            topRadius = newValue.first
            bottomRadius = newValue.second
        }
    }

    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.minY))
        p.addQuadCurve(to: CGPoint(x: rect.minX + topRadius, y: rect.minY + topRadius),
                       control: CGPoint(x: rect.minX + topRadius, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.minX + topRadius, y: rect.maxY - bottomRadius))
        p.addQuadCurve(to: CGPoint(x: rect.minX + topRadius + bottomRadius, y: rect.maxY),
                       control: CGPoint(x: rect.minX + topRadius, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.maxX - topRadius - bottomRadius, y: rect.maxY))
        p.addQuadCurve(to: CGPoint(x: rect.maxX - topRadius, y: rect.maxY - bottomRadius),
                       control: CGPoint(x: rect.maxX - topRadius, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.maxX - topRadius, y: rect.minY + topRadius))
        p.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.minY),
                       control: CGPoint(x: rect.maxX - topRadius, y: rect.minY))
        p.closeSubpath()
        return p
    }
}
