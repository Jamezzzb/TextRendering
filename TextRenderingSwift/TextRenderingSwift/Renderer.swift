import MetalKit
import simd

final class Renderer: NSObject, MTKViewDelegate {
    private var commandQueue: MTLCommandQueue
    private var fontAtlas: FontAtlas
    private var parent: MTLTextView
    private let loader: MTKTextureLoader
    private let allocator: MTKMeshBufferAllocator
    // TODO: Probably shouldn't implicitly unwrap all of these.
    private var device: MTLDevice! = MTLCreateSystemDefaultDevice()
    private var sampler: MTLSamplerState!
    private var pipelineState: MTLRenderPipelineState!
    private var fontTexture: MTLTexture!
    private var textMesh: TextMesh!
    private var uniformBuffer: MTLBuffer!
    private var depthTexture: MTLTexture!
    private var textTranslation: CGPoint!
    private var textScale: CGFloat!
    init(_ parent: MTLTextView) {
        self.parent = parent
        self.fontAtlas = Self.makeFontAtlasIfNeeded()
        self.textScale = 1.0
        self.textTranslation = CGPointMake(0, 0)
        commandQueue = device.makeCommandQueue()!
        loader = MTKTextureLoader(device: device)
        allocator = MTKMeshBufferAllocator(device: device)
        let mdlTex = MDLTexture(
            data: fontAtlas.textureData,
            topLeftOrigin: true, name: "font texture",
            dimensions: vector_int2(2048, 2048),
            rowStride: 2048, channelCount: 1,
            channelEncoding: .uint8, isCube: false)
        fontTexture = try! loader.newTexture(texture: mdlTex)
        super.init()
        initializeMetal()
        makeUniformBuffer()
    }
    
