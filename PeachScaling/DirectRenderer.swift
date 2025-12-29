import Foundation
import AppKit
import Metal
import MetalKit
import ScreenCaptureKit
import CoreVideo
import QuartzCore


@MainActor
final class DirectRenderer: NSObject {
    
    // MARK: - Properties
    
    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let metalEngine: MetalEngine
    private var overlayManager: OverlayWindowManager?
    private var mtkView: MTKView?
    
    // Screen Capture
    private var captureStream: SCStream?
    private var streamOutput: StreamOutput?
    private let captureQueue = DispatchQueue(label: "com.peachscaling.capture", qos: .userInteractive)
    
    // Frame Management
    private var currentFrameTexture: MTLTexture?
    private var displayTexture: MTLTexture?
    private let frameSemaphore = DispatchSemaphore(value: 3)
    
    // Callbacks
    var onWindowLost: (() -> Void)?
    var onWindowMoved: ((CGRect) -> Void)?
    
    // Statistics
    private(set) var currentFPS: Float = 0
    private(set) var interpolatedFPS: Float = 0
    private(set) var processingTime: Double = 0
    
    private var frameCount: UInt64 = 0
    private var interpolatedFrameCount: UInt64 = 0
    private var droppedFrames: UInt64 = 0
    private var lastStatsUpdate: CFTimeInterval = 0
    private var fpsCounter: Int = 0
    private var fpsTimer: CFTimeInterval = 0
    
    // Configuration
    private var currentSettings: CaptureSettings?
    private var targetWindowID: CGWindowID = 0
    private var targetPID: pid_t = 0
    private var isCapturing: Bool = false
    
    // MARK: - Initialization
    
    init?(device: MTLDevice? = nil, commandQueue: MTLCommandQueue? = nil) {
        guard let dev = device ?? MTLCreateSystemDefaultDevice() else {
            NSLog("DirectRenderer: Failed to create Metal device")
            return nil
        }
        
        guard let queue = commandQueue ?? dev.makeCommandQueue() else {
            NSLog("DirectRenderer: Failed to create command queue")
            return nil
        }
        
        guard let engine = MetalEngine(device: dev) else {
            NSLog("DirectRenderer: Failed to create MetalEngine")
            return nil
        }
        
        self.device = dev
        self.commandQueue = queue
        self.metalEngine = engine
        
        super.init()
        
        guard let overlay = OverlayWindowManager(device: dev) else {
            NSLog("DirectRenderer: Failed to create OverlayWindowManager")
            return nil
        }
        
        self.overlayManager = overlay
        
        NSLog("DirectRenderer: Initialized successfully with device: \(dev.name)")
    }
    
    // MARK: - Configuration
    
    func configure(
        from settings: CaptureSettings,
        targetFPS: Int = 120,
        sourceSize: CGSize? = nil,
        outputSize: CGSize? = nil
    ) {
        self.currentSettings = settings
        
        // Configure MetalFX scaler if upscaling is enabled
        if settings.isUpscalingEnabled, let source = sourceSize, let output = outputSize {
            metalEngine.configureScaler(
                inputSize: source,
                outputSize: output,
                colorProcessingMode: settings.qualityMode.scalerMode
            )
        }
        
        NSLog("DirectRenderer: Configured - Upscale: \(settings.scalingType.rawValue), FrameGen: \(settings.frameGenMode.rawValue)")
    }
    
    // MARK: - Capture Control
    
    func startCapture(windowID: CGWindowID, pid: pid_t = 0) -> Bool {
        guard !isCapturing else {
            NSLog("DirectRenderer: Already capturing")
            return false
        }
        
        targetWindowID = windowID
        targetPID = pid
        
        Task {
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(
                    false,
                    onScreenWindowsOnly: true
                )
                
                guard let window = content.windows.first(where: { $0.windowID == windowID }) else {
                    NSLog("DirectRenderer: Window \(windowID) not found")
                    await MainActor.run {
                        onWindowLost?()
                    }
                    return
                }
                
                let filter = SCContentFilter(desktopIndependentWindow: window)
                
                let config = SCStreamConfiguration()
                config.width = Int(window.frame.width) * 2 // Retina
                config.height = Int(window.frame.height) * 2
                config.minimumFrameInterval = CMTime(value: 1, timescale: 60)
                config.pixelFormat = kCVPixelFormatType_32BGRA
                config.queueDepth = 3
                config.showsCursor = currentSettings?.captureCursor ?? true
                
                let stream = SCStream(filter: filter, configuration: config, delegate: nil)
                
                let output = StreamOutput { [weak self] sampleBuffer in
                    self?.processCapturedFrame(sampleBuffer)
                }
                
                try stream.addStreamOutput(output, type: .screen, sampleHandlerQueue: captureQueue)
                try await stream.startCapture()
                
                await MainActor.run {
                    self.captureStream = stream
                    self.streamOutput = output
                    self.isCapturing = true
                    NSLog("DirectRenderer: Capture started for window \(windowID)")
                }
                
            } catch {
                NSLog("DirectRenderer: Failed to start capture: \(error)")
                await MainActor.run {
                    onWindowLost?()
                }
            }
        }
        
