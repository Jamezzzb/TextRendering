import simd

struct Uniforms {
    let modelMatrix: matrix_float4x4
    let viewProjectionMatrix: matrix_float4x4
    let foregroundColor: vector_float4
}

struct Vertex {
    let position: simd_packed_float4
    let textCoords: simd_packed_float2
}

enum Math {
    static func matrix_translation(_ t: vector_float3) -> simd_float4x4 {
        let X = vector_float4( 1, 0, 0, 0)
        let Y = vector_float4(0, 1, 0, 0)
        let Z = vector_float4( 0, 0, 1, 0 )
        let W = vector_float4(t.x, t.y, t.z, 1)
        let mat = matrix_float4x4(X, Y, Z, W)
        return mat
    }
    
    static func matrix_scale(_ s: vector_float3) -> simd_float4x4 {
        let x = vector_float4( s.x, 0, 0, 0)
        let y = vector_float4(0, s.y, 0, 0)
        let z = vector_float4( 0, 0, s.z, 0)
        let w = vector_float4(0, 0, 0, 1)
        let mat = matrix_float4x4(x, y, z, w)
        return mat
    }
    
    static func matrix_orthographic_projection(
        _ left: Float,
        _ right: Float,
        _ top: Float, _ bottom: Float
    ) -> simd_float4x4 {
        
        let near = Float.zero
        let far = Float(1)

        let sx = 2 / (right - left)
        let sy = 2 / (top - bottom)
        let sz = 1 / (far - near)
        let tx = (right + left) / (left - right)
        let ty = (top + bottom) / (bottom - top)
        let tz = near / (far - near);

        let p = vector_float4(sx,  0,  0, 0)
        let q = vector_float4(0, sy,  0, 0)
        let r = vector_float4(0,  0, sz, 0)
        let s = vector_float4(tx, ty, tz,  1)

        return simd_float4x4(p,q,r,s)
    }
}
