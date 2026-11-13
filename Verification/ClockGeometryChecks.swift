import Foundation
import simd

@main struct Checks {
 static func main() throws {
  var cal=Calendar(identifier:.gregorian); cal.timeZone=TimeZone(secondsFromGMT:0)!
  let date=cal.date(from:DateComponents(year:2026,month:10,day:27,hour:10,minute:8,second:30))!
  let a=ClockState.angles(at:date,calendar:cal)
  precondition(abs(a.minute-Float(8.5/60*2 * Double.pi))<0.00001)
  precondition(abs(a.hour-Float((10+8.5/60)/12*2 * Double.pi))<0.00001)
  let midnight=cal.date(from:DateComponents(year:2026,month:10,day:28,hour:0,minute:0,second:0))!
  let b=ClockState.angles(at:midnight,calendar:cal)
  precondition(b.hour==0 && b.minute==0)
  var shifted=cal; shifted.timeZone=TimeZone(secondsFromGMT:3600*9)!
  let c=ClockState.angles(at:date,calendar:shifted)
  precondition(abs(c.hour-a.hour)>1)
  precondition(abs(c.minute-a.minute)<0.00001)
  let meshes:[(String,ChamberMesh)]=[("limestone-cistern",.stone()),("water-surface",.water()),("dial",.dial()),("hour-hand",.hand(length:1.17,width:0.14,material:2,height:0.14)),("minute-hand",.hand(length:1.88,width:0.068,material:1,height:0.20)),("hub",.hub())]
  let out=URL(fileURLWithPath:CommandLine.arguments[1],isDirectory:true)
  for (name,mesh) in meshes {
   precondition(mesh.indices.allSatisfy{Int($0)<mesh.vertices.count})
   precondition(mesh.vertices.allSatisfy{$0.position.x.isFinite && $0.position.y.isFinite && $0.position.z.isFinite})
   precondition(mesh.vertices.allSatisfy{$0.normal.x.isFinite && $0.normal.y.isFinite && $0.normal.z.isFinite})
   try mesh.obj().write(to:out.appendingPathComponent(name+".obj"),atomically:true,encoding:.utf8)
   print("\(name): \(mesh.vertices.count) vertices, \(mesh.indices.count/3) triangles")
  }
  print("PASS: wall-clock angles, midnight rollover, timezone resampling, geometry index bounds and finite coordinates; OBJ models exported.")
 }
}
