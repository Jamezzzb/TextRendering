import CoreText
import MetalKit
import simd

struct TextMesh {
    private(set) var mtkMesh: MTKMesh?
    
    init(
        withString string: String,
        inRect rect: CGRect,
        withFontAtlas fontAtlas: FontAtlas,
        atSize fontSize: CGFloat,
        device: MTLDevice
    ) {
        self.getMeshData(
            withString: string,
            inRect: rect,
            withFont: fontAtlas,
            atSize: fontSize, 
            device: device)
    }
    
    private mutating func getMeshData(
        withString string: String,
        inRect rect: CGRect,
        withFont fontAtlas: FontAtlas,
        atSize fontSize: CGFloat,
        device: MTLDevice
    ) {
        let font = CTFontCreateCopyWithAttributes(fontAtlas.parentFont, fontSize, nil, nil)
        let attrString = NSAttributedString(
            string: string,
            attributes: [NSAttributedString.Key.font : font])
        let frame = CTFramesetterCreateFrame(
            CTFramesetterCreateWithAttributedString(attrString),
            CFRangeMake(0, attrString.length),
            CGPath(rect: rect, transform: nil),
            nil)
        var frameGlyphCount = 0
        // Valid, if there is nothing here we do not increment count
        (CTFrameGetLines(frame) as? [CTLine])?.forEach({ line in
            frameGlyphCount += CTLineGetGlyphCount(line)
        })
        let vertexCount = frameGlyphCount * 4
        let indexCount = frameGlyphCount * 6
        var vertices = [Vertex]()
        vertices.reserveCapacity(vertexCount)
        var indices = [simd_ushort1]()
        indices.reserveCapacity(indexCount)
        // for each glyph we make a square, divided into two triangles gives us 6 indices
        // metal uses 4 homog coords is why float4
        enumerateGlyphs(inFrame: frame) { glyph, glyphIndex, glyphBounds in
            let glyphInfo = fontAtlas.glyphDescriptors[glyph]!
            let minX = Float(glyphBounds.minX)
            let maxX = Float(glyphBounds.maxX)
            let minY = Float(glyphBounds.minY)
            let maxY = Float(glyphBounds.maxY)
            let minS = Float(glyphInfo.topLeftTexCoord.x)
            let maxS = Float(glyphInfo.bottomRightTexCoord.x)
            let minT = Float(glyphInfo.topLeftTexCoord.y)
            let maxT = Float(glyphInfo.bottomRightTexCoord.y)
            vertices.append(Vertex(
                position: packed_float4(minX, maxY, 0, 1),
                textCoords: packed_float2(minS, maxT)))
            vertices.append(Vertex(
                position: packed_float4(minX, minY, 0, 1),
                textCoords: packed_float2(minS, minT)))
            vertices.append(Vertex(
                position: packed_float4(maxX, minY, 0, 1),
                textCoords: packed_float2(maxS, minT)))
            vertices.append(Vertex(
                position: packed_float4(maxX, maxY, 0, 1),
                textCoords: packed_float2(maxS, maxT)))
            indices.append(simd_ushort1(glyphIndex * 4))
            indices.append(simd_ushort1(glyphIndex * 4 + 1))
            indices.append(simd_ushort1(glyphIndex * 4 + 2))
            indices.append(simd_ushort1(glyphIndex * 4 + 2))
            indices.append(simd_ushort1(glyphIndex * 4 + 3))
            indices.append(simd_ushort1(glyphIndex * 4))
        }
        // Use data to make the mesh
        makeMesh(vertices, indices, device)
    }
    
