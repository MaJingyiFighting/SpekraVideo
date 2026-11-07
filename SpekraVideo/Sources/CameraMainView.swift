import SwiftUI
import UIKit

// MARK: - 原生 120Hz UIScrollView 磁力吸附触感刻度波轮（用于变焦、曝光补偿、快门、感光度、色温）

private final class TickStripCanvasView: UIView {
    var items: [String] = [] {
        didSet {
            if oldValue != items { setNeedsDisplay() }
        }
    }
    var tickSpacing: CGFloat = 22.0
    var sidePadding: CGFloat = 140.0

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = false
        backgroundColor = .clear
        contentMode = .redraw
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func draw(_ rect: CGRect) {
        guard let ctx = UIGraphicsGetCurrentContext(), !items.isEmpty else { return }
        let h = bounds.height
        let font = UIFont.monospacedSystemFont(ofSize: 9.5, weight: .semibold)
        let para = NSMutableParagraphStyle()
        para.alignment = .center

        for i in 0..<items.count {
            let x = sidePadding + CGFloat(i) * tickSpacing
            let isMajor = (i % 3 == 0) || (items.count <= 10)
            let tickH: CGFloat = isMajor ? 15.0 : 9.0
            let tickW: CGFloat = isMajor ? 1.6 : 1.0
            let alpha: CGFloat = isMajor ? 0.85 : 0.36

            ctx.setFillColor(UIColor(white: 1.0, alpha: alpha).cgColor)
            ctx.fill(CGRect(x: x - tickW * 0.5, y: h - tickH - 6.0, width: tickW, height: tickH))

            if isMajor {
                let attrs: [NSAttributedString.Key: Any] = [
                    .font: font,
                    .foregroundColor: UIColor(white: 1.0, alpha: 0.86),
                    .paragraphStyle: para
                ]
                let str = items[i] as NSString
                let labelRect = CGRect(x: x - 28.0, y: 4.0, width: 56.0, height: 13.0)
                str.draw(in: labelRect, withAttributes: attrs)
            }
        }
    }
}

private struct NativeScrollWheelRepresentable: UIViewRepresentable {
    let items: [String]
    let selectedIndex: Int
    let tickSpacing: CGFloat
    let onSelectIndex: (Int) -> Void

    final class Coordinator: NSObject, UIScrollViewDelegate {
        var parent: NativeScrollWheelRepresentable
        let feedback = UISelectionFeedbackGenerator()
        let canvas = TickStripCanvasView()
        weak var scrollView: UIScrollView?
        var lastEmittedIndex: Int = -1
        var isProgrammaticScroll: Bool = false
        var lastBoundsWidth: CGFloat = 0

        init(parent: NativeScrollWheelRepresentable) {
            self.parent = parent
            self.lastEmittedIndex = parent.selectedIndex
            super.init()
            feedback.prepare()
        }

        func layoutContentIfNeeded(in sv: UIScrollView) {
            let w = sv.bounds.width
            let h = sv.bounds.height
            guard w > 10, h > 10 else { return }
            let count = max(parent.items.count, 1)
            let sidePad = w * 0.5
            let totalW = sidePad * 2.0 + CGFloat(max(count - 1, 0)) * parent.tickSpacing

            let widthChanged = abs(w - lastBoundsWidth) > 0.5
            let itemsChanged = canvas.items != parent.items
            if widthChanged || itemsChanged || abs(canvas.frame.width - totalW) > 0.5 {
                lastBoundsWidth = w
                canvas.tickSpacing = parent.tickSpacing
                canvas.sidePadding = sidePad
                canvas.items = parent.items
                canvas.frame = CGRect(x: 0, y: 0, width: totalW, height: h)
                sv.contentSize = CGSize(width: totalW, height: h)
                canvas.setNeedsDisplay()

                let safeIdx = min(max(parent.selectedIndex, 0), count - 1)
                lastEmittedIndex = safeIdx
                isProgrammaticScroll = true
                sv.setContentOffset(CGPoint(x: CGFloat(safeIdx) * parent.tickSpacing, y: 0), animated: false)
                isProgrammaticScroll = false
            }
        }

        func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
            feedback.prepare()
        }

        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            guard !isProgrammaticScroll, !parent.items.isEmpty else { return }
            let rawIdx = Int(round(scrollView.contentOffset.x / parent.tickSpacing))
            let clamped = min(max(rawIdx, 0), parent.items.count - 1)
            if clamped != lastEmittedIndex {
                lastEmittedIndex = clamped
                feedback.selectionChanged()
                feedback.prepare()
                parent.onSelectIndex(clamped)
            }
        }

        func scrollViewWillEndDragging(
            _ scrollView: UIScrollView,
            withVelocity velocity: CGPoint,
            targetContentOffset: UnsafeMutablePointer<CGPoint>
        ) {
            guard !parent.items.isEmpty else { return }
            let maxIdx = CGFloat(max(parent.items.count - 1, 0))
            let targetIdx = min(max(round(targetContentOffset.pointee.x / parent.tickSpacing), 0), maxIdx)
            targetContentOffset.pointee.x = targetIdx * parent.tickSpacing
        }

        @objc func handleTap(_ recognizer: UITapGestureRecognizer) {
            guard recognizer.state == .ended,
                  let sv = scrollView,
                  !parent.items.isEmpty else { return }
            let loc = recognizer.location(in: canvas)
            let tappedIdx = Int(round((loc.x - canvas.sidePadding) / parent.tickSpacing))
            let clamped = min(max(tappedIdx, 0), parent.items.count - 1)
            if clamped != lastEmittedIndex {
                lastEmittedIndex = clamped
                feedback.selectionChanged()
                parent.onSelectIndex(clamped)
            }
            isProgrammaticScroll = true
            sv.setContentOffset(CGPoint(x: CGFloat(clamped) * parent.tickSpacing, y: 0), animated: true)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.22) { [weak self] in
                self?.isProgrammaticScroll = false
            }
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeUIView(context: Context) -> UIScrollView {
        let sv = UIScrollView()
        sv.showsHorizontalScrollIndicator = false
        sv.showsVerticalScrollIndicator = false
        sv.bounces = true
        sv.alwaysBounceHorizontal = true
        sv.decelerationRate = .fast
        sv.backgroundColor = .clear
        sv.delegate = context.coordinator
        sv.addSubview(context.coordinator.canvas)
        context.coordinator.scrollView = sv

        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleTap(_:)))
        sv.addGestureRecognizer(tap)
        return sv
    }

    func updateUIView(_ sv: UIScrollView, context: Context) {
        context.coordinator.parent = self
        DispatchQueue.main.async {
            context.coordinator.layoutContentIfNeeded(in: sv)
            guard !sv.isDragging, !sv.isDecelerating, !context.coordinator.isProgrammaticScroll else { return }
            let count = max(self.items.count, 1)
            let safeIdx = min(max(self.selectedIndex, 0), count - 1)
            let targetX = CGFloat(safeIdx) * self.tickSpacing
            if abs(sv.contentOffset.x - targetX) > 1.0 {
                context.coordinator.lastEmittedIndex = safeIdx
                context.coordinator.isProgrammaticScroll = true
                sv.setContentOffset(CGPoint(x: targetX, y: 0), animated: false)
                context.coordinator.isProgrammaticScroll = false
            }
        }
    }
}

private struct MagneticStopWheel: View {
    let title: String
    let items: [String]
    let selectedIndex: Int
    let isAuto: Bool
    let autoButtonLabel: String
    let accent: Color
    let onSelectIndex: (Int) -> Void
    let onTapAuto: () -> Void

    private let tickSpacing: CGFloat = 22.0

