import SwiftUI

/// A derived preview only. Parsing, manual overrides and the captured absolute
/// due date stay with the composer when the drawer discards this view.
struct ReminderInputPreview: View {
    @ObservedObject var composer: ReminderComposer

    var body: some View {
        if composer.usesLiteralInput {
            row(symbol: "text.alignleft", text: "按原文创建", isWarning: false, actionTitle: "恢复识别") {
                composer.setLiteralInput(false)
            }
        } else if let issue = composer.inputIssue {
            row(symbol: "exclamationmark.circle", text: issue, isWarning: true, actionTitle: "按原文") {
                composer.setLiteralInput(true)
            }
        } else if let match = composer.inputMatch {
            row(symbol: "sparkle", text: "将创建：\(match.title)", isWarning: false, actionTitle: "按原文") {
                composer.setLiteralInput(true)
            }
        }
    }

    private func row(
        symbol: String,
        text: String,
        isWarning: Bool,
        actionTitle: String,
        action: @escaping () -> Void
    ) -> some View {
        HStack(alignment: .center, spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.orange.opacity(isWarning ? 0.95 : 0.7))
            Text(text)
                .appText(.secondary)
                .foregroundStyle(.white.opacity(isWarning ? 0.72 : 0.52))
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .help(text)
            Button(actionTitle, action: action)
                .appText(.compact)
                .foregroundStyle(.orange.opacity(0.85))
                .buttonStyle(.plain)
                .fixedSize()
                .help(composer.usesLiteralInput ? "恢复自动日期识别" : "保留完整原文，不使用自动识别的日期")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 7).fill(.orange.opacity(isWarning ? 0.08 : 0.035)))
    }
}
