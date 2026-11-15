#if DEBUG || MUSICFOCUS_HOMR
import Foundation
import CoreGraphics

enum ScoreRecognitionTupletEvidence {
    struct Bracket: Codable {var staff:Int;var left:Double;var right:Double;var x:Double;var y:Double;var unit:Double;var direction:Int}
    static func brackets(raster:ScoreRecognitionRaster,region:ScoreRecognitionRegion)throws->[Bracket] {
        var found:[Bracket]=[]
        let lo=max(0,Int(region.rect.minX)),hi=min(raster.width-1,Int(region.rect.maxX))
        guard hi>lo else{return []}
        for (index,staff) in region.staffs.enumerated() {
            let u=staff.unit
            let meanX=staff.samples.map(\.x).reduce(0,+)/Double(staff.samples.count)
            let meanY=staff.center
            let variance=staff.samples.reduce(0.0){$0+pow($1.x-meanX,2)}
            let slope=variance>0 ? staff.samples.reduce(0.0){$0+($1.x-meanX)*($1.y-meanY)}/variance:0
            // Brackets are straight even where segmentation wobbles around
            // dense beams. Do not bend the rule to those local mask errors.
            func baseline(_ x:Double)->Double {meanY+slope*(x-meanX)}
            let base=(lo...hi).map{baseline(Double($0))}
            for direction in [-1,1] {
                for distance in stride(from:2.5*u,through:10*u,by:1) {
                    try Task.checkCancellation()
                    let offset=distance*Double(direction)
                    func ink(_ x:Int,_ y:Int)->Bool {x>=0 && x<raster.width && y>=0 && y<raster.height && raster.pixels[y*raster.width+x]<210}
                    var values=(lo...hi).map {x in (-2...2).contains{ink(x,Int((base[x-lo]+offset).rounded())+$0)}}
                    for i in 1..<(values.count-1) where values[i-1] && values[i+1] {values[i]=true}
                    var segments:[(Int,Int)]=[],start:Int?
                    for i in 0...values.count {
                        if i<values.count && values[i] {if start==nil {start=i}}
                        else if let a=start {if Double(i-a)>3.5*u && Double(i-a)<20*u {segments.append((a+lo,i+lo))};start=nil}
                    }
                    for (a,b) in zip(segments,segments.dropFirst()) {
                        let gap=Double(b.0-a.1),ratio=Double(a.1-a.0)/Double(b.1-b.0)
                        guard gap>0.4*u,gap<3*u,ratio>0.4,ratio<2.5 else{continue}
                        let x=Double(a.1+b.0)/2,y=baseline(x)+offset
                        if found.contains(where:{$0.staff==index && abs($0.x-x)<u && abs($0.y-y)<u}) {continue}
                        func hook(_ x:Int)->Double {
                            let y=baseline(Double(x))+offset,steps=Array(stride(from:3.0,to:u*0.8,by:1.0))
                            return Double(steps.filter {dy in (-3...3).contains {ink(x+$0,Int((y-Double(direction)*dy).rounded()))}}.count)/Double(max(1,steps.count))
                        }
                        guard max(hook(a.0),hook(b.1-1))>=0.6,
                              ScoreRecognitionPrintedDigits.read(raster:raster,center:CGPoint(x:x,y:y),unit:u)?.digit==2 else{continue}
                        found.append(.init(staff:index,left:Double(a.0),right:Double(b.1),x:x,y:y,unit:u,direction:direction))
                    }
                }
            }
        }
        return found
    }
    static func hasInnerTriplet(_ b:Bracket,first:Double,third:Double,raster:ScoreRecognitionRaster)->Bool {
        let x=(first+third)/2 + (b.direction<0 ? b.unit*0.5 : 0)
        let y=b.y-Double(b.direction)*b.unit*1.3
        for dy in [0.0,-0.3,0.3,-0.6,0.6] {for dx in [0.0,-0.3,0.3,-0.6,0.6,-0.9,0.9,-1.2,1.2,-1.5,1.5] {
            if ScoreRecognitionPrintedDigits.read(raster:raster,center:CGPoint(x:x+dx*b.unit,y:y+dy*b.unit),unit:b.unit)?.digit==3 {return true}
        }}
        return false
    }
}
#endif