    var body: some View {
        let safeIdx = min(max(selectedIndex, 0), max(items.count - 1, 0))
        let currentVal = items.isEmpty ? "" : items[safeIdx]
        let readout = isAuto ? "\(title) · 自动 (\(currentVal))" : "\(title) · \(currentVal)"

        VStack(spacing: 4) {
            Text(readout)
                .font(.system(size: 12, weight: .bold, design: .monospaced))
                .foregroundColor(.white)
                .lineLimit(1)
                .padding(.horizontal, 12)
                .padding(.vertical, 4)
                .background(Color(white: 0.18).opacity(0.95), in: Capsule())
                .overlay(
                    Capsule()
                        .stroke(Color.white.opacity(0.16), lineWidth: 0.7)
                )

            HStack(spacing: 0) {
                ZStack {
                    NativeScrollWheelRepresentable(
                        items: items,
                        selectedIndex: safeIdx,
                        tickSpacing: tickSpacing,
                        onSelectIndex: onSelectIndex
                    )

                    VStack(spacing: 0) {
                        TrianglePointer()
                            .fill(accent)
                            .frame(width: 7, height: 4)
                        Rectangle()
                            .fill(accent)
                            .frame(width: 2.0, height: 18)
                    }
                    .offset(y: 9)
                    .allowsHitTesting(false)
                }
                .frame(height: 46)

                Rectangle()
                    .fill(Color.white.opacity(0.14))
                    .frame(width: 0.8, height: 34)

                Button(action: {
                    UISelectionFeedbackGenerator().selectionChanged()
                    onTapAuto()
                }) {
                    Text(autoButtonLabel)
                        .font(.system(size: 12, weight: .bold))
                        .foregroundColor(isAuto ? accent : .white.opacity(0.88))
                        .lineLimit(1)
                        .frame(width: 58, height: 46)
                        .background(isAuto ? accent.opacity(0.18) : Color.clear)
                }
            }
            .background(Color.black.opacity(0.82), in: RoundedRectangle(cornerRadius: 12))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(Color.white.opacity(0.14), lineWidth: 0.7)
            )
        }
    }
}

private struct TrianglePointer: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
        p.closeSubpath()
        return p
    }
}

// MARK: - iOS 原生相机风格快门上方焦段圆环 (.5 / 1× / 2 / 5) + 半圆弧形刻度变焦转盘

private final class ArcZoomWheelCanvasView: UIView {
    var currentZoom: Float = 1.0 {
        didSet {
            if abs(oldValue - currentZoom) > 0.001 { setNeedsDisplay() }
        }
    }
    var minZoom: Float = 0.5
    var maxZoom: Float = 15.0
    var teleZoom: Float = 5.0

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = false
        backgroundColor = .clear
        contentMode = .redraw
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    static let degreesPerOctave: CGFloat = 25.0

    func angleDegrees(for zoom: Float) -> CGFloat {
        let lCur = CGFloat(log2(max(currentZoom, 0.1)))
        let lVal = CGFloat(log2(max(zoom, 0.1)))
        return (lVal - lCur) * Self.degreesPerOctave
    }

    override func draw(_ rect: CGRect) {
        guard let ctx = UIGraphicsGetCurrentContext() else { return }
        let w = bounds.width
        let radius: CGFloat = 232.0
        let topMargin: CGFloat = 4.0
        let center = CGPoint(x: w * 0.5, y: topMargin + radius)

        // 1. 绘制半透明深色圆弧穹顶背景（向下包裹至快门区域）
        ctx.saveGState()
        let domePath = UIBezierPath(
            arcCenter: center,
            radius: radius,
            startAngle: .pi,
            endAngle: 0,
            clockwise: true
        )
        domePath.addLine(to: CGPoint(x: w + 40, y: bounds.height + 120))
        domePath.addLine(to: CGPoint(x: -40, y: bounds.height + 120))
        domePath.close()
        ctx.setFillColor(UIColor(white: 0.14, alpha: 0.84).cgColor)
        ctx.addPath(domePath.cgPath)
        ctx.fillPath()

        let rimPath = UIBezierPath(
            arcCenter: center,
            radius: radius,
            startAngle: .pi * 1.05,
            endAngle: -.pi * 0.05,
            clockwise: true
        )
        ctx.setStrokeColor(UIColor(white: 1.0, alpha: 0.14).cgColor)
        ctx.setLineWidth(0.8)
        ctx.addPath(rimPath.cgPath)
        ctx.strokePath()
        ctx.restoreGState()

        // 2. 生成主刻度与对数均匀分布的次刻度
        let majorStops: [(zoom: Float, label: String, mm: String?)] = {
            var arr: [(Float, String, String?)] = []
            if minZoom <= 0.55 {
                arr.append((0.5, "0.5", "13MM"))
            }
            arr.append((1.0, "1", "24MM"))
            arr.append((2.0, "2", "48MM"))
            let teleMM = Int(round(24.0 * Double(teleZoom)))
            let teleLabel = teleZoom == floor(teleZoom) ? "\(Int(teleZoom))" : String(format: "%.1f", teleZoom)
            arr.append((teleZoom, teleLabel, "\(teleMM)MM"))
            arr.append((maxZoom, "\(Int(maxZoom))", nil))
            return arr
        }()

        var minorZooms: [Float] = []
        for idx in 0..<(majorStops.count - 1) {
            let z0 = majorStops[idx].zoom
            let z1 = majorStops[idx + 1].zoom
            let l0 = log2(z0)
            let l1 = log2(z1)
            let subdivisions = max(Int(round(Double(l1 - l0) * 12.0)), 6)
            for s in 1..<subdivisions {
                let frac = Float(s) / Float(subdivisions)
                let z = pow(2.0, l0 + (l1 - l0) * frac)
                minorZooms.append(z)
            }
        }

        // 3. 绘制次刻度短线
        for z in minorZooms {
            let deg = angleDegrees(for: z)
            guard abs(deg) <= 68.0 else { continue }
            let rad = deg * .pi / 180.0
            ctx.saveGState()
            ctx.translateBy(x: center.x, y: center.y)
            ctx.rotate(by: rad)
            let startY = -radius + (abs(deg) < 1.3 ? 11.0 : 4.0)
            let endY = -radius + 17.5
            ctx.setStrokeColor(UIColor(white: 1.0, alpha: 0.30).cgColor)
            ctx.setLineWidth(1.0)
            ctx.move(to: CGPoint(x: 0, y: startY))
            ctx.addLine(to: CGPoint(x: 0, y: endY))
            ctx.strokePath()
            ctx.restoreGState()
        }

        // 4. 绘制主刻度长线与沿圆弧切线旋转的数值/毫米标签
        let para = NSMutableParagraphStyle()
        para.alignment = .center
        let majorFont = UIFont.systemFont(ofSize: 14.5, weight: .semibold)
        let mmFont = UIFont.monospacedSystemFont(ofSize: 9.5, weight: .medium)

        for stop in majorStops {
            let deg = angleDegrees(for: stop.zoom)
            guard abs(deg) <= 72.0 else { continue }
            let rad = deg * .pi / 180.0

            ctx.saveGState()
            ctx.translateBy(x: center.x, y: center.y)
            ctx.rotate(by: rad)

            // 主刻度白线
            let startY = -radius + (abs(deg) < 1.3 ? 12.0 : 4.0)
            let endY = -radius + 20.0
            ctx.setStrokeColor(UIColor(white: 1.0, alpha: 0.95).cgColor)
            ctx.setLineWidth(1.7)
            ctx.move(to: CGPoint(x: 0, y: startY))
            ctx.addLine(to: CGPoint(x: 0, y: endY))
            ctx.strokePath()

            // 当主刻度离开顶部中心黄色读数区（|deg| > 9.5°）时，绘制该主刻度的倍率与等效焦距
            let fade = min(max((abs(deg) - 8.5) / 4.0, 0.0), 1.0)
            if fade > 0.02 {
                let titleAttrs: [NSAttributedString.Key: Any] = [
                    .font: majorFont,
                    .foregroundColor: UIColor(white: 1.0, alpha: 0.92 * fade),
                    .paragraphStyle: para
                ]
                (stop.label as NSString).draw(
                    in: CGRect(x: -30, y: -radius + 24.0, width: 60, height: 18),
                    withAttributes: titleAttrs
                )

                if let mm = stop.mm {
                    let mmAttrs: [NSAttributedString.Key: Any] = [
                        .font: mmFont,
                        .foregroundColor: UIColor(white: 1.0, alpha: 0.42 * fade),
                        .paragraphStyle: para
                    ]
                    (mm as NSString).draw(
                        in: CGRect(x: -34, y: -radius + 42.5, width: 68, height: 14),
                        withAttributes: mmAttrs
                    )
                }
            }
            ctx.restoreGState()
        }

        // 5. 绘制顶部 12 点钟方向黄色尖锥指针 ▼ 与当前实时倍率 + 等效毫米数
        let yellowColor = UIColor(red: 1.0, green: 0.82, blue: 0.05, alpha: 1.0)
        ctx.saveGState()
        let pointerPath = UIBezierPath()
        let pyTop = center.y - radius + 3.5
        pointerPath.move(to: CGPoint(x: center.x - 2.3, y: pyTop))
        pointerPath.addLine(to: CGPoint(x: center.x + 2.3, y: pyTop))
        pointerPath.addLine(to: CGPoint(x: center.x, y: pyTop + 11.5))
        pointerPath.close()
        ctx.setFillColor(yellowColor.cgColor)
        ctx.addPath(pointerPath.cgPath)
        ctx.fillPath()

        let zVal = round(currentZoom * 10.0) / 10.0
        let zString: String
        if abs(zVal - round(zVal)) < 0.05 && zVal >= 1.0 {
            zString = "\(Int(round(zVal)))×"
        } else {
            zString = String(format: "%.1f×", zVal)
        }
        let activeAttrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 16.0, weight: .semibold),
            .foregroundColor: yellowColor,
            .paragraphStyle: para
        ]
        (zString as NSString).draw(
            in: CGRect(x: center.x - 42, y: center.y - radius + 22.0, width: 84, height: 20),
            withAttributes: activeAttrs
        )

        let activeMM = Int(round(24.0 * Double(currentZoom)))
        let activeMMAttrs: [NSAttributedString.Key: Any] = [
            .font: mmFont,
            .foregroundColor: UIColor(white: 1.0, alpha: 0.48),
            .paragraphStyle: para
        ]
        ("\(activeMM)MM" as NSString).draw(
            in: CGRect(x: center.x - 42, y: center.y - radius + 42.0, width: 84, height: 14),
            withAttributes: activeMMAttrs
        )
        ctx.restoreGState()
    }
}

