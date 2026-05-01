import SwiftUI

/// 换底牌轻量信息栏（嵌入 southArea 顶部，不遮挡手牌）
struct KittyInfoBar: View {
    let selectedCount: Int
    let onConfirm: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "tray.and.arrow.down.fill")
                .font(.caption)
                .foregroundColor(.yellow)

            Text("选 8 张压底牌")
                .font(.system(size: 12))
                .foregroundColor(.white.opacity(0.8))

            Text("\(selectedCount)/8")
                .font(.system(size: 13, weight: .bold))
                .foregroundColor(selectedCount == 8 ? .green : .orange)

            Spacer()

            Button(action: onConfirm) {
                HStack(spacing: 5) {
                    Image(systemName: "checkmark.circle.fill").font(.caption)
                    Text("确认换底").font(.caption.bold())
                }
                .foregroundColor(.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                .background(selectedCount == 8 ? Color.blue : Color.gray.opacity(0.4))
                .clipShape(Capsule())
            }
            .disabled(selectedCount != 8)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .background(Color.black.opacity(0.40))
    }
}
