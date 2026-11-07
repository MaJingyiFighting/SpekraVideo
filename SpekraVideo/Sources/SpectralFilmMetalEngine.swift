import Foundation
import Metal
import MetalPerformanceShaders
import CoreVideo
import CoreImage

enum DiffusionFilterFamily: Int, CaseIterable, Equatable {
    case off = 0
    case blackProMist = 1
    case glimmerglass = 2
    case proMist = 3
    case cineBloom = 4

    var displayName: String {
        switch self {
        case .off:          return "无柔光镜"
        case .blackProMist: return "黑柔 BPM"
        case .glimmerglass: return "闪耀柔 GG"
        case .proMist:      return "经典白柔"
        case .cineBloom:    return "电影柔"
        }
    }

    var shapeSpec: (wC: Float, wH: Float, wB: Float, warmthBase: Float, totalGain: Float, haloUm: Float, bloomUm: Float) {
        switch self {
        case .off:
            return (1.0, 0.0, 0.0, 0.0, 0.0, 65.0, 260.0)
        case .glimmerglass:
            return (0.60, 0.30, 0.10, 0.00, 0.65, 50.0, 260.0)
        case .blackProMist:
            return (0.40, 0.47, 0.13, 0.65, 0.75, 95.0, 380.0)
        case .proMist:
            return (0.28, 0.42, 0.30, 0.40, 1.05, 150.0, 650.0)
        case .cineBloom:
            return (0.22, 0.30, 0.48, 0.85, 1.00, 200.0, 1000.0)
        }
    }

    func scatterFraction(strength: Float) -> Float {
        guard self != .off, strength > 0.001 else { return 0.0 }
        let breaks: [Float] = [0.125, 0.25, 0.5, 1.0, 2.0]
        let totals: [Float] = [0.10,  0.20, 0.35, 0.55, 0.75]
        let ls = log2(max(strength, 1e-4))
        let l0 = log2(breaks[0])
        let lLast = log2(breaks[breaks.count - 1])
        var base: Float = totals[0]
        if ls <= l0 {
            base = totals[0]
        } else if ls >= lLast {
            base = totals[totals.count - 1]
        } else {
            for i in 0..<(breaks.count - 1) {
                let a = log2(breaks[i]), b = log2(breaks[i + 1])
                if ls >= a && ls <= b {
                    let t = (ls - a) / max(b - a, 1e-5)
                    base = totals[i] + t * (totals[i + 1] - totals[i])
                    break
                }
            }
        }
        return min(max(base * shapeSpec.totalGain, 0.0), 0.95)
    }

    /// 核心权重 wC 保持在 100% 全分辨率锐利 raw 上，晕圈能量 wH 与柔雾能量 wB 作用于高斯平滑后的模糊纹理
    func channelStageWeights() -> (coreWeight: Float, med: (Float, Float, Float), wide: (Float, Float, Float)) {
        let s = shapeSpec
        let warmth = min(max(s.warmthBase, -1.5), 1.5)
        let axis: [Float] = [1.30, 0.15, -1.45]
        var med  = [Float](repeating: 0, count: 3)
        var wide = [Float](repeating: 0, count: 3)

        for c in 0..<3 {
            let wInnerRaw = max((1.0 / 3.0) * (1.0 - warmth * axis[c]), 0.0)
            let wMidRaw: Float = 1.0 / 3.0
            let wOuterRaw = max((1.0 / 3.0) * (1.0 + warmth * axis[c]), 0.0)
            let sumH = max(wInnerRaw + wMidRaw + wOuterRaw, 1e-6)
            let hInner = s.wH * (wInnerRaw / sumH)
            let hOuter = s.wH * ((wMidRaw + wOuterRaw) / sumH)

            med[c]  = hInner + hOuter * 0.65
            wide[c] = s.wB + hOuter * 0.35
        }
        return (
            coreWeight: s.wC,
            med:  (med[0],  med[1],  med[2]),
            wide: (wide[0], wide[1], wide[2])
        )
    }
}

