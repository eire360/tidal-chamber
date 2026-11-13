import Foundation
import simd

struct Vertex {
    var position: SIMD4<Float>
    var normal: SIMD4<Float>
    var uvMaterial: SIMD4<Float>
}

struct ChamberMesh {
    var vertices: [Vertex] = []
    var indices: [UInt32] = []

    mutating func triangle(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ c: SIMD3<Float>, material: Float, uv: [SIMD2<Float>]? = nil) {
        let cross = simd_cross(b - a, c - a)
        guard simd_length_squared(cross) > 0.0000000001 else { return }
        let normal = simd_normalize(cross)
        let base = UInt32(vertices.count)
        for (i,p) in [a,b,c].enumerated() {
            let t = uv?[i] ?? SIMD2(p.x, p.z)
            vertices.append(Vertex(position: SIMD4(p,1), normal: SIMD4(normal,0), uvMaterial: SIMD4(t.x,t.y,material,0)))
        }
        indices += [base,base+1,base+2]
    }

    mutating func quad(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ c: SIMD3<Float>, _ d: SIMD3<Float>, material: Float) {
        triangle(a,b,c,material:material); triangle(a,c,d,material:material)
    }

    // Lathed solid surfaces: physical bevels, wall depth, and an open cistern.
    mutating func lathe(profile: [SIMD2<Float>], material: Float, segments: Int = 256, roughness: Float = 0) {
        func point(_ p: SIMD2<Float>, _ i: Int) -> SIMD3<Float> {
            let a = Float(i) / Float(segments) * 2 * .pi
            let irregular = roughness * (sin(a*13)*0.5 + sin(a*31+0.8)*0.3 + sin(a*47)*0.2)
            let x=(p.x+irregular)*sin(a), z=(p.x+irregular)*cos(a)
            let relief: Float = p.x > 2.7 ? (sin(x*4.3+sin(z*2))*sin(z*5.7)*0.025 + sin(x*15.2+z*12.3)*0.006) : 0
            return SIMD3(x,p.y+irregular*0.16+relief,z)
        }
        for j in 0..<(profile.count-1) {
            for i in 0..<segments {
                quad(point(profile[j],i),point(profile[j],i+1),point(profile[j+1],i+1),point(profile[j+1],i),material:material)
            }
        }
    }

    mutating func box(center: SIMD3<Float>, size: SIMD3<Float>, material: Float) {
        let l = center-size/2, h = center+size/2
        quad([l.x,h.y,l.z],[l.x,h.y,h.z],[h.x,h.y,h.z],[h.x,h.y,l.z],material:material)
        quad([l.x,l.y,h.z],[l.x,l.y,l.z],[h.x,l.y,l.z],[h.x,l.y,h.z],material:material)
        quad([l.x,l.y,l.z],[l.x,l.y,h.z],[l.x,h.y,h.z],[l.x,h.y,l.z],material:material)
        quad([h.x,l.y,h.z],[h.x,l.y,l.z],[h.x,h.y,l.z],[h.x,h.y,h.z],material:material)
        quad([l.x,l.y,h.z],[h.x,l.y,h.z],[h.x,h.y,h.z],[l.x,h.y,h.z],material:material)
        quad([h.x,l.y,l.z],[l.x,l.y,l.z],[l.x,h.y,l.z],[h.x,h.y,l.z],material:material)
    }

    // Coherent value noise: erosion has broad regions, not independent vertex jitter.
    static func noise(_ x: Float, _ z: Float) -> Float {
        func h(_ i: Float,_ j: Float)->Float {
            let f=sin(i*127.1+j*311.7)*43758.5453
            return f-floor(f)
        }
        let ix=floor(x), iz=floor(z), fx=x-ix, fz=z-iz
        let u=fx*fx*(3-2*fx), v=fz*fz*(3-2*fz)
        return (h(ix,iz)*(1-u)+h(ix+1,iz)*u)*(1-v)+(h(ix,iz+1)*(1-u)+h(ix+1,iz+1)*u)*v
    }

