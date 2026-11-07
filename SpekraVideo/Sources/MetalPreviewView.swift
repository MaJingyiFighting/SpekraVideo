import SwiftUI
import MetalKit
import AVKit
import QuartzCore

final class MetalCanvasCoordinator: NSObject, MTKViewDelegate {
    let engine: SpectralFilmMetalEngine
    private let lock = NSLock()
    private var latestTexture: MTLTexture?
    private var redrawPending: Bool = false
    private(set) var lastTextureSize: CGSize = CGSize(width: 1080, height: 1920)
    weak var mtkView: MTKView?

    var onTapViewfinder: ((_ normalizedPortraitPt: CGPoint, _ viewPt: CGPoint) -> Void)?
    var onPinchZoom: ((_ scale: CGFloat, _ state: UIGestureRecognizer.State) -> Void)?
    var onPhysicalCaptureButton: (() -> Void)?

    init(engine: SpectralFilmMetalEngine) {
        self.engine = engine
        super.init()
    }

    func present(texture: MTLTexture) {
        lock.lock()
        latestTexture = texture
        lastTextureSize = CGSize(width: texture.width, height: texture.height)
        let shouldSchedule = !redrawPending
        if shouldSchedule {
            redrawPending = true
        }
        lock.unlock()

        if shouldSchedule {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.mtkView?.setNeedsDisplay()
            }
        }
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        lock.lock()
        let tex = latestTexture
        redrawPending = false
        lock.unlock()

        guard let texture = tex,
              let drawable = view.currentDrawable,
              let rpd = view.currentRenderPassDescriptor,
              let cmdBuf = engine.commandQueue.makeCommandBuffer(),
              let enc = cmdBuf.makeRenderCommandEncoder(descriptor: rpd) else {
            return
        }

        let viewW = max(Float(view.drawableSize.width), 1.0)
        let viewH = max(Float(view.drawableSize.height), 1.0)
        let texW = max(Float(texture.width), 1.0)
        let texH = max(Float(texture.height), 1.0)

        let viewAspect = viewW / viewH
        let texAspect = texW / texH

        var scale = SIMD2<Float>(1.0, 1.0)
        if texAspect > viewAspect {
            scale.y = viewAspect / texAspect
        } else {
            scale.x = texAspect / viewAspect
        }

        enc.setRenderPipelineState(engine.displayRenderPipeline)
        enc.setVertexBytes(&scale, length: MemoryLayout<SIMD2<Float>>.stride, index: 0)
        enc.setFragmentTexture(texture, index: 0)
        enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        enc.endEncoding()

        cmdBuf.present(drawable)
        cmdBuf.commit()
    }

    @objc func handleTap(_ recognizer: UITapGestureRecognizer) {
        guard recognizer.state == .ended, let view = mtkView else { return }
        let pt = recognizer.location(in: view)
        let bounds = view.bounds
        guard bounds.width > 1, bounds.height > 1 else { return }

        lock.lock()
        let texSize = lastTextureSize
        lock.unlock()

        let viewAspect = bounds.width / bounds.height
        let texAspect = max(texSize.width, 1.0) / max(texSize.height, 1.0)

        var videoRect = bounds
        if texAspect > viewAspect {
            let fittedH = bounds.width / texAspect
            videoRect = CGRect(x: 0, y: (bounds.height - fittedH) * 0.5, width: bounds.width, height: fittedH)
        } else {
            let fittedW = bounds.height * texAspect
            videoRect = CGRect(x: (bounds.width - fittedW) * 0.5, y: 0, width: fittedW, height: bounds.height)
        }

        guard videoRect.insetBy(dx: -8, dy: -8).contains(pt) else { return }
        let nx = min(max((pt.x - videoRect.minX) / max(videoRect.width, 1.0), 0.0), 1.0)
        let ny = min(max((pt.y - videoRect.minY) / max(videoRect.height, 1.0), 0.0), 1.0)
        onTapViewfinder?(CGPoint(x: nx, y: ny), pt)
    }

    @objc func handlePinch(_ recognizer: UIPinchGestureRecognizer) {
        onPinchZoom?(recognizer.scale, recognizer.state)
    }
}

struct MetalPreviewView: UIViewRepresentable {
    let coordinator: MetalCanvasCoordinator

    func makeUIView(context: Context) -> MTKView {
        let view = MTKView(frame: .zero, device: coordinator.engine.device)
        view.colorPixelFormat = .bgra8Unorm
        view.clearColor = MTLClearColor(red: 0.0, green: 0.0, blue: 0.0, alpha: 1.0)
        view.framebufferOnly = true
        view.isPaused = true
        view.enableSetNeedsDisplay = true
        view.contentMode = .scaleAspectFit
        if let metalLayer = view.layer as? CAMetalLayer,
           let p3Space = CGColorSpace(name: CGColorSpace.displayP3) {
            metalLayer.colorspace = p3Space
        }
        view.delegate = coordinator
        coordinator.mtkView = view

        let tap = UITapGestureRecognizer(target: coordinator, action: #selector(MetalCanvasCoordinator.handleTap(_:)))
        view.addGestureRecognizer(tap)

        let pinch = UIPinchGestureRecognizer(target: coordinator, action: #selector(MetalCanvasCoordinator.handlePinch(_:)))
        view.addGestureRecognizer(pinch)

        if #available(iOS 17.2, *) {
            let captureInteraction = AVCaptureEventInteraction { [weak coordinator] event in
                if event.phase == .ended {
                    coordinator?.onPhysicalCaptureButton?()
                }
            }
            view.addInteraction(captureInteraction)
        }

        return view
    }

    func updateUIView(_ uiView: MTKView, context: Context) {
        coordinator.mtkView = uiView
    }
}
