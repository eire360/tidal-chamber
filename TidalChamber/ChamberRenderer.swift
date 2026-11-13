import Foundation
import MetalKit
import CoreText
import simd

struct Uniforms {
    var viewProjection: simd_float4x4
    var model: simd_float4x4
    var lightProjection: simd_float4x4
    var cameraTime: SIMD4<Float>
    var lightDay: SIMD4<Float>
    var viewportMotion: SIMD4<Float>
    var renderOptions: SIMD4<Float>
}

final class ChamberRenderer: NSObject, MTKViewDelegate {
    struct Model {
        let vertices: MTLBuffer
        let indices: MTLBuffer
        let count: Int
        let kind: Int
    }
    let device: MTLDevice
    let queue: MTLCommandQueue
    let pipeline: MTLRenderPipelineState
    let shadowPipeline: MTLRenderPipelineState
    let depthState: MTLDepthStencilState
    let shadowTexture: MTLTexture
    let glyphTexture: MTLTexture
    var models: [Model] = []
    var reduceMotion = false
    var increaseContrast = false
    var accessibleLayout = false
    var fixture: Date?
    private var animationTime: Float = 0
    private var lastFrame: CFTimeInterval?
    private(set) var frameCount = 0
    private(set) var lastGPUTime: Double = 0
    private var metricsStart: CFTimeInterval?
    private var gpuSamples: [Double] = []

    init(view: MTKView) throws {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else { throw RenderError.unavailable }
        self.device=device; self.queue=queue
        view.device=device; view.colorPixelFormat = .bgra8Unorm_srgb; view.depthStencilPixelFormat = .depth32Float
        view.sampleCount=4; view.clearColor=MTLClearColor(red:0.07,green:0.11,blue:0.13,alpha:1)
        let library: MTLLibrary
        if let bundled=device.makeDefaultLibrary() { library=bundled }
        else {
            guard let url=Bundle.main.url(forResource:"Chamber",withExtension:"metal") else { throw RenderError.shaderMissing }
            library=try device.makeLibrary(source:String(contentsOf:url,encoding:.utf8),options:nil)
        }
        let descriptor=MTLRenderPipelineDescriptor()
        descriptor.vertexFunction=library.makeFunction(name:"chamberVertex")
        descriptor.fragmentFunction=library.makeFunction(name:"chamberFragment")
        descriptor.colorAttachments[0].pixelFormat=view.colorPixelFormat
        descriptor.depthAttachmentPixelFormat = .depth32Float; descriptor.rasterSampleCount=4
        pipeline=try device.makeRenderPipelineState(descriptor:descriptor)
        let sd=MTLRenderPipelineDescriptor()
        sd.vertexFunction=library.makeFunction(name:"shadowVertex"); sd.depthAttachmentPixelFormat = .depth32Float
        shadowPipeline=try device.makeRenderPipelineState(descriptor:sd)
        let dd=MTLDepthStencilDescriptor(); dd.depthCompareFunction = .less; dd.isDepthWriteEnabled=true
        guard let depth=device.makeDepthStencilState(descriptor:dd) else { throw RenderError.unavailable }
        depthState=depth
        let td=MTLTextureDescriptor.texture2DDescriptor(pixelFormat:.depth32Float,width:1536,height:1536,mipmapped:false)
        td.usage=[.renderTarget,.shaderRead]; td.storageMode = .private
        guard let st=device.makeTexture(descriptor:td) else { throw RenderError.unavailable }; shadowTexture=st
        glyphTexture=try Self.makeGlyphTexture(device)
        super.init()
        for (kind,mesh) in [(0,ChamberMesh.stone()),(1,ChamberMesh.dial()),(2,ChamberMesh.hand(length:1.17,width:0.14,material:2,height:0.14)),(3,ChamberMesh.hand(length:1.88,width:0.068,material:1,height:0.20)),(4,ChamberMesh.hub()),(5,ChamberMesh.water())] {
            guard let vb=device.makeBuffer(bytes:mesh.vertices,length:MemoryLayout<Vertex>.stride*mesh.vertices.count),let ib=device.makeBuffer(bytes:mesh.indices,length:MemoryLayout<UInt32>.stride*mesh.indices.count) else { throw RenderError.unavailable }
            models.append(Model(vertices:vb,indices:ib,count:mesh.indices.count,kind:kind))
        }
        view.delegate=self; view.preferredFramesPerSecond=30
    }

