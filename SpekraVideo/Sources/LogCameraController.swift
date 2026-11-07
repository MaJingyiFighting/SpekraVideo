import Foundation
import AVFoundation
import Photos
import UIKit
import CoreMotion
import CoreImage
import ImageIO
import UniformTypeIdentifiers

enum CaptureMode: String, CaseIterable, Identifiable {
    case photo
    case video
    var id: Self { self }
    var label: String { self == .photo ? "照片" : "视频" }
}

struct NativePhotoDimension: Identifiable, Equatable, Hashable {
    let width: Int32
    let height: Int32
    var id: String { "\(width)x\(height)" }
    var megapixels: Int {
        let raw = Int(round(Double(width) * Double(height) / 1_000_000.0))
        if raw == 49 { return 48 }
        return raw
    }
    var shortLabel: String { "\(megapixels)MP" }
    var menuTitle: String { "\(megapixels)MP (\(width)×\(height))" }
    var cmDimensions: CMVideoDimensions {
        CMVideoDimensions(width: width, height: height)
    }
}

enum PhotoCaptureFormat: String, CaseIterable, Identifiable {
    case heif
    case proRAW
    case bayerRAW
    var id: Self { self }
    var shortLabel: String {
        switch self {
        case .heif: return "标准"
        case .proRAW: return "ProRAW"
        case .bayerRAW: return "RAW"
        }
    }
    var menuTitle: String {
        switch self {
        case .heif: return "仅直出成片"
        case .proRAW: return "Apple ProRAW (12-bit)"
        case .bayerRAW: return "光学 RAW (DNG)"
        }
    }
}

enum ExportFileFormat: String, CaseIterable, Identifiable {
    case heif
    case jpeg
    case tiff16
    var id: Self { self }
    var label: String {
        switch self {
        case .heif: return "HEIF"
        case .jpeg: return "JPEG"
        case .tiff16: return "TIFF 16-bit"
        }
    }
    var fileType: UTType {
        switch self {
        case .heif: return .heic
        case .jpeg: return .jpeg
        case .tiff16: return .tiff
        }
    }
}

enum ExportColorGamut: String, CaseIterable, Identifiable {
    case displayP3
    case sRGB
    var id: Self { self }
    var shortLabel: String { self == .displayP3 ? "P3" : "sRGB" }
    var menuTitle: String { self == .displayP3 ? "Display P3 广色域" : "sRGB 标准色域" }
}

enum ExportDimensionLimit: String, CaseIterable, Identifiable {
    case original
    case longEdge2560
    case longEdge2048
    case longEdge1920
    case shortEdge1440
    case shortEdge1080
    var id: Self { self }
    var label: String {
        switch self {
        case .original: return "原始尺寸"
        case .longEdge2560: return "长边 2560px"
        case .longEdge2048: return "长边 2048px"
        case .longEdge1920: return "长边 1920px"
        case .shortEdge1440: return "短边 1440px"
        case .shortEdge1080: return "短边 1080px"
        }
    }
    func scale(for size: CGSize) -> CGFloat {
        let longEdge = max(size.width, size.height)
        let shortEdge = min(size.width, size.height)
        guard longEdge > 0, shortEdge > 0 else { return 1.0 }
        switch self {
        case .original: return 1.0
        case .longEdge2560: return min(1.0, 2560.0 / longEdge)
        case .longEdge2048: return min(1.0, 2048.0 / longEdge)
        case .longEdge1920: return min(1.0, 1920.0 / longEdge)
        case .shortEdge1440: return min(1.0, 1440.0 / shortEdge)
        case .shortEdge1080: return min(1.0, 1080.0 / shortEdge)
        }
    }
}

enum SocialExportPreset: String, CaseIterable, Identifiable {
    case originalMaster
    case xiaohongshu
    case wechatMoments
    case weibo
    case qzone
    case instagram
    case threads
    case tiktokDouyin
    var id: Self { self }
    var name: String {
        switch self {
        case .originalMaster: return "无损原画"
        case .xiaohongshu: return "小红书"
        case .wechatMoments: return "微信朋友圈"
        case .weibo: return "微博"
        case .qzone: return "QQ空间"
        case .instagram: return "Instagram"
        case .threads: return "Threads"
        case .tiktokDouyin: return "TikTok / 抖音"
        }
    }
    var menuTitle: String {
        name
    }
    var format: ExportFileFormat {
        switch self {
        case .wechatMoments, .weibo, .qzone, .tiktokDouyin: return .jpeg
        default: return .heif
        }
    }
    var gamut: ExportColorGamut {
        format == .jpeg ? .sRGB : .displayP3
    }
    var dimension: ExportDimensionLimit {
        switch self {
        case .originalMaster: return .original
        case .xiaohongshu: return .longEdge2560
        case .wechatMoments, .instagram, .tiktokDouyin: return .shortEdge1080
        case .weibo: return .longEdge2048
        case .qzone: return .longEdge1920
        case .threads: return .shortEdge1440
        }
    }
    var hdrEnabled: Bool {
        format == .heif
    }
    var requiresProPurchase: Bool {
        self != .originalMaster
    }
    var specBadge: String {
        switch self {
        case .originalMaster: return "原始像素 · P3 · HDR"
        case .xiaohongshu: return "长边2560 · P3 · HDR"
        case .wechatMoments: return "短边1080 · sRGB · 96% JPG"
        case .weibo: return "长边2048 · sRGB · 96% JPG"
        case .qzone: return "长边1920 · sRGB · 96% JPG"
        case .instagram: return "短边1080 · P3 · HDR"
        case .threads: return "短边1440 · P3 · HDR"
        case .tiktokDouyin: return "短边1080 · sRGB · 96% JPG"
        }
    }
}

private final class PhotoCaptureProcessor: NSObject, AVCapturePhotoCaptureDelegate {
    let onShutter: () -> Void
    let completion: (Result<(Data, Bool), Error>) -> Void
    private var result: Result<(Data, Bool), Error>?

    init(onShutter: @escaping () -> Void, completion: @escaping (Result<(Data, Bool), Error>) -> Void) {
        self.onShutter = onShutter
        self.completion = completion
    }

    func photoOutput(_ output: AVCapturePhotoOutput, willCapturePhotoFor resolvedSettings: AVCaptureResolvedPhotoSettings) {
        onShutter()
    }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        if let error {
            result = .failure(error)
        } else if let data = photo.fileDataRepresentation() {
            result = .success((data, photo.isRawPhoto))
        }
    }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishCaptureFor resolvedSettings: AVCaptureResolvedPhotoSettings, error: Error?) {
        if let error {
            completion(.failure(error))
        } else if let result {
            completion(result)
        } else {
            completion(.failure(NSError(domain: "SpekraVideo.Photo", code: 1, userInfo: [NSLocalizedDescriptionKey: "照片读取失败"])))
        }
    }
}

enum ActiveControlDrawer: Equatable {
    case lensZoom
    case shutter
    case iso
    case whiteBalance
    case evBias
    case filmLook
}

enum VideoCodecPreset: Int, CaseIterable, Equatable {
    case hevc25 = 0
    case hevc50 = 1
    case hevc90 = 2
    case proRes422 = 3

    var menuTitle: String {
        switch self {
        case .hevc25:    return "HEVC 10-bit · 25M (轻量)"
        case .hevc50:    return "HEVC 10-bit · 50M (标准)"
        case .hevc90:    return "HEVC 10-bit · 90M (高码率)"
        case .proRes422: return "Apple ProRes 422 (母版)"
        }
    }

    var shortBadge: String {
        switch self {
        case .hevc25:    return "HEVC 25M"
        case .hevc50:    return "HEVC 50M"
        case .hevc90:    return "HEVC 90M"
        case .proRes422: return "ProRes 422"
        }
    }

    func targetBitrate(is4K: Bool, fps: Int) -> Int {
        let fpsScale = fps >= 60 ? 1.3 : 1.0
        let baseMbps: Double
        switch (self, is4K) {
        case (.hevc25, false):    baseMbps = 25
        case (.hevc25, true):     baseMbps = 60
        case (.hevc50, false):    baseMbps = 50
        case (.hevc50, true):     baseMbps = 110
        case (.hevc90, false):    baseMbps = 90
        case (.hevc90, true):     baseMbps = 180
        case (.proRes422, false): baseMbps = 150
        case (.proRes422, true):  baseMbps = 420
        }
        return Int(baseMbps * 1_000_000.0 * fpsScale)
    }
}

struct LensOption: Identifiable, Equatable {
    let id: String
    let mmTitle: String         // "13mm", "24mm", "48mm", "120mm", "前置"
    let zoomLabel: String       // "0.5×", "1×", "2×", "5×", "前置"
    let displayZoom: Float      // 等效主摄倍数 (0.5, 1.0, 2.0, 5.0)
    let focalMM: Int            // 等效 35mm 焦距
    let deviceType: AVCaptureDevice.DeviceType
    let position: AVCaptureDevice.Position
    let nativeZoom: CGFloat
}

final class CameraTelemetry: ObservableObject {
    @Published var liveISO: Int = 100
    @Published var liveShutterDenom: Int = 60
    @Published var liveAperture: Float = 1.8
    @Published var liveKelvin: Int = 5200
    @Published var liveTint: Int = 0
    @Published var recordingSeconds: Double = 0.0
}

final class HorizonLevelModel: ObservableObject {
    @Published var levelAngle: Double = 0.0
    @Published var isLevel: Bool = false
}

