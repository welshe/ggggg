import Metal
import MetalKit
import MetalFX
import CoreVideo
import Vision
import Accelerate

// MARK: - Constants & Structures

struct InterpolationConstants {
    var interpolationFactor: Float
    var motionScale: Float
    var textureSize: SIMD2<Float>
}

struct SharpenConstants {
    var sharpness: Float
    var radius: Float
}

struct AAConstants {
    var threshold: Float
    var subpixelBlend: Float
}

@available(macOS 15.0, *)
class MetalEngine {
    
    // MARK: - Properties
    
    let device: MTLDevice
    let commandQueue: MTLCommandQueue
    private let textureCache: CVMetalTextureCache
    
    // Compute Pipeline States
    private var interpolatePSO: MTLComputePipelineState?
    private var interpolateSimplePSO: MTLComputePipelineState?
    private var sharpenPSO: MTLComputePipelineState?
    private var fxaaPSO: MTLComputePipelineState?
    private var bilinearUpscalePSO: MTLComputePipelineState?
    private var copyPSO: MTLComputePipelineState?
    private var motionEstimationPSO: MTLComputePipelineState?
    
    // Render Pipeline State (for final display)
    private var renderPipelineState: MTLRenderPipelineState?
    private var samplerState: MTLSamplerState?
    
    // MetalFX Scaler
    private var spatialScaler: MTLFXSpatialScaler?
    private var scalerInputSize: CGSize = .zero
    private var scalerOutputSize: CGSize = .zero
    
    // Texture Management
    private var previousTexture: MTLTexture?
    private var currentTexture: MTLTexture?
    private var interpolatedTexture: MTLTexture?
    private var sharpenedTexture: MTLTexture?
    private var outputTexture: MTLTexture?
    private var motionTexture: MTLTexture?
    
    // Vision-based Motion Estimation
    private let sequenceHandler = VNSequenceRequestHandler()
    private var lastPixelBuffer: CVPixelBuffer?
    
    // Frame History
    private var frameHistory: [FrameData] = []
    private let maxHistorySize = 4
    
    // Statistics
    private(set) var currentFPS: Float = 0.0
    private(set) var processingTime: Double = 0.0
    private var lastFrameTime: CFTimeInterval = 0
    private var frameCount: Int = 0
    private var fpsUpdateTime: CFTimeInterval = 0
    
    struct FrameData {
        let texture: MTLTexture
        let timestamp: CFTimeInterval
        let pixelBuffer: CVPixelBuffer?
    }
    
    // MARK: - Initialization
    
    init?(device: MTLDevice? = nil) {
        guard let dev = device ?? MTLCreateSystemDefaultDevice() else {
            NSLog("MetalEngine: Failed to create Metal device")
            return nil
        }
        
        guard let queue = dev.makeCommandQueue() else {
            NSLog("MetalEngine: Failed to create command queue")
            return nil
        }
        
        self.device = dev
        self.commandQueue = queue
        
        var cache: CVMetalTextureCache?
        let status = CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, dev, nil, &cache)
        guard status == kCVReturnSuccess, let cache = cache else {
            NSLog("MetalEngine: Failed to create texture cache")
            return nil
        }
        self.textureCache = cache
        
        setupPipelines()
        setupSampler()
        