    private mutating func makeMesh(
        _ vertices: Array<Vertex>,
        _ indices: Array<simd_ushort1>,
        _ device: MTLDevice
    ) {
        // TODO: This can fail if no vertices!
        // may be good place to use optional?
        let allocator = MTKMeshBufferAllocator(device: device)
        let vBuffer = allocator
            .newBuffer(
                with: Data(
                    bytes: vertices,
                    count: vertices.count * MemoryLayout<Vertex>.stride),
                type: MDLMeshBufferType.vertex)
        let iBuffer = allocator
            .newBuffer(
                with: Data(
                    bytes: indices,
                    count: indices.count * MemoryLayout<simd_ushort1>.stride),
                type: .index)
        let submesh = MDLSubmesh(
            indexBuffer: iBuffer,
            indexCount: indices.count,
            indexType: .uInt16,
            geometryType: .triangles,
            material: nil)
        let mesh = MDLMesh(
            vertexBuffer: vBuffer,
            vertexCount: vertices.count,
            descriptor: Self.vertexDescriptor,
            submeshes: [submesh])
        mtkMesh = try! MTKMesh(mesh: mesh, device: device)
    }
    
    private func enumerateGlyphs(
        inFrame frame: CTFrame,
        completion: ((CGGlyph, Int, CGRect) -> Void)?
    ) {
        guard let completion else { 
            assertionFailure("Completion was nil")
            return
        }
        let entire = CFRangeMake(0, 0)
        let framePath = CTFrameGetPath(frame)
        let frameBoundingRect = framePath.boundingBox
        let lines = CTFrameGetLines(frame) as! [CTLine]
        var lineOriginBuffer  = [CGPoint](repeating: .zero, count: lines.count)
        CTFrameGetLineOrigins(frame, entire, &lineOriginBuffer)
        var glyphIndexInFrame: CFIndex = 0
        let context = CGContext(
            data: nil, 
            width: 1,
            height: 1,
            bitsPerComponent: 8,
            bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
        )
        
        for lineIndex in 0..<lines.count {
            let lineOrigin = lineOriginBuffer[lineIndex]
            let runs = CTLineGetGlyphRuns(lines[lineIndex]) as! [CTRun]
            for run in runs {
                let glyphCount = CTRunGetGlyphCount(run)
                var glyphBuffer = [CGGlyph](repeating: .zero, count: glyphCount)
                CTRunGetGlyphs(run, entire, &glyphBuffer)
                var positionBuffer = [CGPoint](repeating: .zero, count: glyphCount)
                CTRunGetPositions(run, entire, &positionBuffer)
                for glyphIndex in 0..<glyphCount {
                    let glyph = glyphBuffer[glyphIndex]
                    let glyphOrigin = positionBuffer[glyphIndex]
                    var glyphRect = CTRunGetImageBounds(run, context, CFRangeMake(glyphIndex, 1))
                    let boundsTransX = frameBoundingRect.origin.x + lineOrigin.x
                    let boundsTransY = (
                        frameBoundingRect.height + frameBoundingRect.origin.y
                        - lineOrigin.y + glyphOrigin.y)
                    let pathTransform = CGAffineTransform(1, 0, 0, -1, boundsTransX, boundsTransY)
                    glyphRect = glyphRect.applying(pathTransform)
                    completion(glyph, glyphIndexInFrame, glyphRect)
                    glyphIndexInFrame += 1
                }
            }
        }
    }
}

// MARK: Vertex Descriptor
extension TextMesh {
    static let vertexDescriptor: MDLVertexDescriptor = {
        let vertexDescriptor = MTLVertexDescriptor()
        // Position
        vertexDescriptor.attributes[0].format = .float4
        vertexDescriptor.attributes[0].offset = 0
        vertexDescriptor.attributes[0].bufferIndex = 0
        // Texture coordinates
        vertexDescriptor.attributes[1].format = .float2
        vertexDescriptor.attributes[1].offset = MemoryLayout<vector_float4>.stride
        vertexDescriptor.attributes[1].bufferIndex = 0
        
        vertexDescriptor.layouts[0].stepFunction = .perVertex
        vertexDescriptor.layouts[0].stride = MemoryLayout<Vertex>.stride
        
        let meshDescriptor = MTKModelIOVertexDescriptorFromMetal(vertexDescriptor)
        (meshDescriptor.attributes[0] as! MDLVertexAttribute).name = MDLVertexAttributePosition
        (meshDescriptor.attributes[1] as! MDLVertexAttribute).name = MDLVertexAttributeTextureCoordinate
        return meshDescriptor
    }()
}