    static func stone() -> ChamberMesh {
        var m=ChamberMesh()
        let segments=256
        // The engraved inner band remains planar. Weathering grows outside it.
        let profile:[SIMD2<Float>]=[[2.12,-0.95],[2.12,-0.48],[2.12,-0.12],[2.16,0.015],[2.22,0.095],[2.48,0.095],[2.57,0.07],[2.66,0.015],[2.75,-0.08],[2.88,-0.17]]
        func rim(_ p:SIMD2<Float>,_ i:Int)->SIMD3<Float> {
            let a=Float(i)/Float(segments)*2 * .pi
            let outside=max(0,min(1,(p.x-2.48)/0.4))
            let shape=(noise(sin(a)*2.4+5,cos(a)*2.4+7)-0.5)*0.32+(noise(sin(a)*6.7,cos(a)*6.7)-0.5)*0.11
            let chip=pow(max(0,sin(a*19+0.5)),8)*0.045
            let r=p.x+(shape-chip)*outside
            let y=p.y+outside*((noise(sin(a)*3.5+1,cos(a)*3.5+9)-0.5)*0.10-chip)
            return [r*sin(a),y,r*cos(a)]
        }
        for j in 0..<(profile.count-1) {
            for i in 0..<segments {
                // Reverse the inner-to-outer profile to keep outward normals.
                m.quad(rim(profile[j+1],i),rim(profile[j+1],i+1),rim(profile[j],i+1),rim(profile[j],i),material:0)
            }
        }
        m.smoothNormals(from:0,to:m.vertices.count)
        // Compact terrain uses detail where it changes the relief; far terrain is coarse.
        let radial=42
        func terrain(_ j:Int,_ i:Int)->SIMD3<Float> {
            let a=Float(i)/Float(segments)*2 * .pi
            let t=Float(j)/Float(radial)
            let r=2.88+pow(t,1.65)*9.5
            let outer = min(1,t*14)
            let shape=(noise(sin(a)*2.4+5,cos(a)*2.4+7)-0.5)*0.32+(noise(sin(a)*6.7,cos(a)*6.7)-0.5)*0.11
            let chip=pow(max(0,sin(a*19+0.5)),8)*0.045
            let rr=r+(shape-chip)*exp(-max(0,r-3.1))
            let x=rr*sin(a),z=rr*cos(a)
            let n=noise(x*0.85+7,z*0.85+3), small=noise(x*3.1,z*3.1)
            let front=1/(1+exp(-(z-2.9)*7))
            let shoulder=(n-0.5)*0.36+(small-0.5)*0.065
            let layer=floor((z+sin(x*1.6)*0.14)*8)/8
            let eroded=shoulder-front*0.76+sin(layer*3)*0.045
            let edge=rim(profile.last!,i)
            let y=edge.y*(1-outer)+(-0.18+eroded)*outer
            return [x,y,z]
        }
        let terrainStart=m.vertices.count
        for j in 0..<radial { for i in 0..<segments {
            m.quad(terrain(j+1,i),terrain(j+1,i+1),terrain(j,i+1),terrain(j,i),material:0)
        }}
        m.smoothNormals(from:terrainStart,to:m.vertices.count)
        // Underwater bed is a real concave solid, not a single infinitely deep plane.
        m.lathe(profile:[[2.12,-0.95],[1.5,-1.06],[0.7,-1.16],[0,-1.22]],material:0,segments:128)
        m.erodedBlock(center:[-2.9,-0.15,2.35],scale:[1.08,0.58,1.25],seed:2)
        m.erodedBlock(center:[-3.22,-0.20,-2.65],scale:[1.05,0.28,1.95],seed:7)
        m.erodedBlock(center:[3.4,-0.28,-3.5],scale:[1.24,0.35,1.95],seed:11)
        return m
    }

