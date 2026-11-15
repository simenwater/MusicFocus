#if DEBUG || MUSICFOCUS_HOMR
import Foundation
import CoreGraphics

/// Read beam bands near a candidate stem on the full-resolution scan. Used as
/// corroboration by the timing validator, never as a global duration rewrite.
struct ScoreRecognitionBeamEvidence {
    let raster: ScoreRecognitionRaster
    func count(at point: CGPoint, unit u: Double) -> Int? {
        let w=raster.width,h=raster.height
        func ink(_ x:Int,_ y:Int)->Bool {x>=0 && x<w && y>=0 && y<h && raster.pixels[y*w+x]<180}
        func runs(_ values:[Bool])->[(Int,Int)] {
            var output:[(Int,Int)]=[],start:Int?
            for i in 0...values.count {
                if i<values.count && values[i] {if start==nil {start=i}}
                else if let s=start {output.append((s,i));start=nil}
            }
            return output
        }
        struct Reading {let beams:Int;let distance:Double}
        var found:[Reading]=[]
        let lo=max(0,Int((point.y-6*u).rounded())),hi=min(h,Int((point.y+6*u).rounded()))
        guard hi>lo else{return nil}
        for x in Int((point.x-u*1.4).rounded())...Int((point.x+u*1.4).rounded()) where x>5 && x<w-5 {
            var vertical=(lo..<hi).map {ink(x,$0)}
            for (a,b) in runs(vertical.map{!$0}) where a>0 && b<vertical.count && Double(b-a)<=u*0.5 {
                for i in a..<b {vertical[i]=true}
            }
            for (aa,bb) in runs(vertical) where Double(bb-aa)>=2.5*u {
                let a=Double(aa+lo),b=Double(bb+lo)
                for (direction,end,head) in [(-1.0,a,b),(1.0,b,a)] {
                    guard abs(point.y-head)<=2*u,direction*(end-point.y)>=2.1*u else{continue}
                    for side in [-1.0,1.0] {
                        let counts=[0.3,0.45,0.6].map { dx -> Int in
                            let xx=Int((Double(x)+side*u*dx).rounded())
                            let profile=stride(from:0.0,to:min(3*u,abs(end-point.y)),by:1.0).map { ink(xx,Int((end+direction*1.1*u-direction*$0).rounded())) }
                            return runs(profile).filter{Double($0.1-$0.0)>=u*0.29 && Double($0.1-$0.0)<=u*0.9}.count
                        }
                        if counts.min()==counts.max(),(1...3).contains(counts[0]) {
                            found.append(.init(beams:counts[0],distance:abs(Double(x)-point.x)+abs(point.y-head)*0.15))
                        }
                    }
                }
            }
        }
        guard let closest=found.map(\.distance).min() else{return nil}
        return found.filter{$0.distance<closest+u*0.4}.map(\.beams).max()
    }
}
#endif