private struct ArcZoomWheelRepresentable: UIViewRepresentable {
    let currentZoom: Float
    let minZoom: Float
    let maxZoom: Float
    let teleZoom: Float

    func makeUIView(context: Context) -> ArcZoomWheelCanvasView {
        let v = ArcZoomWheelCanvasView()
        v.isUserInteractionEnabled = false
        return v
    }

    func updateUIView(_ uiView: ArcZoomWheelCanvasView, context: Context) {
        uiView.minZoom = minZoom
        uiView.maxZoom = maxZoom
        uiView.teleZoom = teleZoom
        uiView.currentZoom = currentZoom
    }
}

// MARK: - 快门上方原生焦段调节组件（收起态：.5  1×  2  5 圆环；展开态：半圆弧形刻度变焦转盘）

private struct NativeCameraZoomControl: View {
    @ObservedObject var controller: LogCameraController
    let accent: Color


    private var isWheelExpanded: Bool {
        controller.activeDrawer == .lensZoom
    }

    private var hasUltraWide: Bool {
        !controller.isFrontCamera && controller.lenses.contains(where: { $0.id == "back_13" })
    }

    private var teleStop: Float {
        controller.lenses.first(where: { $0.id == "back_tele" })?.displayZoom ?? 5.0
    }

    private var minZoom: Float {
        hasUltraWide ? 0.5 : 1.0
    }

    private var maxZoom: Float {
        controller.isFrontCamera ? 3.0 : 15.0
    }

    private var quickStops: [Float] {
        if controller.isFrontCamera {
            return [1.0, 1.5, 2.0]
        }
        var stops: [Float] = []
        if hasUltraWide { stops.append(0.5) }
        stops.append(1.0)
        stops.append(2.0)
        stops.append(teleStop)
        return stops
    }

    private func activeBucketStop(for z: Float, in stops: [Float]) -> Float {
        guard !stops.isEmpty else { return 1.0 }
        var chosen = stops[0]
        for s in stops {
            if z >= s - 0.02 {
                chosen = s
            }
        }
        return chosen
    }

    private func compactLabel(for stop: Float, isSelected: Bool, currentZoom: Float) -> String {
        let val = isSelected ? (round(currentZoom * 10.0) / 10.0) : stop
        let numStr: String
        if val < 1.0 {
            let tenths = Int(round(val * 10.0))
            numStr = ".\(tenths)"
        } else if abs(val - round(val)) < 0.05 {
            numStr = "\(Int(round(val)))"
        } else {
            numStr = String(format: "%.1f", val)
        }
        return isSelected ? "\(numStr)×" : numStr
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            if isWheelExpanded {
                ArcZoomWheelRepresentable(
                    currentZoom: controller.displayZoom,
                    minZoom: minZoom,
                    maxZoom: maxZoom,
                    teleZoom: teleStop
                )
                .frame(maxWidth: .infinity)
                .frame(height: 92)
                .contentShape(Rectangle())
                .gesture(arcWheelDragGesture)
                .simultaneousGesture(
                    SpatialTapGesture()
                        .onEnded { value in
                            handleTapOnArcWheel(at: value.location)
                        }
                )
                .transition(.opacity.combined(with: .move(edge: .bottom)))
            } else {
                collapsedQuickZoomPills
                    .gesture(collapsedBarDragGesture)
                    .transition(.opacity)
            }
        }
    }

    private var collapsedQuickZoomPills: some View {
        let stops = quickStops
        let activeStop = activeBucketStop(for: controller.displayZoom, in: stops)
        let nativeYellow = Color(red: 1.0, green: 0.82, blue: 0.05)

        return HStack(spacing: 8) {
            ForEach(stops, id: \.self) { stop in
                let isSelected = abs(activeStop - stop) < 0.01
                Button(action: {
                    UISelectionFeedbackGenerator().selectionChanged()
                    if isSelected {
                        withAnimation(.spring(response: 0.28, dampingFraction: 0.82)) {
                            controller.activeDrawer = .lensZoom
                        }
                        scheduleAutoCollapse()
                    } else {
                        controller.setDisplayZoom(stop, allowLensSwitch: true, animatedRamp: true)
                    }
                }) {
                    Text(compactLabel(for: stop, isSelected: isSelected, currentZoom: controller.displayZoom))
                        .font(.system(size: isSelected ? 12.5 : 12.0, weight: .bold, design: .rounded))
                        .foregroundColor(isSelected ? nativeYellow : .white)
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                        .frame(width: isSelected ? 37 : 28, height: isSelected ? 37 : 28)
                        .background(
                            Circle()
                                .fill(Color(white: 0.16).opacity(isSelected ? 0.86 : 0.45))
                        )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(Color.black.opacity(0.28), in: Capsule())
    }

    private var collapsedBarDragGesture: some Gesture {
        DragGesture(minimumDistance: 6)
            .onChanged { value in
                if !isWheelExpanded {
                    UISelectionFeedbackGenerator().selectionChanged()
                    withAnimation(.spring(response: 0.25, dampingFraction: 0.84)) {
                        controller.activeDrawer = .lensZoom
                    }
                }
                applyDragDelta(translationX: value.translation.width)
            }
            .onEnded { _ in
                controller.wheelDragStartZoom = nil
                scheduleAutoCollapse()
            }
    }

    private var arcWheelDragGesture: some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { value in
                controller.wheelAutoCollapseGen &+= 1
                applyDragDelta(translationX: value.translation.width)
            }
            .onEnded { _ in
                controller.wheelDragStartZoom = nil
                scheduleAutoCollapse()
            }
    }

    private func applyDragDelta(translationX: CGFloat) {
        if controller.wheelDragStartZoom == nil {
            controller.wheelDragStartZoom = controller.displayZoom
            controller.wheelLastHapticTenth = Int(round(controller.displayZoom * 10.0))
        }
        guard let baseZ = controller.wheelDragStartZoom else { return }
        let deltaOctaves = Float(-translationX / 82.0)
        let rawZ = baseZ * pow(2.0, deltaOctaves)
        let clamped = min(max(rawZ, minZoom), maxZoom)
        let tenth = Int(round(clamped * 10.0))
        if tenth != controller.wheelLastHapticTenth {
            controller.wheelLastHapticTenth = tenth
            UISelectionFeedbackGenerator().selectionChanged()
        }
        controller.setDisplayZoom(clamped, allowLensSwitch: true, animatedRamp: false)
    }

    private func handleTapOnArcWheel(at location: CGPoint) {
        let screenW = UIScreen.main.bounds.width
        let dx = location.x - screenW * 0.5
        let approxDeg = (dx / 232.0) * (180.0 / .pi)
        let targetOctaves = Float(approxDeg / ArcZoomWheelCanvasView.degreesPerOctave)
        let rawTarget = controller.displayZoom * pow(2.0, targetOctaves)
        // 若点击位置靠近主档位（0.5 / 1 / 2 / 5 / 15），直接吸附到主档位
        let candidates: [Float] = [0.5, 1.0, 2.0, teleStop, 15.0].filter { $0 >= minZoom && $0 <= maxZoom }
        if let nearest = candidates.min(by: { abs(log2($0) - log2(max(rawTarget, 0.2))) < abs(log2($1) - log2(max(rawTarget, 0.2))) }),
           abs(log2(nearest) - log2(max(rawTarget, 0.2))) < 0.22 {
            UISelectionFeedbackGenerator().selectionChanged()
            controller.setDisplayZoom(nearest, allowLensSwitch: true, animatedRamp: true)
        }
        scheduleAutoCollapse()
    }

    private func scheduleAutoCollapse() {
        controller.wheelAutoCollapseGen &+= 1
        let gen = controller.wheelAutoCollapseGen
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) {
            if self.controller.wheelAutoCollapseGen == gen && self.controller.activeDrawer == .lensZoom {
                withAnimation(.easeInOut(duration: 0.22)) {
                    self.controller.activeDrawer = nil
                }
            }
        }
    }
}

