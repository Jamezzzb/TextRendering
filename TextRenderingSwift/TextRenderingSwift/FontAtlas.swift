import CoreText
import Accelerate
import simd

struct GlyphDescriptor: Codable {
    let glyphIndex: CGGlyph
    let topLeftTexCoord: CGPoint
    let bottomRightTexCoord: CGPoint
}

extension Array<GlyphDescriptor> {
    subscript(glyph: CGGlyph) -> Element? {
        self.first(where: { $0.glyphIndex == glyph })
    }
}

struct CodableFont: Codable {
    enum CodingKeys: String, CodingKey {
        case name
        case size
    }
    
    let font: CTFont
    
    init(font: CTFont) {
        self.font = font
    }
    
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let name = try values.decode(String.self, forKey: .name)
        let size = try values.decode(CGFloat.self, forKey: .size)
        let cfName = name as CFString
        font = CTFont.init(cfName, size: size)
    }
    
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        let strName = CTFontCopyFullName(font) as String
        let size = CTFontGetSize(font)
        try container.encode(strName, forKey: .name)
        try container.encode(size, forKey: .size)
    }
}

struct FontAtlas: Codable {
    private enum Constants {
        static let size = 4096
    }
    private var codableFont: CodableFont
    private var fontPointSize: CGFloat
    private var textureSize: Int
    private (set) var parentFont: CTFont
    private (set) var glyphDescriptors: [GlyphDescriptor] = []
    private (set) var textureData: Data?
    