    private enum Constants {
        static var sampleText =
"""
"YEAR OF GLAD
I am seated in an office, surrounded by heads and bodies. My posture is consciously congruent to the shape of my hard chair.
This is a cold room in University Administration, wood-walled, Remington-hung, double-windowed against the November heat,
insulated from Administrative sounds by the reception area outside, at which Uncle Charles, Mr. deLint and I were lately received.
I am in here.
Three faces have resolved into place above summer-weight sportcoats and half-Windsors across a polished pine conference
table shiny with the spidered light of an Arizona noon. These are three Deans — of Admissions, Academic Affairs, Athletic
Affairs. I do not know which face belongs to whom.
I believe I appear neutral, maybe even pleasant, though I've been coached to err on the side of neutrality and not attempt what
would feel to me like a pleasant expression or smile.
I have committed to crossing my legs I hope carefully, ankle on knee, hands together in the lap of my slacks. My fingers are
mated into a mirrored series of what manifests, to me, as the letter X. The interview room's other personnel include: the
University's Director of Composition, its varsity tennis coach, and Academy prorector Mr. A. deLint. C.T. is beside me; the others
sit, stand and stand, respectively, at the periphery of my focus. The tennis coach jingles pocket-change. There is something
vaguely digestive about the room's odor. The high-traction sole of my complimentary Nike sneaker runs parallel to the wobbling
loafer of my mother's half-brother, here in his capacity as Headmaster, sitting in the chair to what I hope is my immediate right,
also facing Deans."
"""
        + "\n--D.F.W, INFINITE JEST"
    }
    
    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
    }
    
    private func initializeMetal() {
        let samplerDescriptor = MTLSamplerDescriptor()
        samplerDescriptor.minFilter = .nearest
        samplerDescriptor.magFilter = .linear
        samplerDescriptor.sAddressMode = .clampToZero
        samplerDescriptor.tAddressMode = .clampToZero
        sampler = device.makeSamplerState(descriptor: samplerDescriptor)!
        let library = device.makeDefaultLibrary()
        let pipelineDescriptor = MTLRenderPipelineDescriptor()
        
        pipelineDescriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        pipelineDescriptor.colorAttachments[0].isBlendingEnabled = true
        pipelineDescriptor.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
        pipelineDescriptor.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        pipelineDescriptor.colorAttachments[0].rgbBlendOperation = .add
        pipelineDescriptor.colorAttachments[0].sourceAlphaBlendFactor = .sourceAlpha
        pipelineDescriptor.colorAttachments[0].sourceAlphaBlendFactor = .oneMinusSourceAlpha
        pipelineDescriptor.colorAttachments[0].alphaBlendOperation = .add
        
        pipelineDescriptor.depthAttachmentPixelFormat = .depth32Float
        pipelineDescriptor.vertexFunction = library!.makeFunction(name: "vertex_shade")
        pipelineDescriptor.fragmentFunction = library!.makeFunction(name: "fragment_shade")
        pipelineDescriptor.vertexDescriptor = MTKMetalVertexDescriptorFromModelIO(TextMesh.vertexDescriptor)
        pipelineState = try! device.makeRenderPipelineState(descriptor: pipelineDescriptor)
    }
    
    private func makeTextMesh(_ view: MTKView) {
        textMesh = TextMesh(
            withString: Constants.sampleText,
            inRect: CGRect(
                x: 0, y: 0,
                width: view.drawableSize.width,
                height: view.drawableSize.height),
            withFontAtlas: fontAtlas,
            atSize: 48,
            device: device!)
    }
    
    private func makeUniformBuffer() {
        uniformBuffer = device.makeBuffer(length: MemoryLayout<Uniforms>.stride)
        uniformBuffer.label = "uniform buffer"
    }
    
    private func makeDepthTexture(_ view: MTKView) {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .depth32Float,
            width: Int(view.drawableSize.width),
            height: Int(view.drawableSize.height),
            mipmapped: false)
        descriptor.usage = .renderTarget
        descriptor.storageMode = .private
        depthTexture = device.makeTexture(descriptor: descriptor)
        depthTexture.label = "Depth Texture"
    }
    
    private func renderPassDescriptor(_ view: MTKView) -> MTLRenderPassDescriptor? {
        if let renderPass = view.currentRenderPassDescriptor {
            renderPass.colorAttachments[0].texture = view.currentDrawable?.texture
            renderPass.colorAttachments[0].loadAction = .clear
            renderPass.colorAttachments[0].storeAction = .store
            renderPass.colorAttachments[0].clearColor = .init(red: 0, green: 0, blue: 0.05, alpha: 0)
            
            renderPass.depthAttachment.texture = self.depthTexture
            renderPass.depthAttachment.loadAction = .clear
            renderPass.depthAttachment.storeAction = .store
            renderPass.depthAttachment.clearDepth = 1.0
            return renderPass
        }
        return nil
    }
    
    private func updateUniforms(_ view: MTKView) {
        let translation = vector_float3(Float(textTranslation.x), Float(textTranslation.y), 0)
        let scale = vector_float3(Float(textScale), Float(textScale), 1)
        let modelMatrix = matrix_multiply(
            Math.matrix_translation(translation),
            Math.matrix_scale(scale))
        let projectionMatrix = Math
            .matrix_orthographic_projection(
                0,
                Float(view.drawableSize.width),
                0,
                Float(view.drawableSize.height))
        var uniforms = Uniforms(
            modelMatrix: modelMatrix,
            viewProjectionMatrix: projectionMatrix,
            foregroundColor: .init(0.8, 1, 0.8, 1))
        memcpy(uniformBuffer.contents(), &uniforms, MemoryLayout<Uniforms>.stride)
    }
    
    func draw(in view: MTKView) {
        guard let drawable = view.currentDrawable else { return }
        if textMesh == nil || view.frame.height > 100 {
            makeTextMesh(view)
        }
        if depthTexture == nil ||
            depthTexture.width != Int(view.drawableSize.width) ||
            depthTexture.height != Int(view.drawableSize.height) {
            makeDepthTexture(view)
        }
        updateUniforms(view)
        let renderPass = renderPassDescriptor(view)!
        let commandBuffer = commandQueue.makeCommandBuffer()
        let commandEncoder = commandBuffer?.makeRenderCommandEncoder(descriptor: renderPass)
        commandEncoder?.setFrontFacing(.counterClockwise)
        commandEncoder?.setCullMode(.none)
        commandEncoder?.setRenderPipelineState(pipelineState)
        commandEncoder?.setVertexBuffer(
            textMesh.mtkMesh!.vertexBuffers[0].buffer,
            offset: 0,
            index: 0)
        commandEncoder?.setVertexBuffer(uniformBuffer, offset: 0, index: 1)
        commandEncoder?.setFragmentBuffer(uniformBuffer, offset: 0, index: 0)
        commandEncoder?.setFragmentTexture(fontTexture, index: 0)
        commandEncoder?.setFragmentSamplerState(sampler, index: 0)
        for submesh in textMesh.mtkMesh!.submeshes {
            commandEncoder?.drawIndexedPrimitives(
                type: submesh.primitiveType,
                indexCount: submesh.indexCount,
                indexType: submesh.indexType,
                indexBuffer: submesh.indexBuffer.buffer,
                indexBufferOffset: submesh.indexBuffer.offset)
        }
        commandEncoder?.endEncoding()
        commandBuffer?.present(drawable)
        commandBuffer?.commit()
    }
}

// MARK: Static Methods For Making/Saving/Loading Font Atlas
extension Renderer {
    private static func makeFontAtlasIfNeeded() -> FontAtlas {
        let result = Self.loadAtlas()
        switch result {
        case .some(let wrapped):
            return wrapped
        case _:
            let cfName = "ComicCode-Medium" as CFString
            let font = CTFont.init(cfName, size: 72)
            let fontAtlas = FontAtlas(parentFont: font, textureSize: 2048)
            save(fontAtlas: fontAtlas)
            return fontAtlas
        }
    }
    
    private static func fileURL() throws -> URL {
        try FileManager.default.url(
            for: .documentDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: false)
        .appendingPathComponent("fontAtlas.data")
    }
    
    private static func loadAtlas() -> FontAtlas? {
        do {
            let fileURL = try Self.fileURL()
            let data = try Data(contentsOf: fileURL)
            let decodedAtlas = try JSONDecoder().decode(FontAtlas.self, from: data)
            return decodedAtlas
        } catch {
            return nil
        }
    }
    
    private static func save(fontAtlas: FontAtlas) {
        Task {
            let task = Task {
                let data = try JSONEncoder().encode(fontAtlas)
                let outfile = try Self.fileURL()
                try data.write(to: outfile)
            }
            _ = try await task.value
        }
    }
}