// MARK: - 4:3 / 16:9 画幅自适应构图九宫格 + 水平仪叠加层

private struct HorizonLevelCapsuleView: View {
    @ObservedObject var levelModel: HorizonLevelModel
    let accent: Color

    var body: some View {
        ZStack {
            HStack(spacing: 56) {
                Rectangle()
                    .fill(levelModel.isLevel ? accent : Color.white.opacity(0.45))
                    .frame(width: 18, height: 1.5)
                Rectangle()
                    .fill(levelModel.isLevel ? accent : Color.white.opacity(0.45))
                    .frame(width: 18, height: 1.5)
            }
            Capsule()
                .fill(levelModel.isLevel ? accent : Color.white.opacity(0.9))
                .frame(width: 50, height: levelModel.isLevel ? 2.2 : 1.5)
                .rotationEffect(.degrees(-levelModel.levelAngle))
        }
    }
}

private struct GridAndLevelOverlay: View {
    let isVisible: Bool
    let isPhotoMode: Bool
    let isLandscape: Bool
    let levelModel: HorizonLevelModel
    let accent: Color

    var body: some View {
        GeometryReader { geo in
            let containerW = geo.size.width
            let containerH = geo.size.height
            let targetAspect: CGFloat = isPhotoMode
                ? (isLandscape ? (4.0 / 3.0) : (3.0 / 4.0))
                : (isLandscape ? (16.0 / 9.0) : (9.0 / 16.0))

            let frameSize: CGSize = {
                guard containerW > 0, containerH > 0 else { return .zero }
                let containerAspect = containerW / containerH
                if containerAspect > targetAspect {
                    let h = containerH
                    return CGSize(width: h * targetAspect, height: h)
                } else {
                    let w = containerW
                    return CGSize(width: w, height: w / targetAspect)
                }
            }()

            ZStack {
                if isPhotoMode {
                    RoundedRectangle(cornerRadius: 2)
                        .stroke(Color.white.opacity(0.18), lineWidth: 0.7)
                        .frame(width: frameSize.width, height: frameSize.height)
                }

                if isVisible {
                    ZStack {
                        Path { path in
                            let w = frameSize.width, h = frameSize.height
                            for i in 1...2 {
                                let x = w * CGFloat(i) / 3.0
                                path.move(to: CGPoint(x: x, y: 0))
                                path.addLine(to: CGPoint(x: x, y: h))
                                let y = h * CGFloat(i) / 3.0
                                path.move(to: CGPoint(x: 0, y: y))
                                path.addLine(to: CGPoint(x: w, y: y))
                            }
                        }
                        .stroke(Color.white.opacity(0.24), lineWidth: 0.7)
                        .frame(width: frameSize.width, height: frameSize.height)

                        HorizonLevelCapsuleView(levelModel: levelModel, accent: accent)
                    }
                }
            }
            .position(x: containerW * 0.5, y: containerH * 0.5)
        }
        .allowsHitTesting(false)
    }
}

// MARK: - 顶部 5 栏等宽参数条（镜头 | 曝光 | 快门 | 感光 | 色温，宽敞不换行）

private struct TopCameraHUDStrip: View {
    @ObservedObject var controller: LogCameraController
    @ObservedObject var telemetry: CameraTelemetry
    let accent: Color

    var body: some View {
        HStack(spacing: 5) {
            hudCell(
                title: "镜头",
                value: controller.currentFocalMMText,
                badge: nil,
                isActive: controller.activeDrawer == .lensZoom
            ) {
                toggleDrawer(.lensZoom)
            }

            hudCell(
                title: "曝光",
                value: String(format: "%+.1f", controller.evBias),
                badge: abs(controller.evBias) > 0.05 ? "M" : nil,
                isActive: controller.activeDrawer == .evBias
            ) {
                toggleDrawer(.evBias)
            }

            let activeShutter = controller.shutterDenom > 0 ? controller.shutterDenom : telemetry.liveShutterDenom
            hudCell(
                title: "快门",
                value: "1/\(activeShutter)",
                badge: controller.isExposureLocked ? "L" : (controller.shutterDenom == 0 ? "A" : nil),
                isActive: controller.activeDrawer == .shutter
            ) {
                toggleDrawer(.shutter)
            }

            let activeISO = controller.isoValue > 0 ? controller.isoValue : telemetry.liveISO
            hudCell(
                title: "感光",
                value: "\(activeISO)",
                badge: controller.isExposureLocked ? "L" : (controller.isoValue == 0 ? "A" : nil),
                isActive: controller.activeDrawer == .iso
            ) {
                toggleDrawer(.iso)
            }

            let activeK = controller.wbKelvin > 0 ? Int(controller.wbKelvin) : telemetry.liveKelvin
            hudCell(
                title: "色温",
                value: "\(activeK)K",
                badge: controller.isWBLocked ? "L" : (controller.wbKelvin == 0 ? "A" : nil),
                isActive: controller.activeDrawer == .whiteBalance
            ) {
                toggleDrawer(.whiteBalance)
            }
        }
    }

    private func toggleDrawer(_ d: ActiveControlDrawer) {
        UISelectionFeedbackGenerator().selectionChanged()
        withAnimation(.easeOut(duration: 0.15)) {
            controller.activeDrawer = (controller.activeDrawer == d) ? nil : d
        }
    }

    private func hudCell(
        title: String,
        value: String,
        badge: String?,
        isActive: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 3) {
                    Text(title)
                        .font(.system(size: 9.5, weight: .semibold))
                        .foregroundColor(isActive ? .black.opacity(0.8) : .white.opacity(0.7))
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    if let badge {
                        Text(badge)
                            .font(.system(size: 8, weight: .bold, design: .monospaced))
                            .foregroundColor(isActive ? accent : .black)
                            .padding(.horizontal, 3.5)
                            .padding(.vertical, 0.5)
                            .background(isActive ? Color.black.opacity(0.78) : accent, in: RoundedRectangle(cornerRadius: 3))
                    }
                }
                Text(value)
                    .font(.system(size: 12.5, weight: .bold, design: .monospaced))
                    .foregroundColor(isActive ? .black : .white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 4.5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isActive ? accent : Color.black.opacity(0.56), in: RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.white.opacity(isActive ? 0.0 : 0.12), lineWidth: 0.6)
            )
        }
    }
}

private struct RecordingTimecodeBadge: View {
    @ObservedObject var telemetry: CameraTelemetry
    let isRecording: Bool

    var body: some View {
        let totalTenths = Int(telemetry.recordingSeconds * 10.0)
        let mins = (totalTenths / 10) / 60
        let secs = (totalTenths / 10) % 60
        let tenths = totalTenths % 10
        let badgeContent = HStack(spacing: 6) {
            Circle()
                .fill(isRecording ? Color.red : Color.white.opacity(0.45))
                .frame(width: 6.5, height: 6.5)
            Text(String(format: "%02d:%02d.%d", mins, secs, tenths))
                .font(.system(size: 13.5, weight: .bold, design: .monospaced))
                .foregroundColor(isRecording ? .white : .white.opacity(0.92))
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 5)

        if #available(iOS 26.0, *) {
            badgeContent
                .glassEffect(isRecording ? .regular.tint(.red) : .regular, in: .capsule)
        } else {
            badgeContent
                .background(isRecording ? Color.red.opacity(0.28) : Color.black.opacity(0.68), in: Capsule())
                .overlay(
                    Capsule()
                        .stroke(isRecording ? Color.red.opacity(0.7) : Color.white.opacity(0.16), lineWidth: 0.8)
                )
        }
    }
}