struct SpectralFilmParameters: Equatable {
    var filmIndex: Int = 0                                 // 默认 Kodak Portra 160
    var paperIndex: Int = 0                                // 默认 Kodak Portra Endura
    var bwGradeIndex: Int = 3                              // 默认 Ilford Multigrade 2 号反差
    var upsamplingMode: Int = 0                            // 0 = Arctic 2026 Beta 04, 1 = Hanatos 2025
    var filmExposureEV: Float = 0.0                        // -2.5 ... +2.5 EV
    var printExposureEV: Float = 0.0                       // -1.5 ... +1.5 EV
    var magentaFilterShift: Float = 0.0                    // -25.0 ... +25.0 CC
    var yellowFilterShift: Float = 0.0                     // -25.0 ... +25.0 CC
    var halationAmount: Float = 1.0                        // 0.0 ... 2.0
    var grainAmount: Float = 1.0                           // 0.0 ... 2.0
    var diffusionFamily: DiffusionFilterFamily = .off      // 镜头柔光滤镜类型
    var diffusionStrength: Float = 0.5                     // 0.125(1/8), 0.25(1/4), 0.5(1/2), 1.0(1), 2.0(2)
    var splitCompareRatio: Float = 0.0                     // 0.0 关闭分屏，0.5 左右分屏对比
}

struct FrameColorMetadata: Equatable {
    var isAppleLog: Bool
    var isBT2020: Bool
    var inputColorSpaceName: String
}

private struct SpkFrameUniformsSwift {
    var frame_seed: UInt32
    var has_record_out: UInt32
    var halation_amount: Float
    var grain_amount: Float
    var split_ratio: Float
    var diffusion_ps: Float
    var grain_area_scale: Float
    var diff_core_weight: Float
    var cmy_min: (Float, Float, Float)
    var cmy_max: (Float, Float, Float)
    var diff_w_med: (Float, Float, Float)
    var diff_w_wide: (Float, Float, Float)
    var bounce_w1: Float
    var bounce_w23: Float
}

private struct EngineUniforms {
    var sourceMode: Int32
    var outputGamut: Int32
    var preserveExtendedHDR: Int32
    var reserved: Int32 = 0
}

final class SpectralFilmMetalEngine {
    let device: MTLDevice
    let commandQueue: MTLCommandQueue
    private var textureCache: CVMetalTextureCache?
    private lazy var ciContext = CIContext(mtlDevice: device, options: [.cacheIntermediates: false])
    private let stillQuarterExposurePipeline: MTLComputePipelineState
    private let stillDevelopPrintPipeline: MTLComputePipelineState

    private let quarterExposurePipeline: MTLComputePipelineState
    private let bakePrintLutPipeline: MTLComputePipelineState
    private let developPrintPipeline: MTLComputePipelineState
    let displayRenderPipeline: MTLRenderPipelineState

    private let spkContext: OpaquePointer

    private var tcLutStaging: [UInt16] = [UInt16](repeating: 0, count: 192 * 192 * 4)
    private let tcLutTex: MTLTexture
    private let cam16CmaxBuffer: MTLBuffer
    private let pass2UniformsBuffer: MTLBuffer
    private let printLutTex: MTLTexture

    private var cachedSetupKey: String = ""
    private var needsPrintLutBake: Bool = true
    private var cachedTcBMatrix: [Float] = [Float](repeating: 0, count: 9)
    private var cachedCmyBounds: [Float] = [-0.20, -0.20, -0.20, 2.60, 2.40, 2.75]
    private var cachedTcLutSide: UInt32 = 192
    private var cachedHalationSigmaUm: Float = 65.0
    private var cachedBounceDecay: Float = 0.5

    // 540x960 光学模糊算子缓存（保证最小模糊半径 >= 2.2 像素，彻底消除降采样网格痕迹）
    private var cachedMedBlur: MPSImageGaussianBlur?
    private var cachedMedSigmaPx: Float = -1.0
    private var cachedWideBlur: MPSImageGaussianBlur?
    private var cachedWideSigmaPx: Float = -1.0

    private var texWidth: Int = 0
    private var texHeight: Int = 0
    private var quarterExpTex: MTLTexture?
    private var haloBlurTex: MTLTexture?
    private var bloomBlurTex: MTLTexture?
    private var previewOutTextures: [MTLTexture] = []
    private var previewRingIndex: Int = 0

    private var frameCounter: UInt32 = 1

    init?() {
        guard let dev = MTLCreateSystemDefaultDevice(),
              let queue = dev.makeCommandQueue() else {
            return nil
        }
        self.device = dev
        self.commandQueue = queue

        var cache: CVMetalTextureCache?
        CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, dev, nil, &cache)
        self.textureCache = cache

        let resBase = Bundle.main.resourcePath ?? ""
        let engineDir: String
        if FileManager.default.fileExists(atPath: resBase + "/engine/spektrafilm_constants.bin") {
            engineDir = resBase + "/engine"
        } else {
            engineDir = resBase
        }
        guard let ctx = spk_ios_context_create(engineDir) else {
            return nil
        }
        self.spkContext = ctx