    enum CodingKeys: String, CodingKey {
        case codableFont
        case parentFont
        case fontPointSize
        case glyphDescriptors
        case textureSize
        case textureData
    }
    
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let codableFont = try values.decode(CodableFont.self, forKey: .codableFont)
        self.codableFont = codableFont
        fontPointSize = try values.decode(CGFloat.self, forKey: .fontPointSize)
        parentFont = codableFont.font
        glyphDescriptors = try values.decode([GlyphDescriptor].self, forKey: .glyphDescriptors)
        textureSize = try values.decode(Int.self, forKey: .textureSize)
        textureData = try values.decode(Data.self, forKey: .textureData)
        parentFont = codableFont.font
    }
    
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(codableFont, forKey: .codableFont)
        try container.encode(fontPointSize, forKey: .fontPointSize)
        try container.encode(glyphDescriptors, forKey: .glyphDescriptors)
        try container.encode(textureSize, forKey: .textureSize)
        try container.encode(textureData, forKey: .textureData)
    }
    
    init(parentFont: CTFont, textureSize: Int) {
        self.parentFont = parentFont
        self.codableFont = CodableFont(font: parentFont)
        self.fontPointSize = CTFontGetSize(parentFont)
        self.textureSize = textureSize
        self.makeTextureData()
    }
    
    private func estimatedGlyphSize(forFont font: CTFont) -> CGSize {
        let exemplarString = "{ǺOJMQYZa@jmqyw"
        let exemplarStringSize: CGSize = exemplarString.size(withAttributes: [.font: font])
        let averageGlyphWidth: CGFloat = ceil(
            exemplarStringSize.width /
            CGFloat(exemplarString.lengthOfBytes(using: .utf16)))
        return CGSizeMake(averageGlyphWidth, ceil(exemplarStringSize.height))
    }
    
    private func estimatedLineWidth(forFont font: CTFont) -> CGFloat {
        return ceil("!".size(withAttributes: [.font: font]).width)
    }
    
    private func fontIsLikelyToFit(
        _ font: CTFont,
        atSize size: CGFloat,
        inAtlasRect rect: CGRect
    ) -> Bool {
        let textureArea = rect.size.width * rect.size.height
        let trialFont = CTFontCreateCopyWithAttributes(font, size, nil, nil)
        let glyphCount = CTFontGetGlyphCount(trialFont)
        let glyphMargin = estimatedLineWidth(forFont: trialFont)
        let averageGlyphSize = estimatedGlyphSize(forFont: trialFont)
        let estimatedArea = (
            (averageGlyphSize.width + glyphMargin)
        * (averageGlyphSize.height + glyphMargin)
        * CGFloat(glyphCount))
        return estimatedArea < textureArea
    }
    
    private func pointSizeThatFits(
        forFont font: CTFont,
        inAtlasRect rect: CGRect
    ) -> CGFloat {
        
        var fittedSize: CGFloat = CTFontGetSize(font)
        while fontIsLikelyToFit(font, atSize: fittedSize, inAtlasRect: rect) {
            fittedSize += 1
        }
        while !fontIsLikelyToFit(font, atSize: fittedSize, inAtlasRect: rect) {
            fittedSize -= 1
        }
        return fittedSize
    }
    
    private mutating func makeAtlas(
        forFont font: CTFont,
        width: Int,
        height: Int
    ) -> CGImage? {
        // MARK: Get the Font Atlas in bitmap data (mainly just want pixel values)
        let colorSpace = CGColorSpaceCreateDeviceGray()
        let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        )
        let buffer = context?.data?.bindMemory(to: UInt8.self, capacity: width * height)
        context?.setAllowsAntialiasing(false)
        context?.translateBy(x: 0, y: CGFloat(height))
        context?.scaleBy(x: 1, y: -1)
        context?.setFillColor(red: 0, green: 0, blue: 0, alpha: 1)
        context?.fill(CGRectMake(0, 0, CGFloat(width), CGFloat(height)))
        fontPointSize = pointSizeThatFits(
            forFont: font,
            inAtlasRect: CGRectMake(0, 0, CGFloat(width), CGFloat(height)))
        parentFont = CTFontCreateCopyWithAttributes(font, fontPointSize, nil, nil)
        
        let glyphCount = CTFontGetGlyphCount(font)
        let glyphMargin = estimatedLineWidth(forFont: parentFont)
        context?.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
        let fontAscent = CTFontGetAscent(font)
        let fontDescent = CTFontGetDescent(font)
        var origin = CGPointMake(0, fontAscent)
        var maxYCoordForLine: CGFloat = -1
        var glyph: CGGlyph = 0
        while glyph < glyphCount {
            let boundingRect = CTFontGetBoundingRectsForGlyphs(font, .horizontal, &glyph, nil, 1)
            if origin.x + CGRectGetMaxX(boundingRect) + glyphMargin > CGFloat(width) {
                origin.x = 0
                origin.y = maxYCoordForLine + glyphMargin + fontDescent
                maxYCoordForLine = -1
            }
            if origin.y + CGRectGetMaxY(boundingRect) > maxYCoordForLine {
                maxYCoordForLine = origin.y + CGRectGetMaxY(boundingRect)
            }
            let glyphOriginX = origin.x - boundingRect.origin.x + (glyphMargin * 0.5)
            let glyphOriginY = origin.y + (glyphMargin * 0.5)
            
            var glyphTransform = CGAffineTransform(1, 0, 0, -1, glyphOriginX, glyphOriginY)
            let path = CTFontCreatePathForGlyph(font, glyph, &glyphTransform)
            if let path {
                context?.addPath(path)
                context?.fillPath()
            }
            var glyphPathBoundingRect = path?.boundingBoxOfPath ?? CGRectNull
            if glyphPathBoundingRect.equalTo(CGRectNull) {
                glyphPathBoundingRect = CGRectZero
            }
            let texCoordLeft = glyphPathBoundingRect.origin.x / CGFloat(width)
            let texCoordRight = (
                (glyphPathBoundingRect.origin.x + glyphPathBoundingRect.size.width)
            / CGFloat(width))
            let texCoordTop = (glyphPathBoundingRect.origin.y) / CGFloat(height)
            let texCoordBottom = (
                (glyphPathBoundingRect.origin.y + glyphPathBoundingRect.size.height)
            / CGFloat(height))
            let glyphDescriptor = GlyphDescriptor(
                glyphIndex: glyph,
                topLeftTexCoord: CGPointMake(texCoordLeft, texCoordTop),
                bottomRightTexCoord: CGPointMake(texCoordRight, texCoordBottom)
            )
            glyphDescriptors.append(glyphDescriptor)
            origin.x += boundingRect.width + glyphMargin
            glyph += 1
        }
        
        // MARK: Dead reckoning SDF algo implemenation
        guard let buffer else {
            assertionFailure("Buffer is nil!")
            return nil
        }
        // Initialize some arrays and values we need
        let a = UnsafeMutableBufferPointer<UInt8>(start: buffer, count: 16777216)
        var i = 0
        // x and y coordinates in float vector form
        var coords = [simd_float2](repeating: .zero, count: 16777216)
        // Distance of a given pixel to it's nearest boarder point
        var distance = [Float](repeating: .zero, count: 16777216)
        // Store a lookup to a pixel's nearest boarder point
        var nearestPt = [simd_float2](repeating: .zero, count: 16777216)
        // random intermediate vector we use down below
        var z = [Float](repeating: .zero, count: 16777216)
        let distanceDiag = sqrtf(2)
        // MARK: Initialize
        while i < 16777216 {
            // Go through the trouble of getting coordinates in float form and storing them in simd_float2
            // so we can make use of simd_distance later.
            let xCoord = Float(i % 4096)
            let yCoord = Float(i / 4096)
            coords[i] = simd_float2(xCoord, yCoord)
            distance[i] = 5972
            if xCoord < 4095 && xCoord > 0 && yCoord < 4095 && yCoord > 0 &&
                (a[i] != a[i + 1] || a[i] != a[i - 1] || a[i] != a[i + 4096] || a[i] != a[i - 4096]) {
                distance[i] = 0
                nearestPt[i] = simd_float2(xCoord, yCoord)
            }
            i &+= 1
        }
        // MARK: Foward Pass
        // Set i = 4096 so we can skip the first row of pixels and safely (no index exceptions) perform the lookups
        i = 4096
        while i < 16773120 {
            let xCoord = i % 4096
            if xCoord < 4095 && xCoord > 0 && (distance[i - 1 - 4096] + distanceDiag < distance[i]) {
                nearestPt[i] = nearestPt[i - 1 - 4096]
                distance[i] = simd_distance(coords[i], nearestPt[i])
            }
            if xCoord < 4095 && xCoord > 0 && (distance[i - 4096] + 1 < distance[i]) {
                nearestPt[i] = nearestPt[i - 4096]
                distance[i] = simd_distance(coords[i], nearestPt[i])
            }
            if xCoord < 4095 && xCoord > 0 && (distance[i + 1 - 4096] + distanceDiag < distance[i]) {
                nearestPt[i] = nearestPt[i + 1 - 4096]
                distance[i] = simd_distance(coords[i], nearestPt[i])
            }
            if xCoord < 4095 && xCoord > 0 && (distance[i - 1] + 1 < distance[i]) {
                nearestPt[i] = nearestPt[i - 1]
                distance[i] = simd_distance(coords[i], nearestPt[i])
            }
            i &+= 1
        }
        // MARK: Backward Pass
        i = 4096
        while i < 16773120 {
            let xCoord = i % 4096
            if xCoord < 4095 && xCoord > 0 && (distance[i + 1] + 1 < distance[i]) {
                nearestPt[i] = nearestPt[i + 1]
                distance[i] = simd_distance(coords[i], nearestPt[i])
            }
            if xCoord < 4095 && xCoord > 0 && (distance[i - 1 + 4096] + distanceDiag < distance[i]) {
                nearestPt[i] = nearestPt[i - 1 + 4096]
                distance[i] = simd_distance(coords[i], nearestPt[i])
            }
            if xCoord < 4095 && xCoord > 0 && (distance[i + 4096] + 1 < distance[i]) {
                nearestPt[i] = nearestPt[i + 4096]
                distance[i] = simd_distance(coords[i], nearestPt[i])
            }
            if xCoord < 4095 && xCoord > 0 && (distance[i + 1 + 4096] + distanceDiag < distance[i]) {
                nearestPt[i] = nearestPt[i + 1 + 4096]
                distance[i] = simd_distance(coords[i], nearestPt[i])
            }
            i &+= 1
        }
        // Set i back to 0 because we are safe here.
        i = 0
        while i < 16777216 {
            if !(a[i] < 0x7f) {
                distance[i] = distance[i] == 0 ? 0 : -distance[i]
            }
            i &+= 1
        }
        // Take sigmoid (kind of) to map everything to [0,1] then multipy by 255 to get pixelValues.
        var count = Int32(distance.count)
        vvexpf(&z, &distance, &count)
        let divisor = vDSP.add(1, z)
        let result = vDSP.divide(1, divisor)
        let scaledUp = vDSP.multiply(255, result)
        let pixelValues = vDSP.floatingPointToInteger(
            scaledUp,
            integerType: UInt8.self,
            rounding: .towardNearestInteger)
        // Kind of ugly but we deliberately use a buffer so we can access its array
        // and don't have to worry about deallocating anything (buffer dies when we leave scope [I think]).
        let destinationBuffer = vImage.PixelBuffer(
            size: .init(width: 2048, height: 2048),
            pixelFormat: vImage.Planar8.self)
        _ = destinationBuffer
            .withUnsafePointerToVImageBuffer { destinationPtr in
                vImage.PixelBuffer(
                    pixelValues: pixelValues,
                    size: .init(width: 4096, height: 4096),
                    pixelFormat: vImage.Planar8.self)
                
                .withUnsafePointerToVImageBuffer { sourcePtr in
                    vImageScale_Planar8(
                        sourcePtr,
                        destinationPtr,
                        nil,
                        vImage_Flags(kvImageHighQualityResampling))
                }
            }
        textureData = Data(destinationBuffer.array)
        // Just for debugging, don't actually want the image.
        guard let format = vImage_CGImageFormat(
            bitsPerComponent: 8, bitsPerPixel: 8,
            colorSpace: CGColorSpaceCreateDeviceGray(),
            bitmapInfo:.init(rawValue: CGImageAlphaInfo.none.rawValue))
        else {
            return nil
        }
        return destinationBuffer.makeCGImage(cgImageFormat: format)
    }
    
    private mutating func makeTextureData() {
        _ = makeAtlas(
            forFont: parentFont,
            width: Constants.size,
            height: Constants.size
        )
    }
}