final class LogCameraController: NSObject, ObservableObject {
    @Published var params = SpectralFilmParameters() {
        didSet {
            paramsLock.lock()
            paramsSnapshot = params
            paramsLock.unlock()
        }
    }
    @Published var selectedCategory: FilmCategory = .colorNegative
    @Published var captureMode: CaptureMode = .photo
    @Published var availablePhotoDimensions: [NativePhotoDimension] = [NativePhotoDimension(width: 4032, height: 3024)]
    @Published var selectedPhotoDimension: NativePhotoDimension = NativePhotoDimension(width: 4032, height: 3024)
    @Published var availablePhotoCaptureFormats: [PhotoCaptureFormat] = [.heif]
    @Published var selectedPhotoCaptureFormat: PhotoCaptureFormat = .heif
    @Published var saveOriginalRawDNG: Bool = false

    @Published var selectedExportPreset: SocialExportPreset? = .originalMaster
    @Published var exportFileFormat: ExportFileFormat = .heif
    @Published var exportColorGamut: ExportColorGamut = .displayP3
    @Published var exportDimensionLimit: ExportDimensionLimit = .original
    @Published var exportHDREnabled: Bool = true
    @Published var isCapturingPhoto: Bool = false
    @Published var shutterCurtainOpacity: Double = 0.0

    @Published var activeDrawer: ActiveControlDrawer? = nil
    @Published var filmSubTab: Int = 0
    @Published var captureAngle: CGFloat = 90
    @Published var showProPaywall: Bool = false

    @Published var focusReticlePoint: CGPoint? = nil
    @Published var focusReticleID: Int = 0

    @Published var showGridAndLevel: Bool = true {
        didSet { updateMotionState() }
    }

    @Published var lenses: [LensOption] = []
    @Published var selectedLensId: String = "back_24"
    @Published var displayZoom: Float = 1.0
    var wheelDragStartZoom: Float? = nil
    var wheelLastHapticTenth: Int = -1
    var wheelAutoCollapseGen: Int = 0
    @Published var isFrontCamera: Bool = false
    private var telephotoBaseZoom: Float = 5.0
    private var pinchStartZoom: Float = 1.0
    private var pendingLensSwitchWork: DispatchWorkItem?
    private var lastZoomDetent: Float = 1.0
    private let selectionFeedback = UISelectionFeedbackGenerator()

    @Published var is4K: Bool = false {
        didSet { if oldValue != is4K { reconfigureDevice() } }
    }
    @Published var fps: Int = 30 {
        didSet { if oldValue != fps { reconfigureDevice() } }
    }
    @Published var lockFrameRate: Bool = false {
        didSet { if oldValue != lockFrameRate { applyFrameRate() } }
    }
    @Published var codecPreset: VideoCodecPreset = .hevc50
    @Published var preferAppleLog: Bool = true {
        didSet { if oldValue != preferAppleLog { reconfigureDevice() } }
    }
    @Published var isAppleLogActive: Bool = false
    @Published var saveRawLogAlongside: Bool = false

    static let shutterStops: [Int] = [24, 30, 48, 50, 60, 80, 100, 120, 160, 200, 250, 320, 400, 500, 640, 800, 1000, 1600, 2000, 4000]
    static let photoShutterStops: [Int] = [4, 8, 15, 24, 30, 48, 50, 60, 80, 100, 125, 160, 200, 250, 320, 400, 500, 640, 800, 1000, 1600, 2000, 4000, 8000]
    static let isoStops: [Int] = [50, 64, 80, 100, 125, 160, 200, 250, 320, 400, 500, 640, 800, 1000, 1250, 1600, 2000, 2500, 3200]
    static let wbStops: [Int] = Array(stride(from: 2600, through: 7800, by: 100))

    @Published var evBias: Float = 0.0 {
        didSet { applyExposure() }
    }
    @Published var shutterDenom: Int = 0 {
        didSet {
            if isExposureLocked { isExposureLocked = false }
            applyExposure()
        }
    }
    @Published var isoValue: Int = 0 {
        didSet {
            if isExposureLocked { isExposureLocked = false }
            applyExposure()
        }
    }
    @Published var isExposureLocked: Bool = false {
        didSet { applyExposure() }
    }

    @Published var wbKelvin: Float = 0 {
        didSet {
            if wbKelvin > 0 && isWBLocked { isWBLocked = false }
            applyWhiteBalance()
        }
    }
    @Published var isWBLocked: Bool = false {
        didSet { applyWhiteBalance() }
    }

    @Published var isRecording: Bool = false
    @Published var statusToast: String? = nil

    let telemetry = CameraTelemetry()
    let levelModel = HorizonLevelModel()
    let engine: SpectralFilmMetalEngine?
    let canvasCoordinator: MetalCanvasCoordinator?

    private let paramsLock = NSLock()
    private var paramsSnapshot = SpectralFilmParameters()

