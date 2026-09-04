// ColorSwatch.swift — 色块描边的共享实现（列表行标识与预览分栏共用）。
//
// 两处大色块原本是复制粘贴：同一个圆角半径各写两遍（fill 一次、描边一次），
// 描边参数（不带 style 的 RoundedRectangle + Color.primary.opacity(0.1)）也重复一遍。
// 收成 View 扩展而不是 ColorSwatch 组件，是为了不动调用点的修饰符顺序：
// PreviewPane 那处是 fill → aspectRatio → overlay，封装成组件会把 overlay 提前，
// 那就不是行为不变的搬运了。
//
// 两个刻意保留的原样：
// - 描边矩形不带 style（默认 .circular），与外层 fill 的 .continuous 不一致——
//   这是原实现的观感，不在消重时顺手修齐；
// - 两处对"hex 解析失败"的回落色不同（行用 controlAccentColor、预览用 gray），
//   那是已登记的不一致，仍由调用方各自决定。

import SwiftUI

extension View {
    /// 叠一圈与色块同圆角的主色描边。半径要与外层 fill 的那个传同一个值。
    func swatchStroke(cornerRadius: CGFloat) -> some View {
        overlay(RoundedRectangle(cornerRadius: cornerRadius).strokeBorder(Color.primary.opacity(0.1)))
    }
}