    mutating func erodedBlock(center:SIMD3<Float>,scale:SIMD3<Float>,seed:Float) {
        let start=vertices.count
        let count=72, layers=12
        func point(_ layer:Int,_ i:Int)->SIMD3<Float> {
            let a=Float(i)/Float(count)*2 * .pi
            let t=Float(layer)/Float(layers)
            let c=cos(a),s=sin(a)
            let x=copysign(pow(abs(c),0.64),c), z=copysign(pow(abs(s),0.64),s)
            let fracture=0.05*sin(a*7+seed)+0.025*sin(a*17-seed)
            let strata=0.018*sin(Float(layer)*2.4+seed)+0.012*cos(Float(layer)*4.8+a*3)
            let taper=1-pow(t,4)*0.1+fracture+strata
            return center+SIMD3(x*scale.x*taper,t*scale.y+(Self.noise(x*3+seed,z*3+seed)-0.5)*0.09,z*scale.z*taper)
        }
        for j in 0..<layers { for i in 0..<count {
            quad(point(j,i),point(j,i+1),point(j+1,i+1),point(j+1,i),material:0)
        }}
        let middle=center+SIMD3<Float>(0,scale.y*0.96,0)
        for i in 0..<count { triangle(middle,point(layers,i+1),point(layers,i),material:0) }
        smoothNormals(from:start,to:vertices.count)
    }

    mutating func smoothNormals(from start:Int,to end:Int) {
        struct Key:Hashable { let x:Int;let y:Int;let z:Int }
        func key(_ p:SIMD4<Float>)->Key { Key(x:Int((p.x*10000).rounded()),y:Int((p.y*10000).rounded()),z:Int((p.z*10000).rounded())) }
        var sums:[Key:SIMD3<Float>]=[:]
        for i in start..<end { let n=vertices[i].normal; sums[key(vertices[i].position),default:.zero]+=SIMD3(n.x,n.y,n.z) }
        for i in start..<end {
            if let total=sums[key(vertices[i].position)],simd_length_squared(total)>0.0001 { vertices[i].normal=SIMD4(simd_normalize(total),0) }
        }
    }

    static func water() -> ChamberMesh {
        var m = ChamberMesh()
        let rings=80, segments=192
        // Radial mesh is displaced in the vertex shader; its normal is analytic.
        for j in 0..<rings {
            let r0 = Float(j)/Float(rings)*2.115, r1 = Float(j+1)/Float(rings)*2.115
            for i in 0..<segments {
                let a=Float(i)/Float(segments)*2 * .pi, b=Float(i+1)/Float(segments)*2 * .pi
                m.quad([r1*sin(a),-0.34,r1*cos(a)],[r1*sin(b),-0.34,r1*cos(b)],[r0*sin(b),-0.34,r0*cos(b)],[r0*sin(a),-0.34,r0*cos(a)],material:3)
            }
        }
        return m
    }

    static func dial() -> ChamberMesh {
        var m=ChamberMesh()
        for i in 0..<60 {
            if i % 15 == 0 { continue }
            let a=Float(i)/60 * 2 * .pi
            let len: Float = i % 5 == 0 ? 0.13 : 0.045
            let width: Float = i % 5 == 0 ? 0.025 : 0.012
            let r: Float=2.345
            var tick=ChamberMesh()
            tick.box(center:[0,0.101,-r],size:[width,0.008,len],material:4)
            let rot=rotationY(-a)
            for v in tick.vertices {
                var q=v; q.position=rot*v.position; q.normal=rot*v.normal
                m.vertices.append(q)
            }
            let base=UInt32(m.vertices.count-tick.vertices.count)
            m.indices += tick.indices.map{$0+base}
        }
        // Four real glyph planes, rasterized locally with CoreText into a small atlas.
        for (index,p) in [SIMD2<Float>(0,-2.35),SIMD2<Float>(2.35,0),SIMD2<Float>(0,2.35),SIMD2<Float>(-2.35,0)].enumerated() {
            let w: Float = index == 0 ? 0.29 : 0.20, h: Float=0.30, y: Float=0.106
            let a=SIMD3(p.x-w/2,y,p.y-h/2), b=SIMD3(p.x-w/2,y,p.y+h/2)
            let c=SIMD3(p.x+w/2,y,p.y+h/2), d=SIMD3(p.x+w/2,y,p.y-h/2)
            let u0=Float(index)/4, u1=Float(index+1)/4
            m.triangle(a,b,c,material:5,uv:[[u0,0],[u0,1],[u1,1]])
            m.triangle(a,c,d,material:5,uv:[[u0,0],[u1,1],[u1,0]])
        }
        return m
    }