    private let session = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "app.spekravideo.cam.session", qos: .userInteractive)
    private let videoOutputQueue = DispatchQueue(label: "app.spekravideo.cam.video", qos: .userInteractive)
    private let audioOutputQueue = DispatchQueue(label: "app.spekravideo.cam.audio", qos: .userInteractive)
    private let photoQueue = DispatchQueue(label: "app.spekravideo.cam.photo", qos: .userInitiated)
    private lazy var photoCIContext = CIContext(options: [
        .cacheIntermediates: false,
        .workingColorSpace: CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)!
    ])
    private var photoCaptures: [Int64: PhotoCaptureProcessor] = [:]
    private lazy var photoEngine = SpectralFilmMetalEngine()
    private var pendingSessionChanges = 0
    private var isChangingSession: Bool { pendingSessionChanges > 0 }

    private var videoDevice: AVCaptureDevice?
    private var videoInput: AVCaptureDeviceInput?
    private var activeDeviceType: AVCaptureDevice.DeviceType = .builtInWideAngleCamera
    private var currentOutputPixelFormat: OSType = 0
    private let videoOutput = AVCaptureVideoDataOutput()
    private var photoOutput = AVCapturePhotoOutput()
    private let audioOutput = AVCaptureAudioDataOutput()

    private var rotationCoordinator: AVCaptureDevice.RotationCoordinator?
    private var rotationObservation: NSKeyValueObservation?
    private let motionManager = CMMotionManager()
    private var smoothedLevelAngle: Double = 0.0
    private var lastLevelHapticTime: CFTimeInterval = 0

    private let renderSemaphore = DispatchSemaphore(value: 2)
    private var frameCountForUI: Int = 0

    private let recordingLock = NSLock()
    private var isRecordingInternal: Bool = false
    private var recordingAngleSnapshot: CGFloat = 90
    private var filmAssetWriter: AVAssetWriter?
    private var filmVideoInput: AVAssetWriterInput?
    private var filmAudioInput: AVAssetWriterInput?
    private var filmPixelBufferAdaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var filmOutputURL: URL?
    private var filmSessionStarted: Bool = false
    private var recordingStartPTS: CMTime = .invalid

    private var rawLogAssetWriter: AVAssetWriter?
    private var rawLogVideoInput: AVAssetWriterInput?
    private var rawLogOutputURL: URL?
    private var rawLogSessionStarted: Bool = false

    override init() {
        let eng = SpectralFilmMetalEngine()
        self.engine = eng
        let coord = eng.map { MetalCanvasCoordinator(engine: $0) }
        self.canvasCoordinator = coord
        super.init()

        coord?.onTapViewfinder = { [weak self] normPt, viewPt in
            guard let self else { return }
            if self.activeDrawer != nil {
                self.activeDrawer = nil
            }
            self.focusAndExpose(atNormalizedPortraitPoint: normPt, viewPoint: viewPt)
        }
        coord?.onPinchZoom = { [weak self] scale, state in
            guard let self else { return }
            if state == .began {
                self.pinchStartZoom = self.displayZoom
            } else if state == .changed {
                self.setDisplayZoom(self.pinchStartZoom * Float(scale), allowLensSwitch: !self.isRecording)
            }
        }
        coord?.onPhysicalCaptureButton = { [weak self] in
            guard let self else { return }
            if self.captureMode == .photo {
                self.capturePhoto()
            } else {
                self.toggleRecording()
            }
        }
        NotificationCenter.default.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            self.sessionQueue.async {
                if self.session.isRunning { self.session.stopRunning() }
            }
        }
        NotificationCenter.default.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            self.sessionQueue.async {
                if !self.session.isRunning { self.session.startRunning() }
            }
        }
    }

    var currentFocalMMText: String {
        if isFrontCamera { return "前置 24mm" }
        let mm = Int(round(24.0 * Double(displayZoom)))
        return "\(mm)mm"
    }

    func selectFilm(index: Int) {
        guard index >= 0 && index < SpectralCatalog.films.count else { return }
        var next = params
        next.filmIndex = index
        let film = SpectralCatalog.films[index]
        if let defaultPaperIdx = SpectralCatalog.papers.firstIndex(where: { $0.id == film.defaultPaperId }) {
            next.paperIndex = defaultPaperIdx
        }
        params = next
    }

    func start() {
        DispatchQueue.main.async {
            UIApplication.shared.isIdleTimerDisabled = true
        }
        updateMotionState()
        AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
            guard let self, granted else { return }
            AVCaptureDevice.requestAccess(for: .audio) { _ in }
            PHPhotoLibrary.requestAuthorization(for: .addOnly) { _ in }
            self.sessionQueue.async {
                self.setupSessionIfNeeded()
                if !self.session.isRunning {
                    self.session.startRunning()
                }
            }
        }
    }

    // MARK: - 独立状态模型的电子水平仪（仅当倾角变化 >= 0.15° 时触发局部胶囊重绘）

    private func updateMotionState() {
        if showGridAndLevel && motionManager.isAccelerometerAvailable {
            motionManager.accelerometerUpdateInterval = 1.0 / 20.0
            motionManager.startAccelerometerUpdates(to: .main) { [weak self] data, _ in
                guard let self, let a = data?.acceleration else { return }
                let localGx: Double
                let localGy: Double
                if self.captureAngle == 0 {
                    localGx = -a.y
                    localGy = -a.x
                } else if self.captureAngle == 180 {
                    localGx = a.y
                    localGy = a.x
                } else {
                    localGx = a.x
                    localGy = -a.y
                }
                guard hypot(localGx, localGy) > 0.25 else { return }
                let deg = atan2(localGx, localGy) * 180.0 / .pi
                let smoothed = self.smoothedLevelAngle * 0.65 + deg * 0.35
                self.smoothedLevelAngle = smoothed
                let nowLevel = abs(smoothed) <= 1.0
                if nowLevel && !self.levelModel.isLevel {
                    let now = CACurrentMediaTime()
                    if now - self.lastLevelHapticTime > 0.7 {
                        self.lastLevelHapticTime = now
                        self.selectionFeedback.selectionChanged()
                    }
                }
                if abs(smoothed - self.levelModel.levelAngle) >= 0.15 || nowLevel != self.levelModel.isLevel {
                    self.levelModel.levelAngle = smoothed
                    self.levelModel.isLevel = nowLevel
                }
            }
        } else {
            motionManager.stopAccelerometerUpdates()
        }
    }

    // MARK: - 原生虚拟多摄设备（builtInTripleCamera）无缝零卡顿变焦

    private func preferredBackCameraDevice() -> AVCaptureDevice? {
        let types: [AVCaptureDevice.DeviceType] = [
            .builtInTripleCamera,
            .builtInDualWideCamera,
            .builtInDualCamera,
            .builtInWideAngleCamera
        ]
        for t in types {
            if let dev = AVCaptureDevice.default(t, for: .video, position: .back) {
                return dev
            }
        }
        return nil
    }

    private func buildLensOptions() -> [LensOption] {
        var list: [LensOption] = []
        let backDev = preferredBackCameraDevice()
        let backType = backDev?.deviceType ?? .builtInWideAngleCamera
        let mult = Float(max(backDev?.displayVideoZoomFactorMultiplier ?? 1.0, 0.1))

        if AVCaptureDevice.default(.builtInUltraWideCamera, for: .video, position: .back) != nil {
            list.append(LensOption(id: "back_13", mmTitle: "13mm", zoomLabel: "0.5×", displayZoom: 0.5, focalMM: 13, deviceType: backType, position: .back, nativeZoom: CGFloat(0.5 / mult)))
        }
        if AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) != nil {
            list.append(LensOption(id: "back_24", mmTitle: "24mm", zoomLabel: "1×", displayZoom: 1.0, focalMM: 24, deviceType: backType, position: .back, nativeZoom: CGFloat(1.0 / mult)))
            list.append(LensOption(id: "back_48", mmTitle: "48mm", zoomLabel: "2×", displayZoom: 2.0, focalMM: 48, deviceType: backType, position: .back, nativeZoom: CGFloat(2.0 / mult)))
        }
        if AVCaptureDevice.default(.builtInTelephotoCamera, for: .video, position: .back) != nil {
            var teleZ: Float = 5.0
            if let triple = AVCaptureDevice.default(.builtInTripleCamera, for: .video, position: .back) {
                let factors = triple.virtualDeviceSwitchOverVideoZoomFactors.map { Float(truncating: $0) }
                if let f = factors.first, let l = factors.last, f > 0.1, factors.count >= 2 {
                    teleZ = round((l / f) * 10.0) / 10.0
                }
            }
            self.telephotoBaseZoom = max(teleZ, 3.0)
            let mm = Int(round(24.0 * Double(self.telephotoBaseZoom)))
            let zLbl = self.telephotoBaseZoom == floor(self.telephotoBaseZoom) ? "\(Int(self.telephotoBaseZoom))×" : String(format: "%.1f×", self.telephotoBaseZoom)
            list.append(LensOption(id: "back_tele", mmTitle: "\(mm)mm", zoomLabel: zLbl, displayZoom: self.telephotoBaseZoom, focalMM: mm, deviceType: backType, position: .back, nativeZoom: CGFloat(self.telephotoBaseZoom / mult)))
        }
        if AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front) != nil {
            list.append(LensOption(id: "front", mmTitle: "前置", zoomLabel: "前置", displayZoom: 1.0, focalMM: 24, deviceType: .builtInWideAngleCamera, position: .front, nativeZoom: 1.0))
        }
        return list
    }

    private var isConfigured = false

    private func setupSessionIfNeeded() {
        guard !isConfigured else { return }
        isConfigured = true

        let discovered = buildLensOptions()
        DispatchQueue.main.async { self.lenses = discovered }

        session.beginConfiguration()
        session.automaticallyConfiguresCaptureDeviceForWideColor = false

        if let aDevice = AVCaptureDevice.default(for: .audio),
           let aInput = try? AVCaptureDeviceInput(device: aDevice),
           session.canAddInput(aInput) {
            session.addInput(aInput)
        }

        videoOutput.alwaysDiscardsLateVideoFrames = true
        videoOutput.setSampleBufferDelegate(self, queue: videoOutputQueue)
        if session.canAddOutput(videoOutput) { session.addOutput(videoOutput) }

        audioOutput.setSampleBufferDelegate(self, queue: audioOutputQueue)
        if session.canAddOutput(audioOutput) { session.addOutput(audioOutput) }

        let initialLens = discovered.first(where: { $0.id == "back_24" }) ?? discovered.first
        if let lens = initialLens {
            attachLensLocked(lens)
        }
        session.commitConfiguration()
    }

    func selectLens(_ lens: LensOption) {
        guard !isCapturingPhoto, !isChangingSession else { return }
        selectionFeedback.selectionChanged()
        if lens.position == .front {
            guard !isRecording else {
                showToast("录制中不可切换前后摄像头")
                return
            }
            selectedLensId = lens.id
            isFrontCamera = true
            displayZoom = 1.0
            sessionQueue.async { [weak self] in
                guard let self else { return }
                self.updateSessionConfiguration {
                    self.attachLensLocked(lens)
                }
            }
            return
        }

        if isFrontCamera {
            guard !isRecording else {
                showToast("录制中不可切换前后摄像头")
                return
            }
            isFrontCamera = false
            selectedLensId = lens.id
            displayZoom = lens.displayZoom
            sessionQueue.async { [weak self] in
                guard let self else { return }
                self.updateSessionConfiguration {
                    self.attachLensLocked(lens)
                }
            }
            return
        }

        selectedLensId = lens.id
        setDisplayZoom(lens.displayZoom, allowLensSwitch: true, animatedRamp: true)
    }

    func setDisplayZoom(_ rawDisplayZoom: Float, allowLensSwitch: Bool, animatedRamp: Bool = false) {
        guard !isCapturingPhoto, !isChangingSession else { return }
        let minZ: Float = isFrontCamera ? 1.0 : (lenses.contains(where: { $0.id == "back_13" }) ? 0.5 : 1.0)
        let maxZ: Float = isFrontCamera ? 3.0 : 15.0
        var clamped = min(max(rawDisplayZoom, minZ), maxZ)

        if !animatedRamp {
            let detents: [Float] = [0.5, 1.0, 1.5, 2.0, 3.0, telephotoBaseZoom]
            for d in detents {
                if abs(clamped - d) < 0.03 && abs(lastZoomDetent - d) >= 0.03 {
                    clamped = d
                    selectionFeedback.selectionChanged()
                    break
                }
            }
        }
        lastZoomDetent = clamped
        if abs(displayZoom - clamped) > 0.005 {
            displayZoom = clamped
        }

        if !isFrontCamera {
            let nextLensId: String
            if clamped < 0.98 {
                nextLensId = "back_13"
            } else if clamped >= telephotoBaseZoom - 0.05 && lenses.contains(where: { $0.id == "back_tele" }) {
                nextLensId = "back_tele"
            } else if clamped >= 1.95 {
                nextLensId = "back_48"
            } else {
                nextLensId = "back_24"
            }
            if selectedLensId != nextLensId {
                selectedLensId = nextLensId
            }
        }

        // 在虚拟多摄设备（builtInTripleCamera / builtInDualWideCamera）上直接调整 videoZoomFactor，全程不停止 Session、不拆装 Input
        sessionQueue.async { [weak self] in
            guard let self, let dev = self.videoDevice else { return }
            let targetNativeZ = self.nativeZoomFactor(forDisplayZoom: clamped, on: dev)
            do {
                try dev.lockForConfiguration()
                if animatedRamp {
                    dev.ramp(toVideoZoomFactor: targetNativeZ, withRate: 28.0)
                } else {
                    if dev.isRampingVideoZoom {
                        dev.cancelVideoZoomRamp()
                    }
                    dev.videoZoomFactor = targetNativeZ
                }
                dev.unlockForConfiguration()
            } catch {}
        }
    }

    private func nativeZoomFactor(forDisplayZoom z: Float, on device: AVCaptureDevice) -> CGFloat {
        let mult = Float(max(device.displayVideoZoomFactorMultiplier, 0.1))
        let raw = CGFloat(z / mult)
        let maxAllowed = min(device.maxAvailableVideoZoomFactor, device.activeFormat.videoMaxZoomFactor, 30.0)
        return min(max(raw, device.minAvailableVideoZoomFactor), maxAllowed)
    }

    private func attachLensLocked(_ lens: LensOption) {
        let targetDev: AVCaptureDevice?
        if lens.position == .front {
            targetDev = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front)
        } else {
            targetDev = preferredBackCameraDevice()
        }
        guard let dev = targetDev,
              let input = try? AVCaptureDeviceInput(device: dev) else { return }

        if session.outputs.contains(photoOutput) { session.removeOutput(photoOutput) }
        if let oldInput = videoInput { session.removeInput(oldInput) }
        if session.canAddInput(input) {
            session.addInput(input)
            videoInput = input
            videoDevice = dev
            activeDeviceType = dev.deviceType
        }
        let initialNativeZ = nativeZoomFactor(forDisplayZoom: displayZoom, on: dev)
        applyCaptureModeFormatAndColorSpaceLocked(on: dev, initialZoom: initialNativeZ)
        if dev.isVirtualDevice {
            do {
                try dev.lockForConfiguration()
                if dev.activePrimaryConstituentDeviceSwitchingBehavior != .unsupported {
                    dev.setPrimaryConstituentDeviceSwitchingBehavior(
                        .restricted,
                        restrictedSwitchingBehaviorConditions: [.videoZoomChanged]
                    )
                }
                dev.unlockForConfiguration()
            } catch {}
        }
        setupRotationAndSystemControlsLocked(for: dev)
        applyExposureOnDevice(dev)
        applyWhiteBalanceOnDevice(dev)
    }

    private func setupRotationAndSystemControlsLocked(for device: AVCaptureDevice) {
        if let conn = videoOutput.connection(with: .video) {
            if conn.isVideoRotationAngleSupported(90) {
                conn.videoRotationAngle = 90
            }
            if conn.isVideoMirroringSupported {
                conn.automaticallyAdjustsVideoMirroring = false
                conn.isVideoMirrored = (device.position == .front)
            }
            if conn.isVideoStabilizationSupported {
                conn.preferredVideoStabilizationMode = .standard
            }
        }
        let coordinator = AVCaptureDevice.RotationCoordinator(device: device, previewLayer: nil)
        self.rotationCoordinator = coordinator
        updateCaptureAngle(coordinator.videoRotationAngleForHorizonLevelCapture)

        rotationObservation = coordinator.observe(\.videoRotationAngleForHorizonLevelCapture, options: [.new]) { [weak self] coord, _ in
            self?.updateCaptureAngle(coord.videoRotationAngleForHorizonLevelCapture)
        }

        if #available(iOS 18.0, *), session.supportsControls {
            for existing in session.controls {
                session.removeControl(existing)
            }
            let mult = Float(max(device.displayVideoZoomFactorMultiplier, 0.1))
            let sysZoom = AVCaptureSystemZoomSlider(device: device) { [weak self] z in
                guard let self else { return }
                let disp = Float(z) * mult
                DispatchQueue.main.async {
                    if abs(self.displayZoom - disp) > 0.01 {
                        self.displayZoom = disp
                    }
                }
            }
            if session.canAddControl(sysZoom) { session.addControl(sysZoom) }

            let sysEV = AVCaptureSystemExposureBiasSlider(device: device) { [weak self] bias in
                DispatchQueue.main.async {
                    self?.evBias = bias
                }
            }
            if session.canAddControl(sysEV) { session.addControl(sysEV) }
            session.setControlsDelegate(self, queue: sessionQueue)
        }
    }

    private func updateCaptureAngle(_ angle: CGFloat) {
        guard angle == 0 || angle == 90 || angle == 180 else { return }
        DispatchQueue.main.async {
            if !self.isRecording && self.captureAngle != angle {
                self.captureAngle = angle
            }
        }
    }

    // MARK: - 触屏对焦与测光

    func focusAndExpose(atNormalizedPortraitPoint portraitPoint: CGPoint, viewPoint: CGPoint) {
        let nx = min(max(portraitPoint.x, 0.0), 1.0)
        let ny = min(max(portraitPoint.y, 0.0), 1.0)
        let sensorPt = isFrontCamera
            ? CGPoint(x: ny, y: nx)
            : CGPoint(x: ny, y: 1.0 - nx)

        selectionFeedback.selectionChanged()
        focusReticleID &+= 1
        let currentID = focusReticleID
        focusReticlePoint = viewPoint
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { [weak self] in
            if self?.focusReticleID == currentID {
                self?.focusReticlePoint = nil
            }
        }

        sessionQueue.async { [weak self] in
            guard let self, let dev = self.videoDevice else { return }
            do {
                try dev.lockForConfiguration()
                if dev.isFocusPointOfInterestSupported {
                    dev.focusPointOfInterest = sensorPt
                    if dev.isFocusModeSupported(.continuousAutoFocus) {
                        dev.focusMode = .continuousAutoFocus
                    } else if dev.isFocusModeSupported(.autoFocus) {
                        dev.focusMode = .autoFocus
                    }
                }
                if !self.isExposureLocked && self.shutterDenom == 0 && self.isoValue == 0 && dev.isExposurePointOfInterestSupported {
                    dev.exposurePointOfInterest = sensorPt
                    if dev.isExposureModeSupported(.continuousAutoExposure) {
                        dev.exposureMode = .continuousAutoExposure
                    }
                }
                dev.unlockForConfiguration()
            } catch {}
        }
    }

    private func reconfigureDevice() {
        guard !isRecording, !isCapturingPhoto else { return }
        pendingSessionChanges += 1
        sessionQueue.async { [weak self] in
            guard let self else { return }
            if let device = self.videoDevice {
                let nativeZ = self.nativeZoomFactor(forDisplayZoom: self.displayZoom, on: device)
                self.updateSessionConfiguration {
                    self.applyCaptureModeFormatAndColorSpaceLocked(on: device, initialZoom: nativeZ)
                    if let connection = self.videoOutput.connection(with: .video), connection.isVideoRotationAngleSupported(90) {
                        connection.videoRotationAngle = 90
                    }
                    self.applyExposureOnDevice(device)
                    self.applyWhiteBalanceOnDevice(device)
                }
            }
            DispatchQueue.main.async { self.pendingSessionChanges -= 1 }
        }
    }

    private func updateSessionConfiguration(_ configure: () -> Void) {
        let wasRunning = session.isRunning
        if wasRunning { session.stopRunning() }
        videoOutputQueue.sync {}
        renderSemaphore.wait()
        renderSemaphore.wait()
        renderSemaphore.signal()
        renderSemaphore.signal()
        session.beginConfiguration()
        configure()
        session.commitConfiguration()
        if wasRunning { session.startRunning() }
    }

    private func applyCaptureModeFormatAndColorSpaceLocked(on device: AVCaptureDevice, initialZoom: CGFloat) {
        if session.outputs.contains(photoOutput) { session.removeOutput(photoOutput) }
        if captureMode == .video {
            applyFormatAndColorSpaceLocked(on: device, initialZoom: initialZoom)
        } else {
            applyPhotoFormatAndColorSpaceLocked(on: device, initialZoom: initialZoom)
        }
    }

    private func applyPhotoFormatAndColorSpaceLocked(on device: AVCaptureDevice, initialZoom: CGFloat) {
        let candidates = device.formats.filter { format in
            let dimensions = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            return dimensions.width * 3 == dimensions.height * 4
                && format.videoSupportedFrameRateRanges.contains { $0.minFrameRate <= 30 && $0.maxFrameRate >= 30 }
                && !format.supportedMaxPhotoDimensions.isEmpty
        }
        guard let format = candidates.max(by: { a, b in
            let maxA = a.supportedMaxPhotoDimensions.map { Int64($0.width) * Int64($0.height) }.max() ?? 0
            let maxB = b.supportedMaxPhotoDimensions.map { Int64($0.width) * Int64($0.height) }.max() ?? 0
            if maxA != maxB { return maxA < maxB }
            let da = CMVideoFormatDescriptionGetDimensions(a.formatDescription)
            let db = CMVideoFormatDescriptionGetDimensions(b.formatDescription)
            let distanceA = abs(Int(da.width) - 1920) + abs(Int(da.height) - 1440)
            let distanceB = abs(Int(db.width) - 1920) + abs(Int(db.height) - 1440)
            return distanceA > distanceB
        }) else {
            showToast("当前镜头不支持照片拍摄")
            return
        }
        do {
            try device.lockForConfiguration()
            device.activeFormat = format
            device.activeColorSpace = format.supportedColorSpaces.contains(.P3_D65) ? .P3_D65 : .sRGB
            applyPhotoFrameRateOnLockedDevice(device)
            device.videoZoomFactor = min(max(initialZoom, device.minAvailableVideoZoomFactor), min(device.maxAvailableVideoZoomFactor, format.videoMaxZoomFactor, 30.0))
            device.unlockForConfiguration()
        } catch {
            showToast("相机设置失败，请重试")
            return
        }
        photoOutput = AVCapturePhotoOutput()
        if session.canAddOutput(photoOutput) {
            session.addOutput(photoOutput)
            photoOutput.maxPhotoQualityPrioritization = .quality
            configurePhotoCapabilities(on: device)
        }
        let available = videoOutput.availableVideoPixelFormatTypes
        let pixelFormat = available.contains(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)
            ? kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange : kCVPixelFormatType_32BGRA
        currentOutputPixelFormat = pixelFormat
        videoOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: pixelFormat]
        DispatchQueue.main.async { self.isAppleLogActive = false }
    }

    private func applyPhotoFrameRateOnLockedDevice(_ device: AVCaptureDevice) {
        device.activeVideoMinFrameDuration = CMTime(value: 1, timescale: 30)
        device.activeVideoMaxFrameDuration = .invalid
    }

    private func selectBestVideoFormat(
        from candidates: [AVCaptureDevice.Format],
        targetW: Int32,
        targetH: Int32,
        prefer10Bit: Bool
    ) -> AVCaptureDevice.Format? {
        let matchingDims = candidates.filter {
            let d = CMVideoFormatDescriptionGetDimensions($0.formatDescription)
            return d.width == targetW && d.height == targetH
        }
        let pool = matchingDims.isEmpty ? candidates : matchingDims
        guard !pool.isEmpty else { return nil }

        // 优先挑选：1) 10-bit 像素格式（若开启 Log）；2) 传感器像素合并模式（isVideoBinned，降低 4K 发热与功耗）；3) 最高帧率 <= 60fps（避免误入 4K 120fps 慢动作高功耗档）
        return pool.max { a, b in
            let subA = CMFormatDescriptionGetMediaSubType(a.formatDescription)
            let subB = CMFormatDescriptionGetMediaSubType(b.formatDescription)
            let is10A = (subA == kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange || subA == kCVPixelFormatType_420YpCbCr10BiPlanarFullRange)
            let is10B = (subB == kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange || subB == kCVPixelFormatType_420YpCbCr10BiPlanarFullRange)
            if prefer10Bit && is10A != is10B {
                return !is10A && is10B
            }
            let maxFpsA = a.videoSupportedFrameRateRanges.map(\.maxFrameRate).max() ?? 0
            let maxFpsB = b.videoSupportedFrameRateRanges.map(\.maxFrameRate).max() ?? 0
            let normalRateA = maxFpsA <= 60.1
            let normalRateB = maxFpsB <= 60.1
            if normalRateA != normalRateB {
                return !normalRateA && normalRateB
            }
            if a.isVideoBinned != b.isVideoBinned {
                return !a.isVideoBinned && b.isVideoBinned
            }
            return maxFpsA < maxFpsB
        }
    }

    private func applyFormatAndColorSpaceLocked(on device: AVCaptureDevice, initialZoom: CGFloat) {
        let targetW: Int32 = is4K ? 3840 : 1920
        let targetH: Int32 = is4K ? 2160 : 1080
        let targetFPS = Double(fps)

        let matchFPS: (AVCaptureDevice.Format) -> Bool = { fmt in
            (fmt.videoSupportedFrameRateRanges.map(\.maxFrameRate).max() ?? 0) >= targetFPS - 0.1
        }

        var chosenFormat: AVCaptureDevice.Format? = nil
        var supportsLog = false

        if preferAppleLog {
            let logFormats = device.formats.filter { $0.supportedColorSpaces.contains(.appleLog) && matchFPS($0) }
            chosenFormat = selectBestVideoFormat(from: logFormats, targetW: targetW, targetH: targetH, prefer10Bit: true)
            supportsLog = (chosenFormat != nil)
        }

        if chosenFormat == nil {
            let stdFormats = device.formats.filter { matchFPS($0) }
            chosenFormat = selectBestVideoFormat(from: stdFormats, targetW: targetW, targetH: targetH, prefer10Bit: false) ?? device.activeFormat
        }

        do {
            try device.lockForConfiguration()
            if let fmt = chosenFormat {
                if device.activeFormat != fmt {
                    device.activeFormat = fmt
                }
                if supportsLog {
                    if device.activeColorSpace != .appleLog {
                        device.activeColorSpace = .appleLog
                    }
                } else if fmt.supportedColorSpaces.contains(.P3_D65) {
                    if device.activeColorSpace != .P3_D65 {
                        device.activeColorSpace = .P3_D65
                    }
                } else {
                    if device.activeColorSpace != .sRGB {
                        device.activeColorSpace = .sRGB
                    }
                }
                applyFrameRateOnLockedDevice(device)
                device.videoZoomFactor = min(max(initialZoom, device.minAvailableVideoZoomFactor), min(device.maxAvailableVideoZoomFactor, device.activeFormat.videoMaxZoomFactor, 30.0))
            }
            device.unlockForConfiguration()
        } catch {}

        let availTypes = videoOutput.availableVideoPixelFormatTypes
        let pxFormat: OSType
        if supportsLog && availTypes.contains(kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange) {
            pxFormat = kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
        } else if availTypes.contains(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange) {
            pxFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        } else {
            pxFormat = kCVPixelFormatType_32BGRA
        }
        currentOutputPixelFormat = pxFormat
        videoOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: pxFormat]

        let isLogNow = (device.activeColorSpace == .appleLog)
        DispatchQueue.main.async {
            if self.isAppleLogActive != isLogNow {
                self.isAppleLogActive = isLogNow
            }
        }
    }

    private func applyFrameRate() {
        sessionQueue.async { [weak self] in
            guard let self, let dev = self.videoDevice else { return }
            do {
                try dev.lockForConfiguration()
                if self.captureMode == .photo { self.applyPhotoFrameRateOnLockedDevice(dev) }
                else { self.applyFrameRateOnLockedDevice(dev) }
                dev.unlockForConfiguration()
            } catch {}
        }
    }

    private func applyFrameRateOnLockedDevice(_ device: AVCaptureDevice) {
        let targetFPS = Double(fps)
        let ranges = device.activeFormat.videoSupportedFrameRateRanges
        guard let r = ranges.first(where: { $0.minFrameRate <= targetFPS && targetFPS <= $0.maxFrameRate })
            ?? ranges.max(by: { $0.maxFrameRate < $1.maxFrameRate }) else { return }
        let actual = min(max(targetFPS, r.minFrameRate), r.maxFrameRate)
        let dur = CMTime(value: 1, timescale: CMTimeScale(round(actual)))
        device.activeVideoMinFrameDuration = dur
        device.activeVideoMaxFrameDuration = lockFrameRate ? dur : .invalid
    }

    // MARK: - 原生曝光与白平衡

    private func applyExposure() {
        sessionQueue.async { [weak self] in
            guard let self, let dev = self.videoDevice else { return }
            self.applyExposureOnDevice(dev)
        }
    }

    private func applyExposureOnDevice(_ device: AVCaptureDevice) {
        do {
            try device.lockForConfiguration()
            defer { device.unlockForConfiguration() }

            let bias = min(max(evBias, device.minExposureTargetBias), device.maxExposureTargetBias)
            device.setExposureTargetBias(bias, completionHandler: nil)

            if isExposureLocked {
                if device.isExposureModeSupported(.locked) && device.exposureMode != .locked {
                    device.exposureMode = .locked
                }
                return
            }

            if shutterDenom == 0 && isoValue == 0 {
                if device.isExposureModeSupported(.continuousAutoExposure) && device.exposureMode != .continuousAutoExposure {
                    device.exposureMode = .continuousAutoExposure
                }
                return
            }

            guard device.isExposureModeSupported(.custom) else { return }
            let fmt = device.activeFormat
            let minS = CMTimeGetSeconds(fmt.minExposureDuration)
            let rawS = shutterDenom > 0 ? (1.0 / Double(shutterDenom)) : CMTimeGetSeconds(device.exposureDuration)
            if captureMode == .photo && rawS > (1.0 / 30.0) {
                device.activeVideoMinFrameDuration = .invalid
                device.activeVideoMaxFrameDuration = .invalid
            }
            let frameCapS = CMTimeGetSeconds(device.activeVideoMinFrameDuration)
            let maxS = captureMode == .photo
                ? min(CMTimeGetSeconds(fmt.maxExposureDuration), 0.5)
                : min(CMTimeGetSeconds(fmt.maxExposureDuration), frameCapS > 0 ? frameCapS : 1.0 / Double(max(fps, 24)))
            let dur = CMTimeMakeWithSeconds(min(max(rawS, minS), maxS), preferredTimescale: 1_000_000)

            let iso: Float
            if isoValue > 0 {
                iso = min(max(Float(isoValue), fmt.minISO), fmt.maxISO)
            } else {
                iso = AVCaptureDevice.currentISO
            }
            device.setExposureModeCustom(duration: dur, iso: iso, completionHandler: nil)
        } catch {}
    }

    private func applyWhiteBalance() {
        sessionQueue.async { [weak self] in
            guard let self, let dev = self.videoDevice else { return }
            self.applyWhiteBalanceOnDevice(dev)
        }
    }

    private func applyWhiteBalanceOnDevice(_ device: AVCaptureDevice) {
        guard !device.isAdjustingWhiteBalance else { return }
        do {
            try device.lockForConfiguration()
            defer { device.unlockForConfiguration() }

            if isWBLocked {
                if device.isWhiteBalanceModeSupported(.locked) {
                    device.whiteBalanceMode = .locked
                }
                return
            }

            if wbKelvin <= 0 {
                if device.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) {
                    device.whiteBalanceMode = .continuousAutoWhiteBalance
                }
                return
            }

            guard device.isWhiteBalanceModeSupported(.locked) else { return }
            let tt = AVCaptureDevice.WhiteBalanceTemperatureAndTintValues(temperature: min(max(wbKelvin, 2500), 8000), tint: 0)
            let g = device.deviceWhiteBalanceGains(for: tt)
            let m = device.maxWhiteBalanceGain
            let safe = AVCaptureDevice.WhiteBalanceGains(
                redGain: min(max(g.redGain, 1.0), m),
                greenGain: min(max(g.greenGain, 1.0), m),
                blueGain: min(max(g.blueGain, 1.0), m)
            )
            device.setWhiteBalanceModeLocked(with: safe, completionHandler: nil)
        } catch {}
    }

    // MARK: - 照片拍摄与原生尺寸导出

    func setCaptureMode(_ mode: CaptureMode) {
        guard !isRecording, !isCapturingPhoto, !isChangingSession, captureMode != mode else { return }
        captureMode = mode
        reconfigureDevice()
    }

    func setPhotoDimension(_ dim: NativePhotoDimension) {
        guard !isCapturingPhoto, availablePhotoDimensions.contains(dim) else { return }
        selectedPhotoDimension = dim
    }

    func setPhotoCaptureFormat(_ format: PhotoCaptureFormat) {
        guard !isCapturingPhoto, availablePhotoCaptureFormats.contains(format) else { return }
        selectedPhotoCaptureFormat = format
        if format == .bayerRAW {
            let nativeDisplayZoom: Float = activeDeviceType == .builtInUltraWideCamera ? 0.5 : activeDeviceType == .builtInTelephotoCamera ? telephotoBaseZoom : 1.0
            setDisplayZoom(nativeDisplayZoom, allowLensSwitch: false)
        }
        sessionQueue.async { [weak self] in
            guard let self, let device = self.videoDevice else { return }
            self.configurePhotoCapabilities(on: device)
        }
    }

    @MainActor
    func applyExportPreset(_ preset: SocialExportPreset) {
        if preset.requiresProPurchase && !ProPurchaseManager.shared.isProUnlocked {
            showProPaywall = true
            return
        }
        selectedExportPreset = preset
        exportFileFormat = preset.format
        exportColorGamut = preset.gamut
        exportDimensionLimit = preset.dimension
        exportHDREnabled = preset.hdrEnabled
        showToast("已切换至「\(preset.name)」无损直发规格")
    }

    enum PhotoSaveSpec: Equatable {
        case renderedOnly
        case appleProRaw
        case saveBoth
    }

    enum VideoSaveSpec: Equatable {
        case renderedOnly
        case appleLog10Bit
        case saveBoth
    }

    var currentPhotoSaveSpec: PhotoSaveSpec {
        if saveOriginalRawDNG { return .saveBoth }
        if selectedPhotoCaptureFormat == .proRAW { return .appleProRaw }
        return .renderedOnly
    }

    var currentVideoSaveSpec: VideoSaveSpec {
        if saveRawLogAlongside { return .saveBoth }
        if preferAppleLog { return .appleLog10Bit }
        return .renderedOnly
    }

    var photoSaveSpecShortBadge: String {
        switch currentPhotoSaveSpec {
        case .renderedOnly: return "成片"
        case .appleProRaw:  return "ProRaw"
        case .saveBoth:     return "双存"
        }
    }

    var videoSaveSpecShortBadge: String {
        switch currentVideoSaveSpec {
        case .renderedOnly:  return "成片"
        case .appleLog10Bit: return "Log"
        case .saveBoth:      return "双存"
        }
    }

    @MainActor
    func selectPhotoSaveSpec(_ spec: PhotoSaveSpec) {
        guard !isCapturingPhoto else { return }
        switch spec {
        case .renderedOnly:
            saveOriginalRawDNG = false
            setPhotoCaptureFormat(.heif)
        case .appleProRaw:
            saveOriginalRawDNG = false
            if availablePhotoCaptureFormats.contains(.proRAW) {
                setPhotoCaptureFormat(.proRAW)
            } else if availablePhotoCaptureFormats.contains(.bayerRAW) {
                setPhotoCaptureFormat(.bayerRAW)
            } else {
                setPhotoCaptureFormat(.heif)
            }
        case .saveBoth:
            if !ProPurchaseManager.shared.isProUnlocked {
                showProPaywall = true
                return
            }
            if availablePhotoCaptureFormats.contains(.proRAW) {
                setPhotoCaptureFormat(.proRAW)
            } else if availablePhotoCaptureFormats.contains(.bayerRAW) {
                setPhotoCaptureFormat(.bayerRAW)
            }
            saveOriginalRawDNG = true
            showToast("已开启成片与 DNG 底片同时保存")
        }
    }

    @MainActor
    func selectVideoSaveSpec(_ spec: VideoSaveSpec) {
        guard !isRecording else { return }
        switch spec {
        case .renderedOnly:
            saveRawLogAlongside = false
            preferAppleLog = false
        case .appleLog10Bit:
            saveRawLogAlongside = false
            preferAppleLog = true
        case .saveBoth:
            if !ProPurchaseManager.shared.isProUnlocked {
                showProPaywall = true
                return
            }
            preferAppleLog = true
            saveRawLogAlongside = true
            showToast("已开启成片与 Apple Log 原片同时保存")
        }
    }

    @MainActor
    func setSaveRawLogAlongside(_ enabled: Bool) {
        if enabled && !ProPurchaseManager.shared.isProUnlocked {
            showProPaywall = true
            return
        }
        saveRawLogAlongside = enabled
        if enabled {
            showToast("已开启同步保存 Apple Log 原片")
        }
    }

    func updateExportSpec(
        format: ExportFileFormat? = nil,
        gamut: ExportColorGamut? = nil,
        dimension: ExportDimensionLimit? = nil,
        hdrEnabled: Bool? = nil
    ) {
        if let format { exportFileFormat = format }
        if let gamut { exportColorGamut = gamut }
        if let dimension { exportDimensionLimit = dimension }
        if let hdrEnabled { exportHDREnabled = hdrEnabled }
        selectedExportPreset = SocialExportPreset.allCases.first {
            $0.format == exportFileFormat &&
            $0.gamut == exportColorGamut &&
            $0.dimension == exportDimensionLimit &&
            $0.hdrEnabled == exportHDREnabled
        }
    }

    private func configurePhotoCapabilities(on device: AVCaptureDevice) {
        guard session.outputs.contains(photoOutput) else { return }
        let rawDimensions = device.activeFormat.supportedMaxPhotoDimensions
        if let largest = rawDimensions.max(by: { Int64($0.width) * Int64($0.height) < Int64($1.width) * Int64($1.height) }) {
            if photoOutput.maxPhotoDimensions.width != largest.width || photoOutput.maxPhotoDimensions.height != largest.height {
                photoOutput.maxPhotoDimensions = largest
            }
        }
        photoOutput.isAppleProRAWEnabled = photoOutput.isAppleProRAWSupported

        var formats: [PhotoCaptureFormat] = [.heif]
        if photoOutput.availableRawPhotoPixelFormatTypes.contains(where: AVCapturePhotoOutput.isAppleProRAWPixelFormat) {
            formats.append(.proRAW)
        }
        if photoOutput.availableRawPhotoPixelFormatTypes.contains(where: AVCapturePhotoOutput.isBayerRAWPixelFormat) {
            formats.append(.bayerRAW)
        }

        var nativeDims: [NativePhotoDimension] = []
        for d in rawDimensions {
            let item = NativePhotoDimension(width: d.width, height: d.height)
            if item.megapixels >= 10 && !nativeDims.contains(item) {
                nativeDims.append(item)
            }
        }
        nativeDims.sort { Int64($0.width) * Int64($0.height) < Int64($1.width) * Int64($1.height) }
        if nativeDims.isEmpty {
            nativeDims = [NativePhotoDimension(width: 4032, height: 3024)]
        }

        DispatchQueue.main.async {
            self.availablePhotoCaptureFormats = formats
            if !formats.contains(self.selectedPhotoCaptureFormat) {
                self.selectedPhotoCaptureFormat = .heif
            }
            let filteredDims: [NativePhotoDimension]
            if self.selectedPhotoCaptureFormat == .bayerRAW {
                let bayer = nativeDims.filter { $0.megapixels <= 13 }
                filteredDims = bayer.isEmpty ? [nativeDims[0]] : bayer
            } else {
                filteredDims = nativeDims
            }
            self.availablePhotoDimensions = filteredDims
            if !filteredDims.contains(self.selectedPhotoDimension) {
                self.selectedPhotoDimension = filteredDims.last ?? filteredDims[0]
            }
        }
    }

    func capturePhoto() {
        guard captureMode == .photo, !isRecording, !isCapturingPhoto, !isChangingSession else { return }
        isCapturingPhoto = true
        pendingLensSwitchWork?.cancel()

        let requestedFormat = selectedPhotoCaptureFormat
        let requestedDim = selectedPhotoDimension
        let angle = captureAngle
        var currentParams = params
        if shutterDenom > 0 || isoValue > 0 {
            currentParams.filmExposureEV += evBias
        }
        let fileFormat = exportFileFormat
        let colorGamut = exportColorGamut
        let dimLimit = exportDimensionLimit
        let hdrEnabled = exportHDREnabled
        let keepRawDNG = saveOriginalRawDNG
        let presetLabel = selectedExportPreset?.name ?? "\(fileFormat.label) · \(colorGamut.shortLabel)"

        sessionQueue.async { [weak self] in
            guard let self else { return }
            guard self.session.isRunning,
                  let device = self.videoDevice,
                  let connection = self.photoOutput.connection(with: .video),
                  connection.isActive else {
                self.finishPhotoCapture(message: "相机正在准备，请稍候")
                return
            }

            let effectiveFormat: PhotoCaptureFormat = (requestedFormat == .proRAW && device.exposureMode == .custom) ? .heif : requestedFormat
            let settings: AVCapturePhotoSettings
            if effectiveFormat == .heif {
                let codec: AVVideoCodecType = self.photoOutput.availablePhotoCodecTypes.contains(.hevc) ? .hevc : .jpeg
                settings = AVCapturePhotoSettings(format: [AVVideoCodecKey: codec])
                settings.photoQualityPrioritization = .quality
            } else {
                let rawPixelType = self.photoOutput.availableRawPhotoPixelFormatTypes.first {
                    effectiveFormat == .proRAW ? AVCapturePhotoOutput.isAppleProRAWPixelFormat($0) : AVCapturePhotoOutput.isBayerRAWPixelFormat($0)
                }
                guard let rawPixelType else {
                    self.finishPhotoCapture(message: "当前镜头不支持该 RAW 格式")
                    return
                }
                if effectiveFormat == .bayerRAW && abs(device.videoZoomFactor - 1.0) > 0.001 {
                    self.finishPhotoCapture(message: "光学 RAW 需使用镜头原始 1× 焦距")
                    return
                }
                settings = AVCapturePhotoSettings(rawPixelFormatType: rawPixelType)
                settings.photoQualityPrioritization = effectiveFormat == .bayerRAW ? .speed : .quality
            }

            let supported = device.activeFormat.supportedMaxPhotoDimensions
            let targetCM = requestedDim.cmDimensions
            if supported.contains(where: { $0.width == targetCM.width && $0.height == targetCM.height }) {
                settings.maxPhotoDimensions = targetCM
            } else if let best = supported.max(by: { Int64($0.width) * Int64($0.height) < Int64($1.width) * Int64($1.height) }) {
                settings.maxPhotoDimensions = best
            }

            if connection.isVideoRotationAngleSupported(angle) {
                connection.videoRotationAngle = angle
            }
            if connection.isVideoMirroringSupported {
                connection.automaticallyAdjustsVideoMirroring = false
                connection.isVideoMirrored = (device.position == .front)
            }

            let captureID = settings.uniqueID
            let processor = PhotoCaptureProcessor(
                onShutter: { [weak self] in
                    DispatchQueue.main.async {
                        guard let self else { return }
                        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                        self.shutterCurtainOpacity = 0.78
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in
                            self?.shutterCurtainOpacity = 0.0
                        }
                    }
                },
                completion: { [weak self] result in
                    guard let self else { return }
                    self.sessionQueue.async {
                        self.photoCaptures.removeValue(forKey: captureID)
                    }
                    self.photoQueue.async {
                        switch result {
                        case .success(let (data, isRaw)):
                            self.developAndSavePhoto(
                                data: data,
                                isRaw: isRaw,
                                params: currentParams,
                                fileFormat: fileFormat,
                                colorGamut: colorGamut,
                                dimensionLimit: dimLimit,
                                hdrEnabled: hdrEnabled,
                                keepRawDNG: keepRawDNG,
                                presetLabel: presetLabel
                            )
                        case .failure:
                            self.finishPhotoCapture(message: "拍照失败，请重试")
                        }
                    }
                }
            )
            self.photoCaptures[captureID] = processor
            self.photoOutput.capturePhoto(with: settings, delegate: processor)
        }
    }

    private func developAndSavePhoto(
        data: Data,
        isRaw: Bool,
        params: SpectralFilmParameters,
        fileFormat: ExportFileFormat,
        colorGamut: ExportColorGamut,
        dimensionLimit: ExportDimensionLimit,
        hdrEnabled: Bool,
        keepRawDNG: Bool,
        presetLabel: String
    ) {
        autoreleasepool {
            let inputCI: CIImage?
            if isRaw, let rawFilter = CIRAWFilter(imageData: data, identifierHint: UTType.dng.identifier) {
                rawFilter.extendedDynamicRangeAmount = hdrEnabled ? 1.0 : 0.0
                inputCI = rawFilter.outputImage
            } else {
                inputCI = CIImage(data: data, options: [.applyOrientationProperty: true, .expandToHDR: hdrEnabled])
            }
            guard let rawCI = inputCI,
                  let photoEngine = self.photoEngine,
                  let developed = photoEngine.renderStillPhoto(
                      inputCIImage: rawCI,
                      params: params,
                      outputDisplayP3: colorGamut == .displayP3,
                      preserveHDR: hdrEnabled
                  ) else {
                finishPhotoCapture(message: "胶片冲印失败，请重试")
                return
            }

            // 原生尺寸不经过任何缩放；仅当选择了特定限宽时才等比缩放
            var finalImage = developed
            let scale = dimensionLimit.scale(for: developed.extent.size)
            if scale < 0.999 {
                finalImage = developed.applyingFilter("CILanczosScaleTransform", parameters: [
                    kCIInputScaleKey: scale,
                    kCIInputAspectRatioKey: 1.0
                ])
                let targetRect = CGRect(
                    x: 0,
                    y: 0,
                    width: (developed.extent.width * scale).rounded(),
                    height: (developed.extent.height * scale).rounded()
                )
                finalImage = finalImage.cropped(to: targetRect)
            }

            guard let outColorSpace = CGColorSpace(name: colorGamut == .displayP3 ? CGColorSpace.displayP3 : CGColorSpace.sRGB) else {
                finishPhotoCapture(message: "色域配置失败")
                return
            }

            let sdrImage = finalImage.applyingFilter("CIColorClamp", parameters: [
                "inputMinComponents": CIVector(x: 0, y: 0, z: 0, w: 0),
                "inputMaxComponents": CIVector(x: 1, y: 1, z: 1, w: 1)
            ])

            var repOptions: [CIImageRepresentationOption: Any] = [
                CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String): 0.96
            ]
            if hdrEnabled && fileFormat != .tiff16 {
                repOptions[.hdrImage] = finalImage
            }

            let encodedData: Data?
            switch fileFormat {
            case .heif:
                encodedData = photoCIContext.heifRepresentation(of: sdrImage, format: .RGBA8, colorSpace: outColorSpace, options: repOptions)
            case .jpeg:
                encodedData = photoCIContext.jpegRepresentation(of: sdrImage, colorSpace: outColorSpace, options: repOptions)
            case .tiff16:
                let tiffSpace = hdrEnabled
                    ? CGColorSpace(name: colorGamut == .displayP3 ? CGColorSpace.extendedLinearDisplayP3 : CGColorSpace.extendedLinearSRGB)!
                    : outColorSpace
                encodedData = photoCIContext.tiffRepresentation(
                    of: hdrEnabled ? finalImage : sdrImage,
                    format: hdrEnabled ? .RGBAh : .RGBA16,
                    colorSpace: tiffSpace,
                    options: [:]
                )
            }

            guard let encodedData else {
                finishPhotoCapture(message: "照片编码失败")
                return
            }

            let outW = Int(round(finalImage.extent.width))
            let outH = Int(round(finalImage.extent.height))
            let summary = "已保存 \(outW)×\(outH) · \(presetLabel)"

            PHPhotoLibrary.shared().performChanges({
                let opts = PHAssetResourceCreationOptions()
                opts.uniformTypeIdentifier = fileFormat.fileType.identifier
                opts.originalFilename = "SpekraVideo_\(UUID().uuidString).\(fileFormat.fileType.preferredFilenameExtension ?? "heic")"
                PHAssetCreationRequest.forAsset().addResource(with: .photo, data: encodedData, options: opts)

                if keepRawDNG && isRaw {
                    let rawOpts = PHAssetResourceCreationOptions()
                    rawOpts.uniformTypeIdentifier = UTType.dng.identifier
                    rawOpts.originalFilename = "SpekraVideo_\(UUID().uuidString).dng"
                    PHAssetCreationRequest.forAsset().addResource(with: .photo, data: data, options: rawOpts)
                }
            }, completionHandler: { [weak self] success, _ in
                self?.finishPhotoCapture(message: success ? summary : "保存失败，请检查相册权限")
            })
        }
    }

    private func finishPhotoCapture(message: String) {
        DispatchQueue.main.async {
            self.isCapturingPhoto = false
            self.showToast(message)
        }
    }

    // MARK: - 录制控制

    func toggleRecording() {
        guard captureMode == .video, !isChangingSession else { return }
        recordingLock.lock()
        let rec = isRecordingInternal
        recordingLock.unlock()
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        if rec { stopRecording() } else { startRecording() }
    }

    private func startRecording() {
        let angleNow = captureAngle
        recordingLock.lock()
        guard !isRecordingInternal else { recordingLock.unlock(); return }
        isRecordingInternal = true
        recordingAngleSnapshot = angleNow
        filmSessionStarted = false
        rawLogSessionStarted = false
        recordingStartPTS = .invalid
        recordingLock.unlock()

        DispatchQueue.main.async {
            self.isRecording = true
            self.telemetry.recordingSeconds = 0.0
            self.statusToast = nil
        }
    }

    private func stopRecording() {
        recordingLock.lock()
        guard isRecordingInternal else { recordingLock.unlock(); return }
        isRecordingInternal = false
        let writer = filmAssetWriter, vIn = filmVideoInput, aIn = filmAudioInput, url = filmOutputURL
        let rawWriter = rawLogAssetWriter, rawVIn = rawLogVideoInput, rawURL = rawLogOutputURL
        filmAssetWriter = nil; filmVideoInput = nil; filmAudioInput = nil; filmPixelBufferAdaptor = nil; filmOutputURL = nil
        rawLogAssetWriter = nil; rawLogVideoInput = nil; rawLogOutputURL = nil
        recordingLock.unlock()

        DispatchQueue.main.async { self.isRecording = false }

        videoOutputQueue.async { [weak self] in
            let group = DispatchGroup()
            var savedCount = 0

            if let writer, let url {
                group.enter()
                vIn?.markAsFinished(); aIn?.markAsFinished()
                writer.finishWriting {
                    if writer.status == .completed {
                        PHPhotoLibrary.shared().performChanges({
                            PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url)
                        }) { ok, _ in
                            if ok { savedCount += 1 }
                            try? FileManager.default.removeItem(at: url)
                            group.leave()
                        }
                    } else {
                        try? FileManager.default.removeItem(at: url)
                        group.leave()
                    }
                }
            }

            if let rawWriter, let rawURL {
                group.enter()
                rawVIn?.markAsFinished()
                rawWriter.finishWriting {
                    if rawWriter.status == .completed {
                        PHPhotoLibrary.shared().performChanges({
                            PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: rawURL)
                        }) { ok, _ in
                            if ok { savedCount += 1 }
                            try? FileManager.default.removeItem(at: rawURL)
                            group.leave()
                        }
                    } else {
                        try? FileManager.default.removeItem(at: rawURL)
                        group.leave()
                    }
                }
            }

            group.notify(queue: .main) {
                guard let self else { return }
                self.showToast(savedCount > 0 ? "已保存至系统相册" : "视频保存失败")
            }
        }
    }

    private func showToast(_ text: String) {
        DispatchQueue.main.async { [weak self] in
            self?.statusToast = text
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.4) { [weak self] in
                if self?.statusToast == text { self?.statusToast = nil }
            }
        }
    }

    private func writerTransform(for angle: CGFloat) -> CGAffineTransform {
        if angle == 0 { return CGAffineTransform(rotationAngle: -.pi / 2.0) }
        if angle == 180 { return CGAffineTransform(rotationAngle: .pi / 2.0) }
        return .identity
    }

    private func ensureWritersConfigured(width: Int, height: Int, pts: CMTime, angle: CGFloat) {
        if filmAssetWriter != nil { return }

        let ts = Int(Date().timeIntervalSince1970 * 1000)
        let filmURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("SpekraVideo_\(ts).mov")
        try? FileManager.default.removeItem(at: filmURL)
        guard let writer = try? AVAssetWriter(outputURL: filmURL, fileType: .mov) else { return }

        let is4KNow = max(width, height) >= 3840
        let targetBps = codecPreset.targetBitrate(is4K: is4KNow, fps: fps)
        let transform = writerTransform(for: angle)

        let p3ColorProps: [String: Any] = [
            AVVideoColorPrimariesKey: AVVideoColorPrimaries_P3_D65,
            AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
            AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2
        ]

        var vSettings: [String: Any]
        if codecPreset == .proRes422 {
            vSettings = [
                AVVideoCodecKey: AVVideoCodecType.proRes422,
                AVVideoWidthKey: width,
                AVVideoHeightKey: height,
                AVVideoColorPropertiesKey: p3ColorProps
            ]
            if !writer.canApply(outputSettings: vSettings, forMediaType: .video) {
                vSettings = [
                    AVVideoCodecKey: AVVideoCodecType.hevc,
                    AVVideoWidthKey: width,
                    AVVideoHeightKey: height,
                    AVVideoColorPropertiesKey: p3ColorProps,
                    AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: targetBps]
                ]
            }
        } else {
            vSettings = [
                AVVideoCodecKey: AVVideoCodecType.hevc,
                AVVideoWidthKey: width,
                AVVideoHeightKey: height,
                AVVideoColorPropertiesKey: p3ColorProps,
                AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: targetBps]
            ]
        }

        let vInput = AVAssetWriterInput(mediaType: .video, outputSettings: vSettings)
        vInput.expectsMediaDataInRealTime = true
        vInput.transform = transform

        let sourceBufAttrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferMetalCompatibilityKey as String: true,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:]
        ]
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: vInput, sourcePixelBufferAttributes: sourceBufAttrs)
        if writer.canAdd(vInput) { writer.add(vInput) }

        let aSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVNumberOfChannelsKey: 1,
            AVSampleRateKey: 44100.0,
            AVEncoderBitRateKey: 128_000
        ]
        let aInput = AVAssetWriterInput(mediaType: .audio, outputSettings: aSettings)
        aInput.expectsMediaDataInRealTime = true
        if writer.canAdd(aInput) { writer.add(aInput) }

        writer.startWriting()
        writer.startSession(atSourceTime: pts)

        self.filmAssetWriter = writer
        self.filmVideoInput = vInput
        self.filmAudioInput = aInput
        self.filmPixelBufferAdaptor = adaptor
        self.filmOutputURL = filmURL
        self.filmSessionStarted = true
        self.recordingStartPTS = pts

        if saveRawLogAlongside {
            let rawURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("AppleLogRaw_\(ts).mov")
            try? FileManager.default.removeItem(at: rawURL)
            if let rWriter = try? AVAssetWriter(outputURL: rawURL, fileType: .mov) {
                let rawVSettings: [String: Any] = [
                    AVVideoCodecKey: AVVideoCodecType.hevc,
                    AVVideoWidthKey: width,
                    AVVideoHeightKey: height,
                    AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: max(targetBps, 60_000_000)]
                ]
                let rVInput = AVAssetWriterInput(mediaType: .video, outputSettings: rawVSettings)
                rVInput.expectsMediaDataInRealTime = true
                rVInput.transform = transform
                if rWriter.canAdd(rVInput) {
                    rWriter.add(rVInput)
                    rWriter.startWriting()
                    rWriter.startSession(atSourceTime: pts)
                    self.rawLogAssetWriter = rWriter
                    self.rawLogVideoInput = rVInput
                    self.rawLogOutputURL = rawURL
                    self.rawLogSessionStarted = true
                }
            }
        }
    }
}

