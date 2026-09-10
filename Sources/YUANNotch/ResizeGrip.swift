import SwiftUI

struct ResizeGrip: View {
    var body: some View {
        Canvas { context, size in
            let dotSize: CGFloat = 2.5
            let spacing: CGFloat = 5
            for row in 0..<3 {
                for col in 0..<3 where row + col >= 2 {
                    let x = size.width - CGFloat(3 - col) * spacing
                    let y = size.height - CGFloat(3 - row) * spacing
                    let rect = CGRect(x: x, y: y, width: dotSize, height: dotSize)
                    context.fill(Path(ellipseIn: rect), with: .color(.white.opacity(0.25)))
                }
            }
        }
        .frame(width: 16, height: 16)
        .contentShape(Rectangle())
    }
}
