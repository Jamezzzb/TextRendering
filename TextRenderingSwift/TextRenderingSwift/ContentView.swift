import SwiftUI
import MetalKit

struct ContentView: View {
    var body: some View {
        MTLTextView()
    }
}

#Preview {
    ContentView()
}


struct MTLTextView: NSViewRepresentable {
    func makeCoordinator() -> Renderer {
        Renderer(self)
    }
    
    func makeNSView(context: Context) -> MTKView {
        let mtkView = MTKView()
        mtkView.delegate = context.coordinator
        mtkView.enableSetNeedsDisplay = true
        
        if let device = MTLCreateSystemDefaultDevice() {
            mtkView.device = device
        }
        
        mtkView.framebufferOnly = false
        mtkView.isPaused = false
        mtkView.depthStencilPixelFormat = .depth32Float
        
        return mtkView
    }
    
    func updateNSView(_ nsView: MTKView, context: Context) {
        if nsView.frame.size.height < 10 {
            nsView.isPaused = true
        }
    }
}
