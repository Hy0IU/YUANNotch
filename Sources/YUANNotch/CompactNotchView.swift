import SwiftUI

struct CompactNotchView: View {
    let layout: NotchLayout
    var onTap: (() -> Void)? = nil

    var body: some View {
        Image(systemName: "note.text")
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.white.opacity(0.82))
            .frame(width: layout.compactSize.width, height: layout.compactSize.height)
            .background(Color(red: 0.02, green: 0.02, blue: 0.025).opacity(0.98))
            .clipShape(NotchShape(topCornerRadius: 0, bottomCornerRadius: 12))
            .overlay(
                NotchShape(topCornerRadius: 0, bottomCornerRadius: 12)
                    .stroke(.white.opacity(0.09), lineWidth: 1)
            )
            .contentShape(Rectangle())
            .onTapGesture { onTap?() }
            .pointingHandCursor()
    }
}