        NSLog("MetalEngine: Initialized successfully with device: \(dev.name)")
    }
    
    // MARK: - Pipeline Setup
    
    private func setupPipelines() {
        guard let library = device.makeDefaultLibrary() else {
            NSLog("MetalEngine: Failed to load default library")
            return
        }
        
        // Compute Pipelines
        do {
            if let function = library.makeFunction(name: "interpolateFrames") {
                interpolatePSO = try device.makeComputePipelineState(function: function)
            }
            
            if let function = library.makeFunction(name: "interpolateSimple") {
                interpolateSimplePSO = try device.makeComputePipelineState(function: function)
            }
            
            if let function = library.makeFunction(name: "contrastAdaptiveSharpening") {
                sharpenPSO = try device.makeComputePipelineState(function: function)
            }
            
            if let function = library.makeFunction(name: "applyFXAA") {
                fxaaPSO = try device.makeComputePipelineState(function: function)
            }
            
            if let function = library.makeFunction(name: "bilinearUpscale") {
                bilinearUpscalePSO = try device.makeComputePipelineState(function: function)
            }
            
            if let function = library.makeFunction(name: "copyTexture") {
                copyPSO = try device.makeComputePipelineState(function: function)
            }
            
            if let function = library.makeFunction(name: "estimateMotion") {
                motionEstimationPSO = try device.makeComputePipelineState(function: function)
            }
            
            NSLog("MetalEngine: Compute pipelines created successfully")
        } catch {
            NSLog("MetalEngine: Failed to create compute pipelines: \(error)")
        }
        
        // Render Pipeline (for final display)
        do {
            guard let vertexFunc = library.makeFunction(name: "texture_vertex"),
                  let fragmentFunc = library.makeFunction(name: "texture_fragment") else {
                NSLog("MetalEngine: Failed to find vertex/fragment functions")
                return
            }
            
            let pipelineDesc = MTLRenderPipelineDescriptor()
            pipelineDesc.vertexFunction = vertexFunc
            pipelineDesc.fragmentFunction = fragmentFunc
            pipelineDesc.colorAttachments[0].pixelFormat = .bgra8Unorm
            pipelineDesc.colorAttachments[0].isBlendingEnabled = false
            
            renderPipelineState = try device.makeRenderPipelineState(descriptor: pipelineDesc)
            NSLog("MetalEngine: Render pipeline created successfully")
        } catch {
            NSLog("MetalEngine: Failed to create render pipeline: \(error)")
        }
    }
    
    private func setupSampler() {
        let samplerDesc = MTLSamplerDescriptor()
        samplerDesc.minFilter = .linear
        samplerDesc.magFilter = .linear
        samplerDesc.sAddressMode = .clampToEdge
        samplerDesc.tAddressMode = .clampToEdge
        samplerDesc.mipFilter = .notMipmapped
        samplerState = device.makeSamplerState(descriptor: samplerDesc)
    }
    
    // MARK: - Scaler Configuration
    
    func configureScaler(
        inputSize: CGSize,
        outputSize: CGSize,
        colorProcessingMode: MTLFXSpatialScalerColorProcessingMode = .perceptual
    ) {
        guard inputSize.width > 0, inputSize.height > 0,
              outputSize.width > 0, outputSize.height > 0 else {
            NSLog("MetalEngine: Invalid scaler dimensions")
            return
        }
        
        // Check if reconfiguration is needed
        if scalerInputSize == inputSize && scalerOutputSize == outputSize && spatialScaler != nil {
            return
        }
        
        let descriptor = MTLFXSpatialScalerDescriptor()
        descriptor.inputWidth = Int(inputSize.width)
        descriptor.inputHeight = Int(inputSize.height)
        descriptor.outputWidth = Int(outputSize.width)
        descriptor.outputHeight = Int(outputSize.height)
        descriptor.colorTextureFormat = .bgra8Unorm
        descriptor.outputTextureFormat = .bgra8Unorm
        descriptor.colorProcessingMode = colorProcessingMode
        
        guard let scaler = descriptor.makeSpatialScaler(device: device) else {
            NSLog("MetalEngine: Failed to create MetalFX scaler")
            return
        }
        
        spatialScaler = scaler
        scalerInputSize = inputSize
        scalerOutputSize = outputSize
        
        // Create output texture
        let outputDesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: Int(outputSize.width),
            height: Int(outputSize.height),
            mipmapped: false
        )
        outputDesc.usage = [.shaderWrite, .shaderRead, .renderTarget]
        outputDesc.storageMode = .private
        outputTexture = device.makeTexture(descriptor: outputDesc)
        
        NSLog("MetalEngine: Configured scaler - Input: \(Int(inputSize.width))x\(Int(inputSize.height)), Output: \(Int(outputSize.width))x\(Int(outputSize.height))")
    }
    
    // MARK: - Frame Processing
    
    func processFrame(
        _ imageBuffer: CVImageBuffer,
        settings: CaptureSettings,
        completion: @escaping (MTLTexture?) -> Void
    ) {
        autoreleasepool {
            guard let texture = makeTexture(from: imageBuffer) else {
                NSLog("MetalEngine: Failed to create texture from image buffer")
                completion(nil)
                return
            }
            
            guard let commandBuffer = commandQueue.makeCommandBuffer() else {
                NSLog("MetalEngine: Failed to create command buffer")
                completion(nil)
                return
            }
            commandBuffer.label = "MetalEngine Processing"
            
            let startTime = CACurrentMediaTime()
            
            // Store current frame in history
            storeFrame(texture: texture, pixelBuffer: imageBuffer as? CVPixelBuffer, timestamp: startTime)
            
            var processedTexture = texture
            
            // Frame interpolation if enabled
            if settings.isFrameGenEnabled, let previous = previousTexture {
                if let interpolated = interpolateFrames(
                    previous: previous,
                    current: texture,
                    t: 0.5,
                    settings: settings,
                    commandBuffer: commandBuffer
                ) {
                    processedTexture = interpolated
                }
            }
            
            // Apply anti-aliasing if enabled
            if settings.aaMode != .off {
                if let aaResult = applyAntiAliasing(
                    processedTexture,
                    mode: settings.aaMode,
                    commandBuffer: commandBuffer
                ) {
                    processedTexture = aaResult
                }
            }
            
            // Upscaling
            if settings.isUpscalingEnabled {
                if let upscaled = upscale(
                    processedTexture,
                    settings: settings,
                    commandBuffer: commandBuffer
                ) {
                    processedTexture = upscaled
                }
            }
            
            // Apply sharpening if needed
            if settings.sharpening > 0.01 {
                if let sharpened = applySharpen(
                    processedTexture,
                    intensity: settings.sharpening,
                    commandBuffer: commandBuffer
                ) {
                    processedTexture = sharpened
                }
            }
            
            commandBuffer.addCompletedHandler { [weak self] buffer in
                guard let self = self else { return }
                let endTime = CACurrentMediaTime()
                self.processingTime = (endTime - startTime) * 1000.0
                self.updateFPS(timestamp: endTime)
                completion(processedTexture)
            }
            
            commandBuffer.commit()
            
            // Update previous frame
            previousTexture = texture
        }
    }
    
    // MARK: - Frame Interpolation
    
    private func interpolateFrames(
        previous: MTLTexture,
        current: MTLTexture,
        t: Float,
        settings: CaptureSettings,
        commandBuffer: MTLCommandBuffer
    ) -> MTLTexture? {
        
        // Create interpolated texture if needed
        if interpolatedTexture == nil ||
           interpolatedTexture!.width != current.width ||
           interpolatedTexture!.height != current.height {
            let desc = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .bgra8Unorm,
                width: current.width,
                height: current.height,
                mipmapped: false
            )
            desc.usage = [.shaderWrite, .shaderRead]
            desc.storageMode = .private
            interpolatedTexture = device.makeTexture(descriptor: desc)
        }
        
        guard let outputTex = interpolatedTexture else { return nil }
        
        // Use simple interpolation if motion vectors not available
        guard let pso = interpolateSimplePSO,
              let encoder = commandBuffer.makeComputeCommandEncoder() else {
            return nil
        }
        
        encoder.label = "Frame Interpolation"
        encoder.setComputePipelineState(pso)
        encoder.setTexture(current, index: 0)
        encoder.setTexture(previous, index: 1)
        encoder.setTexture(outputTex, index: 2)
        
        var tValue = t
        encoder.setBytes(&tValue, length: MemoryLayout<Float>.size, index: 0)
        
        let threadgroupSize = MTLSize(width: 16, height: 16, depth: 1)
        let threadgroups = MTLSize(
            width: (current.width + 15) / 16,
            height: (current.height + 15) / 16,
            depth: 1
        )
        
        encoder.dispatchThreadgroups(threadgroups, threadsPerThreadgroup: threadgroupSize)
        encoder.endEncoding()
        
        return outputTex
    }
    
    // MARK: - Anti-Aliasing
    
    private func applyAntiAliasing(
        _ texture: MTLTexture,
        mode: CaptureSettings.AAMode,
        commandBuffer: MTLCommandBuffer
    ) -> MTLTexture? {
        guard mode == .fxaa, let pso = fxaaPSO else {
            return texture
        }
        
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: texture.pixelFormat,
            width: texture.width,
            height: texture.height,
            mipmapped: false
        )
        desc.usage = [.shaderWrite, .shaderRead]
        desc.storageMode = .private
        
        guard let outputTex = device.makeTexture(descriptor: desc),
              let encoder = commandBuffer.makeComputeCommandEncoder() else {
            return texture
        }
        
        encoder.label = "FXAA"
        encoder.setComputePipelineState(pso)
        encoder.setTexture(texture, index: 0)
        encoder.setTexture(outputTex, index: 1)
        
        var constants = AAConstants(threshold: 0.166, subpixelBlend: 0.75)
        encoder.setBytes(&constants, length: MemoryLayout<AAConstants>.size, index: 0)
        
        let threadgroupSize = MTLSize(width: 16, height: 16, depth: 1)
        let threadgroups = MTLSize(
            width: (texture.width + 15) / 16,
            height: (texture.height + 15) / 16,
            depth: 1
        )
        
        encoder.dispatchThreadgroups(threadgroups, threadsPerThreadgroup: threadgroupSize)
        encoder.endEncoding()
        
        return outputTex
    }
    
    // MARK: - Upscaling
    
    private func upscale(
        _ texture: MTLTexture,
        settings: CaptureSettings,
        commandBuffer: MTLCommandBuffer
    ) -> MTLTexture? {
        
        let inputSize = CGSize(width: texture.width, height: texture.height)
        let scaleFactor = CGFloat(settings.scaleFactor.floatValue)
        let outputSize = CGSize(
            width: inputSize.width * scaleFactor,
            height: inputSize.height * scaleFactor
        )
        
        // Use MetalFX for MGUP-1 modes
        if settings.scalingType.usesMetalFX {
            configureScaler(
                inputSize: inputSize,
                outputSize: outputSize,
                colorProcessingMode: settings.qualityMode.scalerMode
            )
            
            guard let scaler = spatialScaler,
                  let output = outputTexture else {
                return fallbackUpscale(texture, outputSize: outputSize, commandBuffer: commandBuffer)
            }
            
            scaler.colorTexture = texture
            scaler.outputTexture = output
            scaler.encode(commandBuffer: commandBuffer)
            
            return output
        } else {
            // Fallback to bilinear
            return fallbackUpscale(texture, outputSize: outputSize, commandBuffer: commandBuffer)
        }
    }
    
    private func fallbackUpscale(
        _ texture: MTLTexture,
        outputSize: CGSize,
        commandBuffer: MTLCommandBuffer
    ) -> MTLTexture? {
        guard let pso = bilinearUpscalePSO else { return texture }
        
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: texture.pixelFormat,
            width: Int(outputSize.width),
            height: Int(outputSize.height),
            mipmapped: false
        )
        desc.usage = [.shaderWrite, .shaderRead]
        desc.storageMode = .private
        
        guard let outputTex = device.makeTexture(descriptor: desc),
              let encoder = commandBuffer.makeComputeCommandEncoder() else {
            return texture
        }
        
        encoder.label = "Bilinear Upscale"
        encoder.setComputePipelineState(pso)
        encoder.setTexture(texture, index: 0)
        encoder.setTexture(outputTex, index: 1)
        
        let threadgroupSize = MTLSize(width: 16, height: 16, depth: 1)
        let threadgroups = MTLSize(
            width: (Int(outputSize.width) + 15) / 16,
            height: (Int(outputSize.height) + 15) / 16,
            depth: 1
        )
        
        encoder.dispatchThreadgroups(threadgroups, threadsPerThreadgroup: threadgroupSize)
        encoder.endEncoding()
        
        return outputTex
    }
    
    // MARK: - Sharpening
    
    private func applySharpen(
        _ texture: MTLTexture,
        intensity: Float,
        commandBuffer: MTLCommandBuffer
    ) -> MTLTexture? {
        guard let pso = sharpenPSO else { return texture }
        
        if sharpenedTexture == nil ||
           sharpenedTexture!.width != texture.width ||
           sharpenedTexture!.height != texture.height {
            let desc = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: texture.pixelFormat,
                width: texture.width,
                height: texture.height,
                mipmapped: false
            )
            desc.usage = [.shaderWrite, .shaderRead]
            desc.storageMode = .private
            sharpenedTexture = device.makeTexture(descriptor: desc)
        }
        
        guard let outputTex = sharpenedTexture,
              let encoder = commandBuffer.makeComputeCommandEncoder() else {
            return texture
        }
        
        encoder.label = "CAS Sharpening"
        encoder.setComputePipelineState(pso)
        encoder.setTexture(texture, index: 0)
        encoder.setTexture(outputTex, index: 1)
        
        var constants = SharpenConstants(sharpness: intensity, radius: 1.0)
        encoder.setBytes(&constants, length: MemoryLayout<SharpenConstants>.size, index: 0)
        
        let threadgroupSize = MTLSize(width: 16, height: 16, depth: 1)
        let threadgroups = MTLSize(
            width: (texture.width + 15) / 16,
            height: (texture.height + 15) / 16,
            depth: 1
        )
        
        encoder.dispatchThreadgroups(threadgroups, threadsPerThreadgroup: threadgroupSize)
        encoder.endEncoding()
        
        return outputTex
    }
    
    // MARK: - Texture Creation
    
    private func makeTexture(from imageBuffer: CVImageBuffer) -> MTLTexture? {
        let width = CVPixelBufferGetWidth(imageBuffer)
        let height = CVPixelBufferGetHeight(imageBuffer)
        
        var cvTexture: CVMetalTexture?
        let status = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault,
            textureCache,
            imageBuffer,
            nil,
            .bgra8Unorm,
            width,
            height,
            0,
            &cvTexture
        )
        
        guard status == kCVReturnSuccess, let cvTex = cvTexture else {
            return nil
        }
        
        return CVMetalTextureGetTexture(cvTex)
    }
    
    // MARK: - Frame History Management
    
    private func storeFrame(texture: MTLTexture, pixelBuffer: CVPixelBuffer?, timestamp: CFTimeInterval) {
        let frame = FrameData(texture: texture, timestamp: timestamp, pixelBuffer: pixelBuffer)
        frameHistory.append(frame)
        
        if frameHistory.count > maxHistorySize {
            frameHistory.removeFirst()
        }
    }
    
    // MARK: - FPS Tracking
    
    private func updateFPS(timestamp: CFTimeInterval) {
        frameCount += 1
        
        if fpsUpdateTime == 0 {
            fpsUpdateTime = timestamp
            return
        }
        
        let elapsed = timestamp - fpsUpdateTime
        if elapsed >= 0.5 {
            currentFPS = Float(frameCount) / Float(elapsed)
            frameCount = 0
            fpsUpdateTime = timestamp
        }
    }
    
    // MARK: - Render to Drawable
    
    func renderToDrawable(
        texture: MTLTexture,
        drawable: CAMetalDrawable,
        commandBuffer: MTLCommandBuffer
    ) -> Bool {
        guard let pipelineState = renderPipelineState,
              let sampler = samplerState else {
            NSLog("MetalEngine: Missing render pipeline or sampler")
            return false
        }
        
        let renderPassDesc = MTLRenderPassDescriptor()
        renderPassDesc.colorAttachments[0].texture = drawable.texture
        renderPassDesc.colorAttachments[0].loadAction = .clear
        renderPassDesc.colorAttachments[0].storeAction = .store
        renderPassDesc.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0)
        
        guard let renderEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDesc) else {
            NSLog("MetalEngine: Failed to create render encoder")
            return false
        }
        
        renderEncoder.label = "Final Render"
        renderEncoder.setRenderPipelineState(pipelineState)
        renderEncoder.setFragmentTexture(texture, index: 0)
        renderEncoder.setFragmentSamplerState(sampler, index: 0)
        renderEncoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        renderEncoder.endEncoding()
        
        commandBuffer.present(drawable)
        return true
    }
    
    // MARK: - Cleanup
    
    func reset() {
        previousTexture = nil
        currentTexture = nil
        interpolatedTexture = nil
        sharpenedTexture = nil
        motionTexture = nil
        frameHistory.removeAll()
        currentFPS = 0
        frameCount = 0
        fpsUpdateTime = 0
    }
}
