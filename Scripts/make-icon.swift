#!/usr/bin/env swift
// 把一张方形图片做成 macOS App 图标母版（1024×1024 PNG，透明底）。
//
//   swift Scripts/make-icon.swift <源图.png|.svg> <输出.png> [--panel]
//
// 源图是 .svg 时会先按 1024 矢量光栅化（NSImage 支持 SVG rep），不走放大滤镜，
// 边缘干净、没有锯齿；位图源才用 Lanczos 放大。
//
// 默认输出透明背景，只把图形放大居中——Dock 里就是图形本身，没有底板。
// 加 --panel 才画 Apple 那套白色圆角底板（想要「卡片感」时用）。
//
// 放大走 CoreImage 的 Lanczos + 轻度锐化，比 NSImage 直接 draw 清晰；
// 全程在 AppKit 里做，alpha 通道不会像 ffmpeg 滤镜链那样被压成黑底。

import AppKit
import CoreImage
import Foundation

let args = CommandLine.arguments
guard args.count >= 3 else {
    FileHandle.standardError.write("用法: make-icon.swift <源图> <输出> [--panel]\n".data(using: .utf8)!)
    exit(2)
}
let sourcePath = args[1]
let outputPath = args[2]
let wantsPanel = args.contains("--panel")

let canvas = 1024
let canvasSide = CGFloat(canvas)

guard let sourceImage = NSImage(contentsOf: URL(fileURLWithPath: sourcePath)) else {
    FileHandle.standardError.write("读不到源图: \(sourcePath)\n".data(using: .utf8)!)
    exit(1)
}

let isVector = sourcePath.lowercased().hasSuffix(".svg")

/// 把矢量图按目标尺寸直接光栅化（保持清晰度），位图源不需要这步。
func rasterize(_ image: NSImage, to side: CGFloat) -> CGImage? {
    let pixels = Int(side.rounded())
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    ) else { return nil }
    rep.size = NSSize(width: side, height: side)

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    if let c = NSGraphicsContext.current?.cgContext {
        c.setShouldAntialias(true)
        c.interpolationQuality = .high
        c.clear(CGRect(x: 0, y: 0, width: side, height: side))
    }
    image.draw(in: CGRect(x: 0, y: 0, width: side, height: side),
               from: .zero, operation: .sourceOver, fraction: 1)
    NSGraphicsContext.restoreGraphicsState()
    return rep.cgImage
}

let sourceCG: CGImage
if isVector {
    guard let rendered = rasterize(sourceImage, to: canvasSide) else {
        FileHandle.standardError.write("SVG 光栅化失败: \(sourcePath)\n".data(using: .utf8)!)
        exit(1)
    }
    sourceCG = rendered
} else {
    guard let bitmap = sourceImage.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
        FileHandle.standardError.write("读不到源图: \(sourcePath)\n".data(using: .utf8)!)
        exit(1)
    }
    sourceCG = bitmap
}

// MARK: 1. 高质量放大源图

func upscale(_ image: CGImage, to side: CGFloat) -> CGImage {
    let ci = CIImage(cgImage: image)
    let scale = side / CGFloat(image.width)

    let lanczos = CIFilter(name: "CILanczosScaleTransform")!
    lanczos.setValue(ci, forKey: kCIInputImageKey)
    lanczos.setValue(scale, forKey: kCIInputScaleKey)
    lanczos.setValue(1.0, forKey: kCIInputAspectRatioKey)
    var output = lanczos.outputImage ?? ci

    let sharpen = CIFilter(name: "CISharpenLuminance")!
    sharpen.setValue(output, forKey: kCIInputImageKey)
    sharpen.setValue(0.45, forKey: kCIInputSharpnessKey)
    output = sharpen.outputImage ?? output

    let context = CIContext(options: [.useSoftwareRenderer: false])
    guard let result = context.createCGImage(output, from: output.extent) else { return image }
    return result
}

let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: canvas, pixelsHigh: canvas,
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
)!
rep.size = NSSize(width: canvas, height: canvas)

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let ctx = NSGraphicsContext.current!.cgContext
ctx.setShouldAntialias(true)
ctx.interpolationQuality = .high
ctx.clear(CGRect(x: 0, y: 0, width: canvas, height: canvas))