        guard let url = Bundle.main.url(forResource: "SpectralFilmShaders", withExtension: "msl"),
              let shaderSource = try? String(contentsOf: url, encoding: .utf8) else {
            spk_ios_context_destroy(ctx)
            return nil
        }

        let options = MTLCompileOptions()
        if #available(iOS 18.0, *) {
            options.mathMode = .fast
        } else {
            options.fastMathEnabled = true
        }

        guard let library = try? dev.makeLibrary(source: shaderSource, options: options),
              let fnStillQuarter = library.makeFunction(name: "spk_still_quarter_exposure_prepass"),
              let fnStillDevelop = library.makeFunction(name: "spk_still_develop_and_print_spectral"),
              let pStillQuarter = try? dev.makeComputePipelineState(function: fnStillQuarter),
              let pStillDevelop = try? dev.makeComputePipelineState(function: fnStillDevelop),
              let fnQuarter = library.makeFunction(name: "spk_quarter_exposure_prepass"),
              let fnBake = library.makeFunction(name: "spk_bake_print_lut_3d"),
              let fn2 = library.makeFunction(name: "spk_develop_and_print_spectral"),
              let vFn = library.makeFunction(name: "spk_fullscreen_vertex"),
              let fFn = library.makeFunction(name: "spk_fullscreen_fragment"),
              let pQuarter = try? dev.makeComputePipelineState(function: fnQuarter),
              let pBake = try? dev.makeComputePipelineState(function: fnBake),
              let p2 = try? dev.makeComputePipelineState(function: fn2) else {
            spk_ios_context_destroy(ctx)
            return nil
        }

        let rDesc = MTLRenderPipelineDescriptor()
        rDesc.vertexFunction = vFn
        rDesc.fragmentFunction = fFn
        rDesc.colorAttachments[0].pixelFormat = .bgra8Unorm

        let lut2DDesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba16Float,
            width: 192,
            height: 192,
            mipmapped: false
        )
        lut2DDesc.usage = [.shaderRead]

        let lut3DDesc = MTLTextureDescriptor()
        lut3DDesc.textureType = .type3D
        lut3DDesc.pixelFormat = .rgba16Float
        lut3DDesc.width = 64
        lut3DDesc.height = 64
        lut3DDesc.depth = 64
        lut3DDesc.usage = [.shaderRead, .shaderWrite]
        lut3DDesc.storageMode = .private

        let p2Bytes = Int(spk_ios_pass2_uniforms_size())
        guard let rp = try? dev.makeRenderPipelineState(descriptor: rDesc),
              let lut2DTex = dev.makeTexture(descriptor: lut2DDesc),
              let cmaxBuf = dev.makeBuffer(length: 128 * 360 * 4, options: .storageModeShared),
              let p2Buf = dev.makeBuffer(length: p2Bytes, options: .storageModeShared),
              let pLutTex = dev.makeTexture(descriptor: lut3DDesc) else {
            spk_ios_context_destroy(ctx)
            return nil
        }

        self.stillQuarterExposurePipeline = pStillQuarter
        self.stillDevelopPrintPipeline = pStillDevelop
        self.quarterExposurePipeline = pQuarter
        self.bakePrintLutPipeline = pBake
        self.developPrintPipeline = p2
        self.displayRenderPipeline = rp
        self.tcLutTex = lut2DTex
        self.cam16CmaxBuffer = cmaxBuf
        self.pass2UniformsBuffer = p2Buf
        self.printLutTex = pLutTex
    }

    deinit {
        spk_ios_context_destroy(spkContext)
    }

    private func updateSetupIfNeeded(
        params: SpectralFilmParameters,
        inputColorSpace: String
    ) {
        let fIdx = min(max(params.filmIndex, 0), SpectralCatalog.films.count - 1)
        let pIdx = min(max(params.paperIndex, 0), SpectralCatalog.papers.count - 1)
        let filmId = SpectralCatalog.films[fIdx].id
        let paperId = SpectralCatalog.papers[pIdx].id

        let key = "\(filmId)|\(paperId)|\(inputColorSpace)|\(params.upsamplingMode)|\(Int(round(params.printExposureEV * 100)))|\(Int(round(params.magentaFilterShift * 10)))|\(Int(round(params.yellowFilterShift * 10)))|\(params.bwGradeIndex)"
        if key == cachedSetupKey {
            return
        }

        var meta = SpkIosPass1Meta()
        let cmaxPtr = cam16CmaxBuffer.contents().assumingMemoryBound(to: Float.self)
        let p2Ptr = pass2UniformsBuffer.contents()

        let ok = tcLutStaging.withUnsafeMutableBufferPointer { lutBufPtr in
            spk_ios_prepare_tables(
                spkContext,
                filmId,
                paperId,
                inputColorSpace,
                Int32(params.upsamplingMode),
                Double(params.printExposureEV),
                Double(params.magentaFilterShift),
                Double(params.yellowFilterShift),
                Int32(params.bwGradeIndex),
                1920,
                &meta,
                lutBufPtr.baseAddress,
                cmaxPtr,
                p2Ptr
            )
        }
        guard ok else { return }

        if meta.tc_lut_updated != 0 {
            tcLutStaging.withUnsafeBytes { rawBytes in
                if let base = rawBytes.baseAddress {
                    tcLutTex.replace(
                        region: MTLRegionMake2D(0, 0, 192, 192),
                        mipmapLevel: 0,
                        withBytes: base,
                        bytesPerRow: 192 * 8
                    )
                }
            }
        }

        cachedSetupKey = key
        needsPrintLutBake = true
        cachedTcLutSide = meta.tc_lut_side
        cachedHalationSigmaUm = max(meta.halation_sigma_um, 40.0)
        cachedBounceDecay = max(meta.halation_bounce_decay, 0.3)

        withUnsafePointer(to: &meta.tc_b_matrix) { ptr in
            ptr.withMemoryRebound(to: Float.self, capacity: 9) { fPtr in
                for i in 0..<9 { cachedTcBMatrix[i] = fPtr[i] }
            }
        }
        withUnsafePointer(to: &meta.cmy_bounds) { ptr in
            ptr.withMemoryRebound(to: Float.self, capacity: 6) { fPtr in
                for i in 0..<6 { cachedCmyBounds[i] = fPtr[i] }
            }
        }
    }

    private func ensureOutputAndBlurTextures(width: Int, height: Int) {
        if width == texWidth && height == texHeight && quarterExpTex != nil && previewOutTextures.count == 3 {
            return
        }
        texWidth = width
        texHeight = height
        cachedMedBlur = nil;  cachedMedSigmaPx = -1.0
        cachedWideBlur = nil; cachedWideSigmaPx = -1.0

        // 光学晕圈模糊网格固定为约 540x960（足够平滑且仅占 4.1MB）
        let is4K = max(width, height) > 1920
        let blurDiv = is4K ? 4 : 2
        let qW = max(width / blurDiv, 1)
        let qH = max(height / blurDiv, 1)
        let qDesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba16Float,
            width: qW,
            height: qH,
            mipmapped: false
        )
        qDesc.usage = [.shaderRead, .shaderWrite]
        qDesc.storageMode = .private

        quarterExpTex = device.makeTexture(descriptor: qDesc)
        haloBlurTex   = device.makeTexture(descriptor: qDesc)
        bloomBlurTex  = device.makeTexture(descriptor: qDesc)

        let outDesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: width,
            height: height,
            mipmapped: false
        )
        outDesc.usage = [.shaderRead, .shaderWrite]
        outDesc.storageMode = .private

        var ring: [MTLTexture] = []
        for _ in 0..<3 {
            if let t = device.makeTexture(descriptor: outDesc) {
                ring.append(t)
            }
        }
        previewOutTextures = ring
    }

    private func blurKernel(cached: inout MPSImageGaussianBlur?, cachedSigma: inout Float, targetSigma: Float) -> MPSImageGaussianBlur {
        if let existing = cached, abs(targetSigma - cachedSigma) <= 0.05 {
            return existing
        }
        let b = MPSImageGaussianBlur(device: device, sigma: targetSigma)
        b.edgeMode = .clamp
        cached = b
        cachedSigma = targetSigma
        return b
    }

    func renderStillPhoto(
        inputCIImage: CIImage,
        params: SpectralFilmParameters,
        outputDisplayP3: Bool,
        preserveHDR: Bool
    ) -> CIImage? {
        let image = inputCIImage.transformed(by: CGAffineTransform(
            translationX: -inputCIImage.extent.minX,
            y: -inputCIImage.extent.minY
        ))
        let width = Int(round(image.extent.width))
        let height = Int(round(image.extent.height))
        guard width > 0, height > 0,
              let linearP3 = CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3),
              let targetSpace = CGColorSpace(name: outputDisplayP3
                  ? CGColorSpace.extendedLinearDisplayP3 : CGColorSpace.extendedLinearSRGB),
              let commandBuffer = commandQueue.makeCommandBuffer() else { return nil }
        let bounds = CGRect(x: 0, y: 0, width: width, height: height)

        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba16Float, width: width, height: height, mipmapped: false
        )
        descriptor.usage = [.shaderRead, .shaderWrite, .renderTarget]
        descriptor.storageMode = .private
        guard let input = device.makeTexture(descriptor: descriptor),
              let output = device.makeTexture(descriptor: descriptor) else { return nil }
        let blurScale = min(1.0, 960.0 / Double(max(width, height)))
        descriptor.width = max(Int(round(Double(width) * blurScale)), 1)
        descriptor.height = max(Int(round(Double(height) * blurScale)), 1)
        descriptor.usage = [.shaderRead, .shaderWrite]
        guard let quarter = device.makeTexture(descriptor: descriptor),
              let halo = device.makeTexture(descriptor: descriptor),
              let bloom = device.makeTexture(descriptor: descriptor) else { return nil }

        updateSetupIfNeeded(params: params, inputColorSpace: "Display P3")
        ciContext.render(image, to: input, commandBuffer: commandBuffer, bounds: bounds, colorSpace: linearP3)

        if needsPrintLutBake {
            guard let encoder = commandBuffer.makeComputeCommandEncoder() else { return nil }
            encoder.setComputePipelineState(bakePrintLutPipeline)
            encoder.setTexture(printLutTex, index: 0)
            encoder.setBuffer(pass2UniformsBuffer, offset: 0, index: 0)
            encoder.setBuffer(cam16CmaxBuffer, offset: 0, index: 1)
            encoder.setBytes(&cachedCmyBounds, length: 6 * 4, index: 2)
            encoder.dispatchThreadgroups(
                MTLSize(width: 8, height: 8, depth: 8),
                threadsPerThreadgroup: MTLSize(width: 8, height: 8, depth: 8)
            )
            encoder.endEncoding()
            needsPrintLutBake = false
        }

        var pass1Params = [Float](repeating: 0, count: 16)
        for i in 0..<9 { pass1Params[i] = cachedTcBMatrix[i] }
        pass1Params[9] = pow(2.0, params.filmExposureEV)
        pass1Params[10] = 2.0
        pass1Params[15] = Float(cachedTcLutSide)

        let diffusion = params.diffusionFamily.scatterFraction(strength: params.diffusionStrength)
        let weights = params.diffusionFamily.channelStageWeights()
        let rho = cachedBounceDecay
        let bounceSum = 1 + rho + rho * rho
        let longEdgeScale = Float(1920.0) / Float(max(width, height))
        frameCounter &+= 1
        var frameUniforms = SpkFrameUniformsSwift(
            frame_seed: frameCounter,
            has_record_out: 0,
            halation_amount: params.halationAmount,
            grain_amount: params.grainAmount,
            split_ratio: 0,
            diffusion_ps: diffusion,
            grain_area_scale: longEdgeScale * longEdgeScale,
            diff_core_weight: weights.coreWeight,
            cmy_min: (cachedCmyBounds[0], cachedCmyBounds[1], cachedCmyBounds[2]),
            cmy_max: (cachedCmyBounds[3], cachedCmyBounds[4], cachedCmyBounds[5]),
            diff_w_med: weights.med,
            diff_w_wide: weights.wide,
            bounce_w1: 1 / bounceSum,
            bounce_w23: (rho + rho * rho) / bounceSum
        )
        var engineUniforms = EngineUniforms(
            sourceMode: 2,
            outputGamut: outputDisplayP3 ? 1 : 0,
            preserveExtendedHDR: preserveHDR ? 1 : 0
        )
        let threadgroup = MTLSize(width: 16, height: 16, depth: 1)

        if params.halationAmount > 0.001 || diffusion > 0.001 {
            guard let encoder = commandBuffer.makeComputeCommandEncoder() else { return nil }
            encoder.setComputePipelineState(stillQuarterExposurePipeline)
            encoder.setTexture(input, index: 0)
            encoder.setTexture(input, index: 1)
            encoder.setTexture(tcLutTex, index: 2)
            encoder.setTexture(quarter, index: 3)
            encoder.setBytes(&pass1Params, length: pass1Params.count * 4, index: 0)
            encoder.dispatchThreadgroups(
                MTLSize(width: (quarter.width + 15) / 16, height: (quarter.height + 15) / 16, depth: 1),
                threadsPerThreadgroup: threadgroup
            )
            encoder.endEncoding()

            let pixelUm = Float(36000.0) / Float(max(quarter.width, quarter.height))
            let spec = params.diffusionFamily.shapeSpec
            let haloUm = diffusion > 0.001 ? max(cachedHalationSigmaUm, spec.haloUm * 0.6) : cachedHalationSigmaUm
            let mediumSigma = max((haloUm / pixelUm) * sqrt(max(params.halationAmount, 0.5)), 2.2)
            let bloomUm = diffusion > 0.001 ? max(haloUm * 2.2, spec.bloomUm * 0.45) : haloUm * 1.8
            let wideSigma = max(bloomUm / pixelUm, mediumSigma + 2.5)
            let nextSigma = max(sqrt(max(wideSigma * wideSigma - mediumSigma * mediumSigma, 2.25)), 2.0)
            let mediumBlur = blurKernel(cached: &cachedMedBlur, cachedSigma: &cachedMedSigmaPx, targetSigma: mediumSigma)
            let wideBlur = blurKernel(cached: &cachedWideBlur, cachedSigma: &cachedWideSigmaPx, targetSigma: nextSigma)
            mediumBlur.encode(commandBuffer: commandBuffer, sourceTexture: quarter, destinationTexture: halo)
            wideBlur.encode(commandBuffer: commandBuffer, sourceTexture: halo, destinationTexture: bloom)
        }

        guard let encoder = commandBuffer.makeComputeCommandEncoder() else { return nil }
        encoder.setComputePipelineState(stillDevelopPrintPipeline)
        encoder.setTexture(input, index: 0)
        encoder.setTexture(input, index: 1)
        encoder.setTexture(tcLutTex, index: 2)
        encoder.setTexture(halo, index: 3)
        encoder.setTexture(bloom, index: 4)
        encoder.setTexture(printLutTex, index: 5)
        encoder.setTexture(output, index: 6)
        encoder.setTexture(output, index: 7)
        encoder.setBytes(&pass1Params, length: pass1Params.count * 4, index: 0)
        encoder.setBuffer(pass2UniformsBuffer, offset: 0, index: 1)
        encoder.setBytes(&frameUniforms, length: MemoryLayout<SpkFrameUniformsSwift>.stride, index: 2)
        encoder.setBytes(&engineUniforms, length: MemoryLayout<EngineUniforms>.stride, index: 3)
        encoder.dispatchThreadgroups(
            MTLSize(width: (width + 15) / 16, height: (height + 15) / 16, depth: 1),
            threadsPerThreadgroup: threadgroup
        )
        encoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        guard commandBuffer.status == .completed else { return nil }
        return CIImage(mtlTexture: output, options: [.colorSpace: targetSpace])?.cropped(to: bounds)
    }

    func renderFrame(
        sampleBuffer: CVPixelBuffer,
        colorMeta: FrameColorMetadata,
        params: SpectralFilmParameters,
        recordingDestinationBuffer: CVPixelBuffer?,
        completion: @escaping (MTLTexture?, Double) -> Void
    ) {
        guard let cache = textureCache else {
            completion(nil, 0.0)
            return
        }

        let width = CVPixelBufferGetWidth(sampleBuffer)
        let height = CVPixelBufferGetHeight(sampleBuffer)
        guard width > 0 && height > 0 else {
            completion(nil, 0.0)
            return
        }

        ensureOutputAndBlurTextures(width: width, height: height)
        guard let qExpTex = quarterExpTex,
              let hBlurTex = haloBlurTex,
              let bBlurTex = bloomBlurTex,
              previewOutTextures.count == 3 else {
            completion(nil, 0.0)
            return
        }

        previewRingIndex = (previewRingIndex + 1) % 3
        let prevTex = previewOutTextures[previewRingIndex]

        let planeCount = CVPixelBufferGetPlaneCount(sampleBuffer)
        let pixelFormat = CVPixelBufferGetPixelFormatType(sampleBuffer)
        let isBiPlanar = planeCount >= 2
        let is10Bit = (pixelFormat == kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange ||
                       pixelFormat == kCVPixelFormatType_420YpCbCr10BiPlanarFullRange)
        let isFullRange = (pixelFormat == kCVPixelFormatType_420YpCbCr10BiPlanarFullRange ||
                           pixelFormat == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange)

        var yOrBgraTex: MTLTexture?
        var cbcrTex: MTLTexture?

        if isBiPlanar {
            let yFormat: MTLPixelFormat = is10Bit ? .r16Unorm : .r8Unorm
            let cbcrFormat: MTLPixelFormat = is10Bit ? .rg16Unorm : .rg8Unorm

            var cvY: CVMetalTexture?
            var cvCbCr: CVMetalTexture?
            let wY = CVPixelBufferGetWidthOfPlane(sampleBuffer, 0)
            let hY = CVPixelBufferGetHeightOfPlane(sampleBuffer, 0)
            let wUV = CVPixelBufferGetWidthOfPlane(sampleBuffer, 1)
            let hUV = CVPixelBufferGetHeightOfPlane(sampleBuffer, 1)

            CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault, cache, sampleBuffer, nil, yFormat, wY, hY, 0, &cvY)
            CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault, cache, sampleBuffer, nil, cbcrFormat, wUV, hUV, 1, &cvCbCr)
            if let cvY { yOrBgraTex = CVMetalTextureGetTexture(cvY) }
            if let cvCbCr { cbcrTex = CVMetalTextureGetTexture(cvCbCr) }
        } else {
            var cvBGRA: CVMetalTexture?
            CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault, cache, sampleBuffer, nil, .bgra8Unorm, width, height, 0, &cvBGRA)
            if let cvBGRA {
                yOrBgraTex = CVMetalTextureGetTexture(cvBGRA)
                cbcrTex = yOrBgraTex
            }
        }

        guard let inTex0 = yOrBgraTex, let inTex1 = cbcrTex else {
            completion(nil, 0.0)
            return
        }

        var recordOutTex: MTLTexture = prevTex
        var hasRecordOut: UInt32 = 0
        if let recBuf = recordingDestinationBuffer {
            var cvOut: CVMetalTexture?
            CVMetalTextureCacheCreateTextureFromImage(
                kCFAllocatorDefault,
                cache,
                recBuf,
                nil,
                .bgra8Unorm,
                CVPixelBufferGetWidth(recBuf),
                CVPixelBufferGetHeight(recBuf),
                0,
                &cvOut
            )
            if let cvOut, let wrapped = CVMetalTextureGetTexture(cvOut) {
                recordOutTex = wrapped
                hasRecordOut = 1
            }
        }

        updateSetupIfNeeded(
            params: params,
            inputColorSpace: colorMeta.inputColorSpaceName
        )

        var pass1Params = [Float](repeating: 0.0, count: 16)
        for i in 0..<9 { pass1Params[i] = cachedTcBMatrix[i] }
        pass1Params[9] = pow(2.0, params.filmExposureEV)
        pass1Params[10] = colorMeta.isAppleLog ? 1.0 : 0.0
        pass1Params[11] = isBiPlanar ? 1.0 : 0.0
        pass1Params[12] = isFullRange ? 1.0 : 0.0
        pass1Params[13] = is10Bit ? 1.0 : 0.0
        pass1Params[14] = colorMeta.isBT2020 ? 1.0 : 0.0
        pass1Params[15] = Float(cachedTcLutSide)

        let diffPs = params.diffusionFamily.scatterFraction(strength: params.diffusionStrength)
        let diffWeights = params.diffusionFamily.channelStageWeights()

        let rho = cachedBounceDecay
        let bSum = 1.0 + rho + rho * rho
        let bW1 = 1.0 / bSum
        let bW23 = (rho + rho * rho) / bSum

        let longEdgeScale = Float(1920.0) / Float(max(width, height))
        let grainAreaScale = longEdgeScale * longEdgeScale

        frameCounter &+= 1
        var frameUniforms = SpkFrameUniformsSwift(
            frame_seed: frameCounter,
            has_record_out: hasRecordOut,
            halation_amount: params.halationAmount,
            grain_amount: params.grainAmount,
            split_ratio: params.splitCompareRatio,
            diffusion_ps: diffPs,
            grain_area_scale: grainAreaScale,
            diff_core_weight: diffWeights.coreWeight,
            cmy_min: (cachedCmyBounds[0], cachedCmyBounds[1], cachedCmyBounds[2]),
            cmy_max: (cachedCmyBounds[3], cachedCmyBounds[4], cachedCmyBounds[5]),
            diff_w_med: diffWeights.med,
            diff_w_wide: diffWeights.wide,
            bounce_w1: bW1,
            bounce_w23: bW23
        )

        guard let cmdBuf = commandQueue.makeCommandBuffer() else {
            completion(nil, 0.0)
            return
        }

        if needsPrintLutBake {
            if let bakeEnc = cmdBuf.makeComputeCommandEncoder() {
                bakeEnc.setComputePipelineState(bakePrintLutPipeline)
                bakeEnc.setTexture(printLutTex, index: 0)
                bakeEnc.setBuffer(pass2UniformsBuffer, offset: 0, index: 0)
                bakeEnc.setBuffer(cam16CmaxBuffer, offset: 0, index: 1)
                bakeEnc.setBytes(&cachedCmyBounds, length: 6 * 4, index: 2)
                bakeEnc.dispatchThreadgroups(
                    MTLSize(width: 8, height: 8, depth: 8),
                    threadsPerThreadgroup: MTLSize(width: 8, height: 8, depth: 8)
                )
                bakeEnc.endEncoding()
            }
            needsPrintLutBake = false
        }

        let tgSize = MTLSize(width: 16, height: 16, depth: 1)

        if diffPs > 0.001 || params.halationAmount > 0.001 {
            let qGrid = MTLSize(
                width: (qExpTex.width + 15) / 16,
                height: (qExpTex.height + 15) / 16,
                depth: 1
            )
            if let encQ = cmdBuf.makeComputeCommandEncoder() {
                encQ.setComputePipelineState(quarterExposurePipeline)
                encQ.setTexture(inTex0, index: 0)
                encQ.setTexture(inTex1, index: 1)
                encQ.setTexture(tcLutTex, index: 2)
                encQ.setTexture(qExpTex, index: 3)
                encQ.setBytes(&pass1Params, length: pass1Params.count * 4, index: 0)
                encQ.dispatchThreadgroups(qGrid, threadsPerThreadgroup: tgSize)
                encQ.endEncoding()
            }

            // 在 540x960 模糊网格上保证最小高斯半径 >= 2.2 像素，彻底消除网格痕迹
            let qPxUm: Float = 36000.0 / Float(max(qExpTex.width, qExpTex.height))
            let spec = params.diffusionFamily.shapeSpec
            let haloUm = diffPs > 0.001 ? max(cachedHalationSigmaUm, spec.haloUm * 0.6) : cachedHalationSigmaUm
            let targetMedQPx = max((haloUm / qPxUm) * sqrt(max(params.halationAmount, 0.5)), 2.2)
            let bloomUm = diffPs > 0.001 ? max(haloUm * 2.2, spec.bloomUm * 0.45) : (haloUm * 1.8)
            let targetWideQPx = max(bloomUm / qPxUm, targetMedQPx + 2.5)

            let step2Sigma = max(targetMedQPx, 2.2)
            let step3Sigma = max(sqrt(max(targetWideQPx * targetWideQPx - step2Sigma * step2Sigma, 2.25)), 2.0)

            let b2 = blurKernel(cached: &cachedMedBlur,  cachedSigma: &cachedMedSigmaPx,  targetSigma: step2Sigma)
            let b3 = blurKernel(cached: &cachedWideBlur, cachedSigma: &cachedWideSigmaPx, targetSigma: step3Sigma)

            b2.encode(commandBuffer: cmdBuf, sourceTexture: qExpTex,  destinationTexture: hBlurTex)
            b3.encode(commandBuffer: cmdBuf, sourceTexture: hBlurTex, destinationTexture: bBlurTex)
        }

        let mainGrid = MTLSize(
            width: (width + 15) / 16,
            height: (height + 15) / 16,
            depth: 1
        )
        if let encMain = cmdBuf.makeComputeCommandEncoder() {
            encMain.setComputePipelineState(developPrintPipeline)
            encMain.setTexture(inTex0, index: 0)
            encMain.setTexture(inTex1, index: 1)
            encMain.setTexture(tcLutTex, index: 2)
            encMain.setTexture(hBlurTex, index: 3)
            encMain.setTexture(bBlurTex, index: 4)
            encMain.setTexture(printLutTex, index: 5)
            encMain.setTexture(prevTex, index: 6)
            encMain.setTexture(recordOutTex, index: 7)
            encMain.setBytes(&pass1Params, length: pass1Params.count * 4, index: 0)
            encMain.setBuffer(pass2UniformsBuffer, offset: 0, index: 1)
            encMain.setBytes(&frameUniforms, length: MemoryLayout<SpkFrameUniformsSwift>.stride, index: 2)
            encMain.dispatchThreadgroups(mainGrid, threadsPerThreadgroup: tgSize)
            encMain.endEncoding()
        }

        cmdBuf.addCompletedHandler { buffer in
            let gpuMs = max((buffer.gpuEndTime - buffer.gpuStartTime) * 1000.0, 0.0)
            completion(prevTex, gpuMs)
        }
        cmdBuf.commit()
    }
}