// MARK: - 原生 UIMenu 左侧空白槽位对齐图标生成器（全部使用单列图标槽位，不混用 state 列，锁图标与勾号同列且绝不把文字向右顶）

private enum MenuGutterIcons {
    static let checkmark: UIImage = renderSlotIcon(systemName: "checkmark", weight: .bold)
    static let lock: UIImage = renderSlotIcon(systemName: "lock.fill", weight: .semibold)
    static let blank: UIImage = {
        let size = CGSize(width: 18, height: 18)
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { _ in }
            .withRenderingMode(.alwaysTemplate)
    }()

    private static func renderSlotIcon(systemName: String, weight: UIImage.SymbolWeight) -> UIImage {
        let canvas = CGSize(width: 18, height: 18)
        let cfg = UIImage.SymbolConfiguration(pointSize: 13, weight: weight)
        let sym = UIImage(systemName: systemName, withConfiguration: cfg) ?? UIImage()
        let renderer = UIGraphicsImageRenderer(size: canvas)
        return renderer.image { _ in
            let s = sym.size
            let origin = CGPoint(x: (canvas.width - s.width) * 0.5, y: (canvas.height - s.height) * 0.5)
            sym.draw(at: origin)
        }
        .withRenderingMode(.alwaysTemplate)
    }
}

// MARK: - 主界面

struct CameraMainView: View {
    @StateObject private var controller = LogCameraController()
    @ObservedObject private var purchaseManager = ProPurchaseManager.shared

    private let accent = Color(red: 0.95, green: 0.74, blue: 0.24)

    private var currentFilm: FilmStockItem {
        let idx = min(max(controller.params.filmIndex, 0), SpectralCatalog.films.count - 1)
        return SpectralCatalog.films[idx]
    }

    private var currentPaper: PrintMediumItem {
        let idx = min(max(controller.params.paperIndex, 0), SpectralCatalog.papers.count - 1)
        return SpectralCatalog.papers[idx]
    }

    private var isLandscape: Bool {
        controller.captureAngle == 0 || controller.captureAngle == 180
    }

    private var uiRotationDegrees: Double {
        if controller.captureAngle == 0 { return 90.0 }
        if controller.captureAngle == 180 { return -90.0 }
        return 0.0
    }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Color.black.ignoresSafeArea()

                if let coordinator = controller.canvasCoordinator {
                    MetalPreviewView(coordinator: coordinator)
                        .ignoresSafeArea()
                }

                // 物理快门帘幕闪烁反馈
                Color.black
                    .opacity(controller.shutterCurtainOpacity)
                    .animation(.easeInOut(duration: 0.08), value: controller.shutterCurtainOpacity)
                    .ignoresSafeArea()
                    .allowsHitTesting(false)

                // 触屏对焦准星
                if let focusPt = controller.focusReticlePoint {
                    FocusReticleShape()
                        .stroke(accent, lineWidth: 1.6)
                        .frame(width: 54, height: 54)
                        .position(focusPt)
                        .allowsHitTesting(false)
                }

                // 随横竖屏自动旋转的构图网格、水平仪与操控界面
                ZStack {
                    GridAndLevelOverlay(
                        isVisible: controller.showGridAndLevel,
                        isPhotoMode: controller.captureMode == .photo,
                        isLandscape: isLandscape,
                        levelModel: controller.levelModel,
                        accent: accent
                    )

                    if isLandscape {
                        landscapeLayout
                    } else {
                        portraitLayout
                    }
                }
                .frame(
                    width: isLandscape ? geo.size.height : geo.size.width,
                    height: isLandscape ? geo.size.width : geo.size.height
                )
                .rotationEffect(.degrees(uiRotationDegrees))
                .position(x: geo.size.width * 0.5, y: geo.size.height * 0.5)
                .animation(.easeInOut(duration: 0.2), value: controller.captureAngle)