if wantsPanel {
    // Apple 的图标网格：1024 画布里圆角矩形占 824，四周留 100 给投影。
    let tileInset: CGFloat = 100
    let tile = CGRect(
        x: tileInset, y: tileInset,
        width: canvasSide - tileInset * 2, height: canvasSide - tileInset * 2
    )

    ctx.saveGState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.22)
    shadow.shadowBlurRadius = 26
    shadow.shadowOffset = NSSize(width: 0, height: -10)
    shadow.set()
    NSColor.white.setFill()
    squirclePath(in: tile).fill()
    ctx.restoreGState()

    ctx.saveGState()
    squirclePath(in: tile).addClip()
    NSGradient(colors: [
        NSColor(calibratedRed: 1.0, green: 1.0, blue: 1.0, alpha: 1),
        NSColor(calibratedRed: 0.957, green: 0.953, blue: 0.941, alpha: 1),
    ])!.draw(in: tile, angle: -90)
    ctx.restoreGState()
}

// MARK: 2. 放图

// 透明底时图形铺到 92%（贴边会被 Dock 的圆角托盘切掉）；
// 有白色底板时收进底板里。
let fillFactor: CGFloat = 0.86
let artSide = wantsPanel ? (canvasSide - 200) * 0.68 : canvasSide * fillFactor
let artRect = CGRect(
    x: (canvasSide - artSide) / 2,
    y: (canvasSide - artSide) / 2,
    width: artSide, height: artSide
)
// 先裁掉源图四周的透明边，图形才真的能铺满画布——
// 否则 Dock 的玻璃托盘会在图形外露一圈灰边。
let tight = trimTransparent(sourceCG)
let art = upscale(tight, to: artSide)
ctx.draw(art, in: artRect)

NSGraphicsContext.restoreGraphicsState()

guard let data = rep.representation(using: .png, properties: [:]) else {
    FileHandle.standardError.write("PNG 编码失败\n".data(using: .utf8)!)
    exit(1)
}
try data.write(to: URL(fileURLWithPath: outputPath))
print("wrote \(outputPath) (\(canvas)×\(canvas), \(wantsPanel ? "白底" : "透明底"))")

/// 裁掉四周全透明的像素。
func trimTransparent(_ image: CGImage) -> CGImage {
    let width = image.width, height = image.height
    guard let data = CFDataGetBytePtr(image.dataProvider?.data) else { return image }
    let bytesPerRow = image.bytesPerRow
    let alphaOffset: Int = {
        switch image.alphaInfo {
        case .premultipliedFirst, .first, .noneSkipFirst: return 0
        default: return 3
        }
    }()

    var minX = width, minY = height, maxX = -1, maxY = -1
    for y in 0..<height {
        for x in 0..<width {
            let alpha = data[y * bytesPerRow + x * 4 + alphaOffset]
            if alpha > 8 {
                if x < minX { minX = x }
                if x > maxX { maxX = x }
                if y < minY { minY = y }
                if y > maxY { maxY = y }
            }
        }
    }
    guard maxX > minX, maxY > minY else { return image }
    let rect = CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
    return image.cropping(to: rect) ?? image
}

/// 超椭圆（squircle）：|x/a|^n + |y/b|^n = 1，n≈4.6 接近 macOS 的连续曲率。
func squirclePath(in rect: CGRect, n: CGFloat = 4.6, segments: Int = 720) -> NSBezierPath {
    let path = NSBezierPath()
    let a = rect.width / 2, b = rect.height / 2
    let cx = rect.midX, cy = rect.midY
    for i in 0...segments {
        let t = CGFloat(i) / CGFloat(segments) * 2 * .pi
        let ct = cos(t), st = sin(t)
        let x = cx + a * copysign(pow(abs(ct), 2 / n), ct)
        let y = cy + b * copysign(pow(abs(st), 2 / n), st)
        if i == 0 { path.move(to: NSPoint(x: x, y: y)) } else { path.line(to: NSPoint(x: x, y: y)) }
    }
    path.close()
    return path
}