    static func hand(length: Float, width: Float, material: Float, height: Float) -> ChamberMesh {
        var m=ChamberMesh()
        let p:[SIMD2<Float>] = [[-width*0.42,0.22],[-width/2,-0.15],[-width*0.3,-length*0.83],[0,-length],[width*0.3,-length*0.83],[width/2,-0.15],[width*0.42,0.22]]
        for i in 0..<p.count {
            let j=(i+1)%p.count, a=p[i], b=p[j]
            m.triangle([0,height,0],[b.x,height,b.y],[a.x,height,a.y],material:material)
            m.quad([a.x,height-0.035,a.y],[b.x,height-0.035,b.y],[b.x,height,b.y],[a.x,height,a.y],material:material)
        }
        return m
    }

    static func hub() -> ChamberMesh {
        var m=ChamberMesh()
        m.lathe(profile:[[0,0.07],[0.105,0.07],[0.13,0.09],[0.13,0.235],[0.105,0.255],[0,0.255]],material:1,segments:96)
        return m
    }

    func obj() -> String {
        var s="# Tidal Chamber — original procedural geometry\n"
        for v in vertices { s += "v \(v.position.x) \(v.position.y) \(v.position.z)\n" }
        for v in vertices { s += "vn \(v.normal.x) \(v.normal.y) \(v.normal.z)\n" }
        for i in stride(from:0,to:indices.count,by:3) { let a=indices[i]+1,b=indices[i+1]+1,c=indices[i+2]+1; s += "f \(a)//\(a) \(b)//\(b) \(c)//\(c)\n" }
        return s
    }
}

func rotationY(_ a: Float) -> simd_float4x4 {
    simd_float4x4(columns: (SIMD4(cos(a),0,-sin(a),0),SIMD4(0,1,0,0),SIMD4(sin(a),0,cos(a),0),SIMD4(0,0,0,1)))
}

func lookAt(_ eye: SIMD3<Float>, _ target: SIMD3<Float>) -> simd_float4x4 {
    let z=simd_normalize(eye-target), x=simd_normalize(simd_cross(SIMD3<Float>(0,1,0),z)), y=simd_cross(z,x)
    return simd_float4x4(rows:[SIMD4(x,-simd_dot(x,eye)),SIMD4(y,-simd_dot(y,eye)),SIMD4(z,-simd_dot(z,eye)),SIMD4(0,0,0,1)])
}

func ortho(width: Float, height: Float, near: Float, far: Float) -> simd_float4x4 {
    simd_float4x4(columns:(SIMD4(2/width,0,0,0),SIMD4(0,2/height,0,0),SIMD4(0,0,1/(near-far),0),SIMD4(0,0,near/(near-far),1)))
}

func perspective(verticalFOV:Float,aspect:Float,near:Float,far:Float)->simd_float4x4 {
    let y=1/tan(verticalFOV/2),x=y/aspect,z=far/(near-far)
    return simd_float4x4(columns:(SIMD4(x,0,0,0),SIMD4(0,y,0,0),SIMD4(0,0,z,-1),SIMD4(0,0,z*near,0)))
}
