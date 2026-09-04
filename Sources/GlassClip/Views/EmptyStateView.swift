// EmptyStateView.swift — 通用空态占位视图。
//
// 面板列表（"Nothing here yet"/"No matches"）与预览分栏
// （"Image unavailable"）共用同一视觉：图标 + 标题 + 副标题，
// 居中、弱化配色，撑满可用空间。

import SwiftUI

/// 空态占位：标题 + 副标题 + 品牌图标。
struct EmptyStateView: View {
    /// 主标题（一行）。
    let title: String
    /// 副标题（可含换行，居中多行排布，行距略放宽）。
    let subtitle: String

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "list.clipboard")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(.quaternary)
            Text(title)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.secondary)
            Text(subtitle)
                .font(.system(size: 12))
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .lineSpacing(3)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