        return true
    }
    
    func stopCapture() {
        guard isCapturing else { return }
        
        Task {
            do {
                try await captureStream?.stopCapture()
            } catch {
                NSLog("DirectRenderer: Error stopping capture: \(error)")
            }
            
            await MainActor.run {
                self.captureStream = nil
                self.streamOutput = nil
                self.isCapturing = false
                self.metalEngine.reset()
                NSLog("DirectRenderer: Capture stopped")
            }
        }
    }
    
    func pauseCapture() {
        // ScreenCaptureKit doesn't have explicit pause, so we stop processing
        isCapturing = false
    }
    
    func resumeCapture() {
        isCapturing = true
    }
    
    // MARK: - Frame Processing
    
    private func processCapturedFrame(_ sampleBuffer: CMSampleBuffer) {
        guard isCapturing, sampleBuffer.isValid else { return }
        
        autoreleasepool {
            guard let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer),
                  let settings = currentSettings else {
                return
            }
            
            frameSemaphore.wait()
            
            metalEngine.processFrame(imageBuffer, settings: settings) { [weak self] processedTexture in
                guard let self = self else {
                    self?.frameSemaphore.signal()
                    return
                }
                
                Task { @MainActor in
                    if let texture = processedTexture {
                        self.displayTexture = texture
                        self.frameCount += 1
                        
                        if settings.isFrameGenEnabled {
                            self.interpolatedFrameCount += 1
                        }
                        
                        // Trigger view redraw
                        self.mtkView?.setNeedsDisplay(self.mtkView?.bounds ?? .zero)
                    }
                    
                    self.frameSemaphore.signal()
                }
            }
        }
    }
    
    // MARK: - Window Management
    
    func attachToScreen(
        _ screen: NSScreen? = nil,
        size: CGSize? = nil,
        windowFrame: CGRect? = nil
    ) {
        let targetScreen = screen ?? NSScreen.main ?? NSScreen.screens.first
        guard let targetScreen else {
            NSLog("DirectRenderer: No screen available")
            return
        }
        
        let displaySize = size ?? targetScreen.frame.size
        
        let config = OverlayWindowConfig(
            targetScreen: targetScreen,
            windowFrame: windowFrame,
            size: displaySize,
            refreshRate: 120.0,
            vsyncEnabled: currentSettings?.vsync ?? true,
            adaptiveSyncEnabled: currentSettings?.adaptiveSync ?? true,
            passThrough: true
        )
        
        guard let overlayManager, overlayManager.createOverlay(config: config) else {
            NSLog("DirectRenderer: Failed to create overlay")
            return
        }
        
        let view = MTKView(frame: CGRect(origin: .zero, size: displaySize), device: device)
        view.clearColor = MTLClearColorMake(0, 0, 0, 0)
        view.colorPixelFormat = .bgra8Unorm
        view.framebufferOnly = true
        view.autoResizeDrawable = true
        view.layer?.isOpaque = false
        view.enableSetNeedsDisplay = true
        view.isPaused = false
        view.preferredFramesPerSecond = 120
        view.delegate = self
        
        if let layer = view.layer as? CAMetalLayer {
            layer.displaySyncEnabled = currentSettings?.vsync ?? true
            layer.presentsWithTransaction = false
            layer.wantsExtendedDynamicRangeContent = false
            layer.maximumDrawableCount = 3
            layer.allowsNextDrawableTimeout = true
            layer.pixelFormat = .bgra8Unorm
            layer.isOpaque = false
            
            let backingScale = targetScreen.backingScaleFactor
            layer.drawableSize = CGSize(
                width: displaySize.width * backingScale,
                height: displaySize.height * backingScale
            )
        }
        
        overlayManager.setMTKView(view)
        self.mtkView = view
        
        if targetWindowID != 0 {
            overlayManager.setTargetWindow(targetWindowID, pid: targetPID)
        }
        
        NSLog("DirectRenderer: Attached to screen with size \(Int(displaySize.width))x\(Int(displaySize.height))")
    }
    
    func detachWindow() {
        mtkView?.isPaused = true
        mtkView?.delegate = nil
        mtkView = nil
        overlayManager?.destroyOverlay()
        NSLog("DirectRenderer: Detached from window")
    }
    
    // MARK: - Statistics
    
    func getStats() -> DirectEngineStats {
        let now = CACurrentMediaTime()
        
        // Update FPS calculation
        fpsCounter += 1
        if fpsTimer == 0 {
            fpsTimer = now
        }
        
        let elapsed = now - fpsTimer
        if elapsed >= 0.5 {
            currentFPS = Float(fpsCounter) / Float(elapsed)
            interpolatedFPS = currentSettings?.isFrameGenEnabled ?? false
                ? currentFPS * Float(currentSettings?.frameGenMultiplier.intValue ?? 1)
                : currentFPS
            fpsCounter = 0
            fpsTimer = now
        }
        
        return DirectEngineStats(
            fps: currentFPS,
            interpolatedFPS: interpolatedFPS,
            captureFPS: currentFPS,
            frameTime: Float(processingTime),
            gpuTime: Float(processingTime * 0.8),
            captureLatency: Float(processingTime * 0.1),
            presentLatency: Float(processingTime * 0.1),
            frameCount: frameCount,
            interpolatedFrameCount: interpolatedFrameCount,
            droppedFrames: droppedFrames,
            gpuMemoryUsed: 0,
            gpuMemoryTotal: 0,
            textureMemoryUsed: 0,
            renderEncoders: 0,
            computeEncoders: 0,
            blitEncoders: 0,
            commandBuffers: 0,
            drawCalls: 0,
            upscaleMode: 0,
            frameGenMode: 0,
            aaMode: 0
        )
    }
}