    func resetFrameClock() { lastFrame=nil }
    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        guard let drawable=view.currentDrawable,let pass=view.currentRenderPassDescriptor,let command=queue.makeCommandBuffer() else { return }
        let now=CACurrentMediaTime()
        if metricsStart == nil { metricsStart=now }
        if let lastFrame, !reduceMotion { animationTime += Float(min(now-lastFrame,0.1)) }
        lastFrame=now
        let date=fixture ?? Date()
        let angle=ClockState.angles(at:date), dayPhase=ClockState.dayPhase(at:date)
        let daylight=max(0,sin((dayPhase-0.25)*2 * .pi))
        let light=simd_normalize(SIMD3<Float>(0.60+0.12*sin(dayPhase*2 * .pi),0.90,-0.46))
        let target=SIMD3<Float>(0,0,accessibleLayout ? 1.7 : 0.62)
        let eye=target+(accessibleLayout ? SIMD3<Float>(0,9,5.3) : SIMD3<Float>(0,12,4.2))
        let aspect=Float(view.drawableSize.width/max(view.drawableSize.height,1))
        let width: Float=accessibleLayout ? 8.2 : 5.15
        let distance=simd_length(eye-target)
        let projection=accessibleLayout ? ortho(width:width,height:width/aspect,near:0.1,far:40) : perspective(verticalFOV:2*atan(width/aspect/2/distance),aspect:aspect,near:0.1,far:40)
        let vp=projection*lookAt(eye,target)
        let lp=ortho(width:11,height:11,near:0.1,far:30)*lookAt(light*14,[0,0,0])
        let sec=Float(Calendar.autoupdatingCurrent.component(.second,from:date))
        var u=Uniforms(viewProjection:vp,model:matrix_identity_float4x4,lightProjection:lp,cameraTime:SIMD4(eye,reduceMotion ? 0 : animationTime),lightDay:SIMD4(light,daylight),viewportMotion:SIMD4(Float(view.drawableSize.width),Float(view.drawableSize.height),reduceMotion ? 0 : 1,sec),renderOptions:SIMD4(increaseContrast ? 1 : 0,0,0,0))
        let sp=MTLRenderPassDescriptor()
        sp.depthAttachment.texture=shadowTexture; sp.depthAttachment.loadAction = .clear; sp.depthAttachment.storeAction = .store; sp.depthAttachment.clearDepth=1
        if let enc=command.makeRenderCommandEncoder(descriptor:sp) {
            enc.setRenderPipelineState(shadowPipeline); enc.setDepthStencilState(depthState)
            enc.setDepthBias(0.0006,slopeScale:1.2,clamp:0.004)
            for model in models where model.kind != 5 && model.kind != 1 {
                u.model=transform(model.kind,hour:angle.hour,minute:angle.minute)
                bind(model,to:enc,uniforms:&u); enc.drawIndexedPrimitives(type:.triangle,indexCount:model.count,indexType:.uint32,indexBuffer:model.indices,indexBufferOffset:0)
            }
            enc.endEncoding()
        }
        if let enc=command.makeRenderCommandEncoder(descriptor:pass) {
            enc.setRenderPipelineState(pipeline); enc.setDepthStencilState(depthState)
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("-wireframe") { enc.setTriangleFillMode(.lines) }
            #endif
            enc.setFragmentTexture(shadowTexture,index:0); enc.setFragmentTexture(glyphTexture,index:1)
            for model in models {
                u.model=transform(model.kind,hour:angle.hour,minute:angle.minute)
                bind(model,to:enc,uniforms:&u)
                enc.setFragmentBytes(&u,length:MemoryLayout<Uniforms>.stride,index:1)
                enc.drawIndexedPrimitives(type:.triangle,indexCount:model.count,indexType:.uint32,indexBuffer:model.indices,indexBufferOffset:0)
            }
            enc.endEncoding()
        }
        frameCount+=1
        command.addCompletedHandler { [weak self] buffer in
            let gpuTime=max(0,buffer.gpuEndTime-buffer.gpuStartTime)*1000
            DispatchQueue.main.async {
                guard let self else { return }
                self.lastGPUTime=gpuTime
                #if DEBUG
                self.gpuSamples.append(gpuTime)
                if self.gpuSamples.count > 120 { self.gpuSamples.removeFirst(self.gpuSamples.count-120) }
                if self.frameCount % 60 == 0 {
                    let samples=self.gpuSamples.suffix(120)
                    let metrics:[String:Any] = ["frames":self.frameCount,"elapsedSeconds":CACurrentMediaTime()-(self.metricsStart ?? now),"meanGPUms":samples.reduce(0,+)/Double(max(samples.count,1)),"reduceMotion":self.reduceMotion,"liveTime":self.fixture == nil,"renderDate":(self.fixture ?? Date()).description]
                    if let data=try? JSONSerialization.data(withJSONObject:metrics,options:.prettyPrinted), let directory=FileManager.default.urls(for:.documentDirectory,in:.userDomainMask).first { try? data.write(to:directory.appendingPathComponent("render-metrics.json")) }
                }
                #endif
            }
            if buffer.status == .error { print("Metal render error: \(String(describing:buffer.error))") }
        }
        command.present(drawable); command.commit()
    }

    private func transform(_ kind:Int,hour:Float,minute:Float)->simd_float4x4 {
        kind==2 ? rotationY(-hour) : kind==3 ? rotationY(-minute) : matrix_identity_float4x4
    }
    private func bind(_ model:Model,to enc:MTLRenderCommandEncoder,uniforms:inout Uniforms) {
        enc.setVertexBuffer(model.vertices,offset:0,index:0); enc.setVertexBytes(&uniforms,length:MemoryLayout<Uniforms>.stride,index:1)
    }
    enum RenderError: Error { case unavailable, shaderMissing, textureFailed }
    private static func makeGlyphTexture(_ device:MTLDevice)throws->MTLTexture {
        let width=512,height=128
        var data=[UInt8](repeating:0,count:width*height*4)
        guard let context=CGContext(data:&data,width:width,height:height,bitsPerComponent:8,bytesPerRow:width*4,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue) else { throw RenderError.textureFailed }
        let font=CTFontCreateWithName("Baskerville" as CFString,98,nil)
        for (i,text) in ["12","3","6","9"].enumerated() {
            let attrs:[NSAttributedString.Key:Any]=[NSAttributedString.Key(kCTFontAttributeName as String):font,NSAttributedString.Key(kCTForegroundColorAttributeName as String):CGColor(gray:1,alpha:1)]
            let line=CTLineCreateWithAttributedString(NSAttributedString(string:text,attributes:attrs))
            let bounds=CTLineGetBoundsWithOptions(line,.useGlyphPathBounds)
            context.textPosition=CGPoint(x:CGFloat(i*128)+64-bounds.midX,y:64-bounds.midY)
            CTLineDraw(line,context)
        }
        let desc=MTLTextureDescriptor.texture2DDescriptor(pixelFormat:.rgba8Unorm,width:width,height:height,mipmapped:false)
        desc.usage = .shaderRead
        guard let texture=device.makeTexture(descriptor:desc) else { throw RenderError.textureFailed }
        texture.replace(region:MTLRegionMake2D(0,0,width,height),mipmapLevel:0,withBytes:data,bytesPerRow:width*4)
        return texture
    }
}