                if controller.showProPaywall {
                    ProPaywallModalView(
                        purchaseManager: purchaseManager,
                        accent: accent,
                        onClose: { controller.showProPaywall = false }
                    )
                }
            }
            .ignoresSafeArea()
        }
        .ignoresSafeArea()
        .preferredColorScheme(.dark)
        .statusBarHidden(true)
        .onAppear { controller.start() }
    }

    // MARK: - 竖屏布局

    private var portraitLayout: some View {
        VStack(spacing: 6) {
            topFormatAndUtilityRow
            TopCameraHUDStrip(controller: controller, telemetry: controller.telemetry, accent: accent)

            Spacer()

            if let toast = controller.statusToast {
                toastBadge(toast)
            }
            if let drawer = controller.activeDrawer, drawer != .lensZoom {
                activeDrawerView(drawer)
            }

            if controller.captureMode == .video {
                RecordingTimecodeBadge(telemetry: controller.telemetry, isRecording: controller.isRecording)
                    .padding(.bottom, 4)
            }

            if controller.activeDrawer == nil || controller.activeDrawer == .lensZoom {
                NativeCameraZoomControl(controller: controller, accent: accent)
                    .padding(.bottom, 4)
            }

            bottomCompactBar
        }
        .padding(.top, 62)
        .padding(.bottom, 18)
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - 横屏布局

    private var landscapeLayout: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 6) {
                topFormatAndUtilityRow
                TopCameraHUDStrip(controller: controller, telemetry: controller.telemetry, accent: accent)

                Spacer()

                if let toast = controller.statusToast {
                    toastBadge(toast)
                }
                if let drawer = controller.activeDrawer, drawer != .lensZoom {
                    activeDrawerView(drawer)
                        .frame(maxWidth: 460)
                } else {
                    NativeCameraZoomControl(controller: controller, accent: accent)
                        .frame(maxWidth: 420)
                }
            }

            rightLandscapeRail
        }
        .padding(.leading, controller.captureAngle == 0 ? 62 : 14)
        .padding(.trailing, controller.captureAngle == 180 ? 62 : 14)
        .padding(.vertical, 8)
    }

    // MARK: - 顶部第 1 行：采集画质（左） | 平台·编码·色域（中） | 网格与分屏开关（右）

    private var topFormatAndUtilityRow: some View {
        HStack(spacing: 6) {
            leftCaptureSpecMenu

            Spacer(minLength: 4)

            // 顶部中间：编码 · 色域 · 平台格式原生液态玻璃菜单（位于同一 HStack 流中，绝不与左右按钮叠压）
            centerFormatSpecMenu

            Spacer(minLength: 4)

            HStack(spacing: 6) {
                // 九宫格 + 水平仪一体开关
                Button(action: {
                    UISelectionFeedbackGenerator().selectionChanged()
                    controller.showGridAndLevel.toggle()
                }) {
                    Image(systemName: "viewfinder")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundColor(controller.showGridAndLevel ? .black : .white)
                        .frame(width: 30, height: 30)
                        .background(controller.showGridAndLevel ? accent : Color.black.opacity(0.6), in: Circle())
                }

                // 原片分屏对比开关
                Button(action: {
                    UISelectionFeedbackGenerator().selectionChanged()
                    controller.params.splitCompareRatio = controller.params.splitCompareRatio > 0.01 ? 0.0 : 0.5
                }) {
                    Image(systemName: "rectangle.lefthalf.inset.filled")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundColor(controller.params.splitCompareRatio > 0.01 ? .black : .white)
                        .frame(width: 30, height: 30)
                        .background(controller.params.splitCompareRatio > 0.01 ? accent : Color.black.opacity(0.6), in: Circle())
                }
            }
        }
    }

    // 原生 Menu 单行菜单项：不混用 Picker/Toggle 的 state 列，统一使用单列 18×18 槽位图标（✓ / 🔒 / 空白），文字左边距 100% 对齐
    private func nativeMenuButton(
        title: String,
        isSelected: Bool,
        isLockedPro: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Label {
                Text(title)
            } icon: {
                Image(uiImage: isSelected ? MenuGutterIcons.checkmark : (isLockedPro ? MenuGutterIcons.lock : MenuGutterIcons.blank))
            }
        }
    }

    // 左按钮（原生液态玻璃 Menu）：保留分辨率、拍摄帧率与保存规格
    private var leftCaptureSpecMenu: some View {
        Menu {
            if controller.captureMode == .photo {
                Section("照片分辨率 (4:3)") {
                    ForEach(controller.availablePhotoDimensions) { dim in
                        nativeMenuButton(
                            title: dim.menuTitle,
                            isSelected: controller.selectedPhotoDimension == dim
                        ) {
                            controller.setPhotoDimension(dim)
                        }
                    }
                }

                Section("保存规格") {
                    nativeMenuButton(
                        title: "保存成片",
                        isSelected: controller.currentPhotoSaveSpec == .renderedOnly
                    ) {
                        controller.selectPhotoSaveSpec(.renderedOnly)
                    }
                    nativeMenuButton(
                        title: "Apple ProRaw",
                        isSelected: controller.currentPhotoSaveSpec == .appleProRaw
                    ) {
                        controller.selectPhotoSaveSpec(.appleProRaw)
                    }
                    nativeMenuButton(
                        title: "同时保存",
                        isSelected: controller.currentPhotoSaveSpec == .saveBoth,
                        isLockedPro: !purchaseManager.isProUnlocked
                    ) {
                        controller.selectPhotoSaveSpec(.saveBoth)
                    }
                }
            } else {
                Section("视频分辨率 (16:9)") {
                    nativeMenuButton(
                        title: "1080p HD (1920×1080)",
                        isSelected: !controller.is4K
                    ) {
                        controller.is4K = false
                    }
                    nativeMenuButton(
                        title: "4K UHD (3840×2160)",
                        isSelected: controller.is4K
                    ) {
                        controller.is4K = true
                    }
                }

                Section("拍摄帧率") {
                    ForEach([24, 30, 60], id: \.self) { rate in
                        nativeMenuButton(
                            title: "\(rate) fps",
                            isSelected: controller.fps == rate
                        ) {
                            controller.fps = rate
                        }
                    }
                }

                Section {
                    nativeMenuButton(
                        title: "锁定恒定帧率 (CFR)",
                        isSelected: controller.lockFrameRate
                    ) {
                        controller.lockFrameRate.toggle()
                    }
                }

                Section("保存规格") {
                    nativeMenuButton(
                        title: "保存成片",
                        isSelected: controller.currentVideoSaveSpec == .renderedOnly
                    ) {
                        controller.selectVideoSaveSpec(.renderedOnly)
                    }
                    nativeMenuButton(
                        title: "Apple Log 10-bit",
                        isSelected: controller.currentVideoSaveSpec == .appleLog10Bit
                    ) {
                        controller.selectVideoSaveSpec(.appleLog10Bit)
                    }
                    nativeMenuButton(
                        title: "同时保存",
                        isSelected: controller.currentVideoSaveSpec == .saveBoth,
                        isLockedPro: !purchaseManager.isProUnlocked
                    ) {
                        controller.selectVideoSaveSpec(.saveBoth)
                    }
                }
            }
        } label: {
            HStack(spacing: 5) {
                if controller.captureMode == .photo {
                    Text(controller.selectedPhotoDimension.shortLabel)
                        .font(.system(size: 10, weight: .heavy, design: .monospaced))
                        .foregroundColor(.black)
                        .lineLimit(1)
                        .padding(.horizontal, 4.5)
                        .padding(.vertical, 2)
                        .background(Color.white, in: RoundedRectangle(cornerRadius: 3.5))

                    Text(controller.photoSaveSpecShortBadge)
                        .font(.system(size: 10.5, weight: .bold, design: .monospaced))
                        .foregroundColor(.white)
                        .lineLimit(1)
                } else {
                    Text(controller.is4K ? "4K" : "1080p")
                        .font(.system(size: 10, weight: .heavy, design: .monospaced))
                        .foregroundColor(.black)
                        .lineLimit(1)
                        .padding(.horizontal, 4.5)
                        .padding(.vertical, 2)
                        .background(Color.white, in: RoundedRectangle(cornerRadius: 3.5))

                    Text("\(controller.fps)fps · \(controller.videoSaveSpecShortBadge)")
                        .font(.system(size: 10.5, weight: .bold, design: .monospaced))
                        .foregroundColor(.white)
                        .lineLimit(1)
                }

                Image(systemName: "chevron.down")
                    .font(.system(size: 8.5, weight: .bold))
                    .foregroundColor(.white.opacity(0.65))
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 4.5)
            .background(Color.black.opacity(0.66), in: RoundedRectangle(cornerRadius: 7))
            .overlay(
                RoundedRectangle(cornerRadius: 7)
                    .stroke(Color.white.opacity(0.18), lineWidth: 0.7)
            )
            .fixedSize(horizontal: true, vertical: false)
        }
    }

    // 中间按钮（原生液态玻璃 Menu）：平台选择放第一行（纯平台名无参数），输出画面尺寸与编码色域
    private var centerFormatSpecMenu: some View {
        Menu {
            Section("按平台最佳规格拍摄") {
                ForEach(SocialExportPreset.allCases) { preset in
                    let isLocked = preset.requiresProPurchase && !purchaseManager.isProUnlocked
                    nativeMenuButton(
                        title: preset.menuTitle,
                        isSelected: controller.selectedExportPreset == preset,
                        isLockedPro: isLocked
                    ) {
                        controller.applyExportPreset(preset)
                    }
                }
            }

            if controller.captureMode == .photo {
                Section("输出画面尺寸") {
                    ForEach(ExportDimensionLimit.allCases) { dim in
                        nativeMenuButton(
                            title: dim.label,
                            isSelected: controller.exportDimensionLimit == dim
                        ) {
                            controller.updateExportSpec(dimension: dim)
                        }
                    }
                }

                Section("编码与色域") {
                    ForEach(ExportFileFormat.allCases) { fmt in
                        nativeMenuButton(
                            title: "格式：\(fmt.label)",
                            isSelected: controller.exportFileFormat == fmt
                        ) {
                            controller.updateExportSpec(format: fmt)
                        }
                    }
                    ForEach(ExportColorGamut.allCases) { gamut in
                        nativeMenuButton(
                            title: "色域：\(gamut.menuTitle)",
                            isSelected: controller.exportColorGamut == gamut
                        ) {
                            controller.updateExportSpec(gamut: gamut)
                        }
                    }
                    nativeMenuButton(
                        title: "HDR 高光增益图",
                        isSelected: controller.exportHDREnabled
                    ) {
                        controller.updateExportSpec(hdrEnabled: !controller.exportHDREnabled)
                    }
                }
            } else {
                Section("视频编码") {
                    ForEach(VideoCodecPreset.allCases, id: \.rawValue) { preset in
                        nativeMenuButton(
                            title: preset.menuTitle,
                            isSelected: controller.codecPreset == preset
                        ) {
                            controller.codecPreset = preset
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 5) {
                if controller.captureMode == .photo {
                    let platformTitle = controller.selectedExportPreset?.name ?? "自定义"
                    let fmtTag = controller.exportFileFormat.label
                    let gamutTag = controller.exportColorGamut.shortLabel
                    Text("\(platformTitle) · \(fmtTag) \(gamutTag)")
                        .font(.system(size: 10.5, weight: .bold, design: .monospaced))
                        .foregroundColor(.white)
                        .lineLimit(1)
                } else {
                    let platformTitle = controller.selectedExportPreset?.name ?? "无损原画"
                    Text("\(platformTitle) · \(controller.codecPreset.shortBadge)")
                        .font(.system(size: 10.5, weight: .bold, design: .monospaced))
                        .foregroundColor(.white)
                        .lineLimit(1)
                }

                Image(systemName: "chevron.down")
                    .font(.system(size: 8.5, weight: .bold))
                    .foregroundColor(.white.opacity(0.65))
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 4.5)
            .background(Color.black.opacity(0.66), in: RoundedRectangle(cornerRadius: 7))
            .overlay(
                RoundedRectangle(cornerRadius: 7)
                    .stroke(Color.white.opacity(0.18), lineWidth: 0.7)
            )
            .fixedSize(horizontal: true, vertical: false)
        }
    }

    // MARK: - 底部竖屏控制坞与右侧横屏控制栏

    private var bottomCompactBar: some View {
        ZStack {
            HStack(spacing: 8) {
                // 左侧：胶卷与相纸组合入口
                Button(action: {
                    toggleDrawer(.filmLook)
                }) {
                    HStack(spacing: 6) {
                        Image(systemName: "film")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundColor(controller.activeDrawer == .filmLook ? .black : accent)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(currentFilm.shortName)
                                .font(.system(size: 11, weight: .bold))
                                .foregroundColor(controller.activeDrawer == .filmLook ? .black : .white)
                                .lineLimit(1)
                            Text(currentFilm.category == .blackAndWhite ? "反差 \(SpectralCatalog.bwGrades[controller.params.bwGradeIndex])" : currentPaper.shortName)
                                .font(.system(size: 8.5, weight: .medium))
                                .foregroundColor(controller.activeDrawer == .filmLook ? .black.opacity(0.75) : .white.opacity(0.65))
                                .lineLimit(1)
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .frame(width: 116, height: 42, alignment: .leading)
                    .background(controller.activeDrawer == .filmLook ? accent : Color.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
                }

                Spacer(minLength: 74)

                // 右侧：照片/视频切换 + 曝光/色温锁定
                HStack(spacing: 6) {
                    captureModeSwitchPill

                    let anyLocked = controller.isExposureLocked || controller.isWBLocked
                    Button(action: {
                        UISelectionFeedbackGenerator().selectionChanged()
                        let next = !anyLocked
                        controller.isExposureLocked = next
                        controller.isWBLocked = next
                    }) {
                        Image(systemName: anyLocked ? "lock.fill" : "lock.open")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundColor(anyLocked ? .black : .white)
                            .frame(width: 34, height: 34)
                            .background(anyLocked ? accent : Color.white.opacity(0.1), in: Circle())
                    }
                }
            }

            shutterButton
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity)
        .background(Color.black.opacity(0.76), in: RoundedRectangle(cornerRadius: 22))
    }

    private var rightLandscapeRail: some View {
        VStack(spacing: 10) {
            let anyLocked = controller.isExposureLocked || controller.isWBLocked
            Button(action: {
                UISelectionFeedbackGenerator().selectionChanged()
                let next = !anyLocked
                controller.isExposureLocked = next
                controller.isWBLocked = next
            }) {
                Image(systemName: anyLocked ? "lock.fill" : "lock.open")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundColor(anyLocked ? .black : .white)
                    .frame(width: 42, height: 42)
                    .background(anyLocked ? accent : Color.white.opacity(0.1), in: Circle())
            }

            captureModeSwitchPill

            Spacer()

            if controller.captureMode == .video {
                RecordingTimecodeBadge(telemetry: controller.telemetry, isRecording: controller.isRecording)
            }

            shutterButton

            Spacer()

            Button(action: {
                toggleDrawer(.filmLook)
            }) {
                VStack(spacing: 2) {
                    Image(systemName: "film")
                        .font(.system(size: 14, weight: .bold))
                    Text(currentFilm.shortName)
                        .font(.system(size: 8.5, weight: .bold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
                .foregroundColor(controller.activeDrawer == .filmLook ? .black : .white)
                .frame(width: 52, height: 44)
                .background(controller.activeDrawer == .filmLook ? accent : Color.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 11))
            }
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 6)
        .background(Color.black.opacity(0.76), in: RoundedRectangle(cornerRadius: 20))
    }

    private var captureModeSwitchPill: some View {
        HStack(spacing: 2) {
            ForEach(CaptureMode.allCases) { mode in
                let active = controller.captureMode == mode
                Button(action: {
                    guard controller.captureMode != mode else { return }
                    UISelectionFeedbackGenerator().selectionChanged()
                    controller.setCaptureMode(mode)
                }) {
                    Text(mode.label)
                        .font(.system(size: 10.5, weight: .bold))
                        .foregroundColor(active ? .black : .white.opacity(0.78))
                        .lineLimit(1)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .background(active ? accent : Color.clear, in: Capsule())
                }
                .disabled(controller.isRecording || controller.isCapturingPhoto)
            }
        }
        .padding(2)
        .background(Color.white.opacity(0.1), in: Capsule())
        .fixedSize(horizontal: true, vertical: false)
    }

    private func toggleDrawer(_ d: ActiveControlDrawer) {
        UISelectionFeedbackGenerator().selectionChanged()
        withAnimation(.easeOut(duration: 0.15)) {
            controller.activeDrawer = (controller.activeDrawer == d) ? nil : d
        }
    }

    private var shutterButton: some View {
        Button(action: {
            controller.activeDrawer = nil
            if controller.captureMode == .photo {
                controller.capturePhoto()
            } else {
                controller.toggleRecording()
            }
        }) {
            ZStack {
                Circle()
                    .stroke(controller.isCapturingPhoto ? accent : Color.white, lineWidth: 2.5)
                    .frame(width: 58, height: 58)

                if controller.captureMode == .photo {
                    Circle()
                        .fill(controller.isCapturingPhoto ? accent.opacity(0.85) : Color(white: 0.96))
                        .frame(width: 46, height: 46)
                    Circle()
                        .stroke(Color.black.opacity(0.16), lineWidth: 1.0)
                        .frame(width: 41, height: 41)
                } else if controller.isRecording {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.red)
                        .frame(width: 24, height: 24)
                } else {
                    Circle()
                        .fill(Color(red: 0.86, green: 0.14, blue: 0.14))
                        .frame(width: 46, height: 46)
                }
            }
        }
        .disabled(controller.isCapturingPhoto)
    }

    // MARK: - 磁力刻度波轮与胶片面板分发

    @ViewBuilder
    private func activeDrawerView(_ drawer: ActiveControlDrawer) -> some View {
        switch drawer {
        case .lensZoom:
            EmptyView()

        case .shutter:
            let stops = controller.captureMode == .photo ? LogCameraController.photoShutterStops : LogCameraController.shutterStops
            let curDenom = controller.shutterDenom > 0 ? controller.shutterDenom : controller.telemetry.liveShutterDenom
            let idx = stops.enumerated().min(by: { abs($0.element - curDenom) < abs($1.element - curDenom) })?.offset ?? 4
            MagneticStopWheel(
                title: "快门速度",
                items: stops.map { "1/\($0)" },
                selectedIndex: idx,
                isAuto: controller.shutterDenom == 0,
                autoButtonLabel: "自动",
                accent: accent,
                onSelectIndex: { i in controller.shutterDenom = stops[i] },
                onTapAuto: { controller.shutterDenom = 0 }
            )

        case .iso:
            let stops = LogCameraController.isoStops
            let curISO = controller.isoValue > 0 ? controller.isoValue : controller.telemetry.liveISO
            let idx = stops.enumerated().min(by: { abs($0.element - curISO) < abs($1.element - curISO) })?.offset ?? 6
            MagneticStopWheel(
                title: "ISO 感光度",
                items: stops.map { "\($0)" },
                selectedIndex: idx,
                isAuto: controller.isoValue == 0,
                autoButtonLabel: "自动",
                accent: accent,
                onSelectIndex: { i in controller.isoValue = stops[i] },
                onTapAuto: { controller.isoValue = 0 }
            )

        case .whiteBalance:
            let stops = LogCameraController.wbStops
            let curK = controller.wbKelvin > 0 ? Int(controller.wbKelvin) : controller.telemetry.liveKelvin
            let idx = stops.enumerated().min(by: { abs($0.element - curK) < abs($1.element - curK) })?.offset ?? 26
            VStack(spacing: 6) {
                HStack(spacing: 6) {
                    wbQuickChip("自动", k: 0)
                    wbQuickChip("暖光", k: 3200)
                    wbQuickChip("荧光", k: 4000)
                    wbQuickChip("日光", k: 5200)
                    wbQuickChip("阴天", k: 6500)
                }
                MagneticStopWheel(
                    title: "色温",
                    items: stops.map { "\($0)K" },
                    selectedIndex: idx,
                    isAuto: controller.wbKelvin == 0,
                    autoButtonLabel: "自动",
                    accent: accent,
                    onSelectIndex: { i in controller.wbKelvin = Float(stops[i]) },
                    onTapAuto: { controller.wbKelvin = 0 }
                )
            }

        case .evBias:
            let evStops: [Float] = stride(from: -2.0, through: 2.001, by: 0.1).map { Float(round($0 * 10) / 10) }
            let idx = evStops.enumerated().min(by: { abs($0.element - controller.evBias) < abs($1.element - controller.evBias) })?.offset ?? 20
            MagneticStopWheel(
                title: "曝光补偿",
                items: evStops.map { String(format: "%+.1f EV", $0) },
                selectedIndex: idx,
                isAuto: abs(controller.evBias) < 0.05,
                autoButtonLabel: "归零",
                accent: accent,
                onSelectIndex: { i in controller.evBias = evStops[i] },
                onTapAuto: { controller.evBias = 0.0 }
            )

        case .filmLook:
            filmAndDiffusionDrawer
        }
    }

    private func wbQuickChip(_ title: String, k: Float) -> some View {
        let selected = (k == 0 && controller.wbKelvin == 0) || (k > 0 && abs(controller.wbKelvin - k) < 60)
        return Button(action: {
            UISelectionFeedbackGenerator().selectionChanged()
            controller.wbKelvin = k
        }) {
            Text(title)
                .font(.system(size: 10, weight: .bold))
                .foregroundColor(selected ? .black : .white)
                .lineLimit(1)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 5)
                .background(selected ? accent : Color.black.opacity(0.68), in: Capsule())
        }
    }

    // MARK: - 胶片、相纸、柔光镜与影调微调面板

    private var filmAndDiffusionDrawer: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                Picker("", selection: $controller.filmSubTab) {
                    Text("胶卷与相纸").tag(0)
                    Text("柔光与颗粒").tag(1)
                    Text("影调微调").tag(2)
                }
                .pickerStyle(.segmented)

                Button("复位") {
                    var reset = controller.params
                    reset.filmExposureEV = 0
                    reset.printExposureEV = 0
                    reset.magentaFilterShift = 0
                    reset.yellowFilterShift = 0
                    reset.halationAmount = 1
                    reset.grainAmount = 1
                    reset.diffusionFamily = .off
                    reset.diffusionStrength = 0.5
                    controller.params = reset
                }
                .font(.system(size: 11, weight: .bold))
                .foregroundColor(accent)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
            }

            if controller.filmSubTab == 0 {
                Picker("类别", selection: $controller.selectedCategory) {
                    ForEach(FilmCategory.allCases, id: \.rawValue) { cat in
                        Text(cat.rawValue).tag(cat)
                    }
                }
                .pickerStyle(.segmented)
                .onChange(of: controller.selectedCategory) { _, newCat in
                    if let firstIdx = SpectralCatalog.films.firstIndex(where: { $0.category == newCat }) {
                        controller.selectFilm(index: firstIdx)
                    }
                }

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(Array(SpectralCatalog.films.enumerated()), id: \.element.id) { idx, film in
                            if film.category == controller.selectedCategory {
                                let selected = controller.params.filmIndex == idx
                                Button(action: {
                                    UISelectionFeedbackGenerator().selectionChanged()
                                    controller.selectFilm(index: idx)
                                }) {
                                    Text(film.shortName)
                                        .font(.system(size: 11, weight: .bold))
                                        .foregroundColor(selected ? .black : .white)
                                        .lineLimit(1)
                                        .fixedSize(horizontal: true, vertical: false)
                                        .padding(.horizontal, 11)
                                        .padding(.vertical, 6)
                                        .background(selected ? accent : Color.white.opacity(0.12), in: Capsule())
                                }
                            }
                        }
                    }
                }
                .frame(height: 32)

                if currentFilm.category != .blackAndWhite {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            Text("相纸")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundColor(.white.opacity(0.55))
                                .padding(.trailing, 2)
                            ForEach(Array(SpectralCatalog.papers.enumerated()), id: \.element.id) { idx, paper in
                                if idx != 2 {
                                    let selected = controller.params.paperIndex == idx
                                    Button(action: {
                                        UISelectionFeedbackGenerator().selectionChanged()
                                        controller.params.paperIndex = idx
                                    }) {
                                        Text(paper.shortName)
                                            .font(.system(size: 10.5, weight: .semibold))
                                            .foregroundColor(selected ? accent : .white.opacity(0.8))
                                            .lineLimit(1)
                                            .fixedSize(horizontal: true, vertical: false)
                                            .padding(.horizontal, 9)
                                            .padding(.vertical, 4.5)
                                            .background(selected ? accent.opacity(0.18) : Color.white.opacity(0.08), in: Capsule())
                                            .overlay(
                                                Capsule()
                                                    .stroke(selected ? accent.opacity(0.6) : Color.clear, lineWidth: 0.7)
                                            )
                                    }
                                }
                            }
                        }
                    }
                    .frame(height: 30)
                } else {
                    Picker("反差号", selection: $controller.params.bwGradeIndex) {
                        ForEach(0..<SpectralCatalog.bwGrades.count, id: \.self) { g in
                            Text("反差 \(SpectralCatalog.bwGrades[g])").tag(g)
                        }
                    }
                    .pickerStyle(.segmented)
                }
            } else if controller.filmSubTab == 1 {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(DiffusionFilterFamily.allCases, id: \.rawValue) { fam in
                            let sel = controller.params.diffusionFamily == fam
                            Button(action: {
                                UISelectionFeedbackGenerator().selectionChanged()
                                controller.params.diffusionFamily = fam
                            }) {
                                Text(fam.displayName)
                                    .font(.system(size: 11, weight: .bold))
                                    .foregroundColor(sel ? .black : .white)
                                    .lineLimit(1)
                                    .fixedSize(horizontal: true, vertical: false)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 5.5)
                                    .background(sel ? accent : Color.white.opacity(0.12), in: Capsule())
                            }
                        }
                    }
                }
                .frame(height: 32)

                if controller.params.diffusionFamily != .off {
                    HStack(spacing: 6) {
                        Text("柔光强度")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(.white.opacity(0.75))
                            .lineLimit(1)
                        ForEach([(Float(0.125), "1/8"), (Float(0.25), "1/4"), (Float(0.5), "1/2"), (Float(1.0), "1"), (Float(2.0), "2")], id: \.1) { val, lbl in
                            let sel = abs(controller.params.diffusionStrength - val) < 0.05
                            Button(lbl) {
                                UISelectionFeedbackGenerator().selectionChanged()
                                controller.params.diffusionStrength = val
                            }
                            .font(.system(size: 11, weight: .bold, design: .monospaced))
                            .foregroundColor(sel ? .black : .white)
                            .lineLimit(1)
                            .padding(.horizontal, 9)
                            .padding(.vertical, 4)
                            .background(sel ? accent : Color.white.opacity(0.1), in: Capsule())
                        }
                        Spacer()
                    }
                }

                HStack(spacing: 12) {
                    miniSlider("高光光晕", value: $controller.params.halationAmount, range: 0...2, fmt: "%.1f")
                    miniSlider("银盐颗粒", value: $controller.params.grainAmount, range: 0...2, fmt: "%.1f")
                }
            } else {
                HStack(spacing: 12) {
                    miniSlider("胶片曝光", value: $controller.params.filmExposureEV, range: -2.5...2.5, fmt: "%+.1f")
                    miniSlider("冲印明暗", value: $controller.params.printExposureEV, range: -1.5...1.5, fmt: "%+.1f")
                }
                if currentFilm.category == .colorNegative {
                    HStack(spacing: 12) {
                        miniSlider("冲印冷暖 Y", value: $controller.params.yellowFilterShift, range: -25...25, fmt: "%+.0f")
                        miniSlider("冲印绿品 M", value: $controller.params.magentaFilterShift, range: -25...25, fmt: "%+.0f")
                    }
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity)
        .background(Color.black.opacity(0.84), in: RoundedRectangle(cornerRadius: 14))
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(Color.white.opacity(0.14), lineWidth: 0.7)
        )
    }

    private func miniSlider(_ title: String, value: Binding<Float>, range: ClosedRange<Float>, fmt: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.white.opacity(0.8))
                    .lineLimit(1)
                Spacer()
                Text(String(format: fmt, value.wrappedValue))
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundColor(accent)
                    .lineLimit(1)
            }
            Slider(value: value, in: range).tint(accent)
        }
    }

    private func toastBadge(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11.5, weight: .semibold))
            .foregroundColor(.black)
            .lineLimit(1)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(accent, in: Capsule())
    }
}

private struct FocusReticleShape: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.addRoundedRect(in: rect, cornerSize: CGSize(width: 4, height: 4))
        let tick: CGFloat = 6.0
        p.move(to: CGPoint(x: rect.midX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.midX, y: rect.minY + tick))
        p.move(to: CGPoint(x: rect.midX, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.midX, y: rect.maxY - tick))
        p.move(to: CGPoint(x: rect.minX, y: rect.midY))
        p.addLine(to: CGPoint(x: rect.minX + tick, y: rect.midY))
        p.move(to: CGPoint(x: rect.maxX, y: rect.midY))
        p.addLine(to: CGPoint(x: rect.maxX - tick, y: rect.midY))
        return p
    }
}