// MARK: - MTKViewDelegate

@available(macOS 15.0, *)
extension DirectRenderer: MTKViewDelegate {
    
    nonisolated func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        // Handle drawable size changes if needed
    }
    
    nonisolated func draw(in view: MTKView) {
        Task { @MainActor in
            autoreleasepool {
                guard let texture = self.displayTexture,
                      let commandBuffer = self.commandQueue.makeCommandBuffer(),
                      let drawable = view.currentDrawable else {
                    return
                }
                
                commandBuffer.label = "DirectRenderer Display"
                
                let startTime = CACurrentMediaTime()
                
                // Render texture to drawable
                _ = self.metalEngine.renderToDrawable(
                    texture: texture,
                    drawable: drawable,
                    commandBuffer: commandBuffer
                )
                
                commandBuffer.addCompletedHandler { [weak self] _ in
                    Task { @MainActor in
                        let endTime = CACurrentMediaTime()
                        self?.processingTime = (endTime - startTime) * 1000.0
                    }
                }
                
                commandBuffer.commit()
                
                // Update window position if tracking a window
                self.overlayManager?.updateWindowPosition()
            }
        }
    }
}

// MARK: - StreamOutput Helper

@available(macOS 15.0, *)
private class StreamOutput: NSObject, SCStreamOutput {
    private let handler: (CMSampleBuffer) -> Void
    
    init(handler: @escaping (CMSampleBuffer) -> Void) {
        self.handler = handler
        super.init()
    }
    
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen else { return }
        handler(sampleBuffer)
    }
}

// MARK: - Stats Structure

struct DirectEngineStats {
    var fps: Float
    var interpolatedFPS: Float
    var captureFPS: Float
    var frameTime: Float
    var gpuTime: Float
    var captureLatency: Float
    var presentLatency: Float
    var frameCount: UInt64
    var interpolatedFrameCount: UInt64
    var droppedFrames: UInt64
    var gpuMemoryUsed: UInt64
    var gpuMemoryTotal: UInt64
    var textureMemoryUsed: UInt64
    var renderEncoders: UInt32
    var computeEncoders: UInt32
    var blitEncoders: UInt32
    var commandBuffers: UInt32
    var drawCalls: UInt32
    var upscaleMode: UInt32
    var frameGenMode: UInt32
    var aaMode: UInt32
}