@available(iOS 18.0, *)
extension LogCameraController: AVCaptureSessionControlsDelegate {
    func sessionControlsDidBecomeActive(_ session: AVCaptureSession) {}
    func sessionControlsWillEnterFullscreenAppearance(_ session: AVCaptureSession) {}
    func sessionControlsWillExitFullscreenAppearance(_ session: AVCaptureSession) {}
    func sessionControlsDidBecomeInactive(_ session: AVCaptureSession) {}
}

extension LogCameraController: AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureAudioDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        if output === audioOutput {
            recordingLock.lock()
            let active = isRecordingInternal && filmSessionStarted
            let aInput = filmAudioInput
            recordingLock.unlock()
            if active, let aInput, aInput.isReadyForMoreMediaData {
                aInput.append(sampleBuffer)
            }
            return
        }

        guard output === videoOutput,
              let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer),
              let engine = self.engine else { return }

        if renderSemaphore.wait(timeout: .now()) != .success { return }

        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let w = CVPixelBufferGetWidth(pixelBuffer)
        let h = CVPixelBufferGetHeight(pixelBuffer)

        var isLogFrame = false
        var isBT2020Frame = false
        var colorSpaceName = "Display P3"
        if let dev = self.videoDevice {
            if dev.activeColorSpace == .appleLog {
                isLogFrame = true
                isBT2020Frame = true
                colorSpaceName = "ITU-R BT.2020"
            } else if dev.activeColorSpace == .P3_D65 {
                colorSpaceName = "Display P3"
            } else {
                colorSpaceName = "sRGB"
            }
        }
        let colorMeta = FrameColorMetadata(isAppleLog: isLogFrame, isBT2020: isBT2020Frame, inputColorSpaceName: colorSpaceName)

        paramsLock.lock()
        let currentParams = paramsSnapshot
        paramsLock.unlock()

        recordingLock.lock()
        let recRequested = isRecordingInternal
        let angleSnapshot = recordingAngleSnapshot
        recordingLock.unlock()

        var recordDestPB: CVPixelBuffer? = nil
        var activeAdaptor: AVAssetWriterInputPixelBufferAdaptor? = nil
        var activeFilmVIn: AVAssetWriterInput? = nil
        var recElapsed: Double = 0.0
        var recActive = false

        if recRequested {
            ensureWritersConfigured(width: w, height: h, pts: pts, angle: angleSnapshot)
            recordingLock.lock()
            if isRecordingInternal && filmSessionStarted {
                recActive = true
                activeAdaptor = filmPixelBufferAdaptor
                activeFilmVIn = filmVideoInput
                if recordingStartPTS.isValid {
                    recElapsed = max(CMTimeGetSeconds(CMTimeSubtract(pts, recordingStartPTS)), 0.0)
                }
                if let rIn = rawLogVideoInput, rawLogSessionStarted, rIn.isReadyForMoreMediaData {
                    rIn.append(sampleBuffer)
                }
            }
            recordingLock.unlock()

            if recActive, let adaptor = activeAdaptor, let vIn = activeFilmVIn, vIn.isReadyForMoreMediaData, let pool = adaptor.pixelBufferPool {
                var outPB: CVPixelBuffer?
                CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &outPB)
                recordDestPB = outPB
            }
        }

        engine.renderFrame(
            sampleBuffer: pixelBuffer,
            colorMeta: colorMeta,
            params: currentParams,
            recordingDestinationBuffer: recordDestPB
        ) { [weak self] outTex, _ in
            guard let self else { return }
            defer { self.renderSemaphore.signal() }

            if let outTex {
                self.canvasCoordinator?.present(texture: outTex)
            }

            if recActive, let recPB = recordDestPB, let adaptor = activeAdaptor, let vIn = activeFilmVIn {
                self.videoOutputQueue.async {
                    self.recordingLock.lock()
                    let stillRec = self.isRecordingInternal && self.filmSessionStarted
                    self.recordingLock.unlock()
                    if stillRec && vIn.isReadyForMoreMediaData {
                        adaptor.append(recPB, withPresentationTime: pts)
                    }
                }
            }

            self.frameCountForUI &+= 1
            if self.frameCountForUI % 18 == 0, let dev = self.videoDevice {
                let t = max(CMTimeGetSeconds(dev.exposureDuration), 1e-5)
                let s = Int(round(dev.iso))
                let denom = max(Int(round(1.0 / t)), 1)
                let fNum = dev.lensAperture
                var kVal = 5200
                let gains = dev.deviceWhiteBalanceGains
                let maxG = dev.maxWhiteBalanceGain
                if gains.redGain >= 1.0 && gains.greenGain >= 1.0 && gains.blueGain >= 1.0 &&
                   gains.redGain <= maxG && gains.greenGain <= maxG && gains.blueGain <= maxG {
                    let tt = dev.temperatureAndTintValues(for: gains)
                    if tt.temperature.isFinite {
                        kVal = Int(round(min(max(tt.temperature, 2000), 10000)) / 50.0) * 50
                    }
                }
                DispatchQueue.main.async {
                    if self.telemetry.liveISO != s { self.telemetry.liveISO = s }
                    if self.telemetry.liveShutterDenom != denom { self.telemetry.liveShutterDenom = denom }
                    if abs(self.telemetry.liveAperture - fNum) > 0.05 { self.telemetry.liveAperture = fNum }
                    if self.telemetry.liveKelvin != kVal { self.telemetry.liveKelvin = kVal }
                    if recActive {
                        self.telemetry.recordingSeconds = recElapsed
                    }
                }
            }
        }
    }
}
