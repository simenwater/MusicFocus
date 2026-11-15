#if DEBUG || MUSICFOCUS_HOMR
import Foundation
import CoreGraphics

/// Reuses HOMR's existing clef/key segmentation. Only an independently visible
/// bass clef at a bar boundary may repair a missed G2 -> F4 transition. The two
/// dots, staff position, and decoded pitch/geometry must agree; ambiguous cases
/// and already-correct absolute pitches remain unchanged.
struct ScoreRecognitionClefs {
    struct Component { var rect: CGRect; var area: Int }
    struct Result { var symbols: [ScoreRecognitionSymbol]; var recovered: Int; var changedNotes: Int }
    let raster: ScoreRecognitionRaster
    let candidates: [Component]

    init(raster: ScoreRecognitionRaster, mask: [UInt8]) {
        self.raster = raster
        candidates = Self.components(mask, width:raster.width, height:raster.height).filter{$0.area>=20}
    }

    static func components(_ ink: [UInt8], width: Int, height: Int) -> [Component] {
        guard width>0, height>0, ink.count==width*height else { return [] }
        var visited=[UInt8](repeating:0,count:ink.count), result:[Component]=[]
        for seed in ink.indices where ink[seed]>0 && visited[seed]==0 {
            var queue=[seed], head=0, x0=seed%width, x1=x0, y0=seed/width, y1=y0
            visited[seed]=1
            while head<queue.count {
                let index=queue[head],x=index%width,y=index/width; head+=1
                x0=min(x0,x);x1=max(x1,x);y0=min(y0,y);y1=max(y1,y)
                for dy in -1...1 { for dx in -1...1 where dx != 0 || dy != 0 {
                    let xx=x+dx,yy=y+dy
                    guard (0..<width).contains(xx),(0..<height).contains(yy) else { continue }
                    let next=yy*width+xx
                    if ink[next]>0 && visited[next]==0 {visited[next]=1;queue.append(next)}
                }}
            }
            result.append(.init(rect:CGRect(x:x0,y:y0,width:x1-x0+1,height:y1-y0+1),area:queue.count))
        }
        return result
    }

    func hasBassDots(_ box: CGRect, staff: ScoreRecognitionStaff) -> Bool {
        let u=staff.unit, fLine=staff.y(at:box.midX)-u
        let x0=max(0,Int(box.minX+box.width*0.65)),x1=min(raster.width,Int(box.maxX+u))
        let y0=max(0,Int(fLine-u)),y1=min(raster.height,Int(fLine+u))
        guard x1>x0,y1>y0 else{return false}
        let w=x1-x0,h=y1-y0,thickness=max(1,Int(u*0.15))
        var ink=[UInt8](repeating:0,count:w*h)
        for x in x0..<x1 {for y in y0..<y1 {
            guard raster.pixels[y*raster.width+x]<130 else{continue}
            let cy=staff.y(at:Double(x))
            if (-2...2).contains(where:{abs(Double(y)-(cy+Double($0)*u))<=Double(thickness)}) {continue}
            ink[(y-y0)*w+x-x0]=1
        }}
        let dots=Self.components(ink,width:w,height:h).filter {
            let r=$0.rect
            return $0.area>=3 && r.width>=u*0.1 && r.width<=u*0.65 && r.height>=u*0.1 && r.height<=u*0.65
                && r.width/r.height>=0.45 && r.width/r.height<=2.2
                && r.minX>0 && r.maxX<Double(w) // clipped barlines are not dots
        }.map{Component(rect:$0.rect.offsetBy(dx:Double(x0),dy:Double(y0)),area:$0.area)}
        for a in dots {for b in dots where b.rect.midY>a.rect.midY {
            let dy=b.rect.midY-a.rect.midY,ratio=Double(a.area)/Double(b.area)
            if abs(a.rect.midX-b.rect.midX)<u*0.25 && dy>u*0.5 && dy<u*1.4
                && abs((a.rect.midY+b.rect.midY)/2-fLine)<u*0.35 && (0.5...2).contains(ratio)
                && a.rect.midX>box.minX+box.width*0.8 {return true}
        }}
        return false
    }

    static func diatonic(_ pitch: String) -> Int? {
        guard let letter=pitch.first, let octave=Int(pitch.dropFirst()), let step=Array("CDEFGAB").firstIndex(of:letter) else {return nil}
        return octave*7+step
    }
    static func bassPitch(fromTreble pitch: String) -> String? {
        guard let old=diatonic(pitch), old>=12 else{return nil}
        let value=old-12
        return String(Array("CDEFGAB")[value%7])+String(value/7)
    }

    func repair(_ symbols: [ScoreRecognitionSymbol], region: ScoreRecognitionRegion) -> Result {
        var result=symbols,recovered=0,changed=0
        for (staffIndex,staff) in region.staffs.enumerated() {
            let u=staff.unit
            func sameStaff(_ s: ScoreRecognitionSymbol) -> Bool {(s.position.hasPrefix("lower") ? 1:0)==staffIndex}
            let possible=candidates.filter { c in
                let r=c.rect,f=staff.y(at:r.midX)-u,ratio=r.width/r.height
                return r.minX>region.rect.minX+u*5 && r.maxX<region.rect.maxX && (0.45...1.2).contains(ratio)
                    && r.height>u*1.7 && r.height<u*4 && abs(r.minY-(f-u))<u*0.65 && abs(r.maxY-(f+2*u))<u*0.8
            }.sorted{$0.rect.minX<$1.rect.minX}
            for candidate in possible {
                let box=candidate.rect
                guard hasBassDots(box,staff:staff) else{continue}
                let localX=(box.midX-region.rect.minX)*region.scale
                guard let boundary=result.indices.first(where:{ i in
                    let s=result[i],x=region.sourcePoint(s.point).x
                    return (s.rhythm.contains("barline") || s.rhythm.hasPrefix("repeat")) && x>=box.minX-u*0.3 && x<=box.maxX+u*4
                }),let previous=result[..<boundary].last(where:{sameStaff($0) && $0.rhythm.hasPrefix("clef_")}), previous.rhythm=="clef_G2" else {continue}
                let end=result.indices.first(where:{$0>boundary && sameStaff(result[$0]) && result[$0].rhythm.hasPrefix("clef_")}) ?? result.count
                let notes=(boundary..<end).filter{sameStaff(result[$0]) && result[$0].midi != nil}
                guard notes.count>=3 else{continue}
                // Do not shift an implicit change that the decoder already got
                // right. Attention is approximate, so require a large margin
                // between the old-clef and new-clef interpretations.
                var oldErrors:[Double]=[],newErrors:[Double]=[]
                for i in notes.prefix(6) {
                    let s=result[i],point=region.sourcePoint(s.point)
                    guard let rank=Self.diatonic(s.pitch) else{continue}
                    let steps=2*(staff.y(at:point.x)-point.y)/u
                    oldErrors.append(abs(Double(rank)-(34+steps)))
                    newErrors.append(abs(Double(rank)-(22+steps)))
                }
                guard oldErrors.count>=3,oldErrors.sorted()[oldErrors.count/2]<3.5,newErrors.sorted()[newErrors.count/2]>7 else{continue}
                let replacements=notes.compactMap{ i -> (Int,String)? in
                    guard let pitch=Self.bassPitch(fromTreble:result[i].pitch) else{return nil}
                    var note=result[i];note.pitch=pitch
                    return note.midi != nil ? (i,pitch):nil
                }
                guard replacements.count==notes.count else{continue}
                for (i,pitch) in replacements {result[i].pitch=pitch}
                result.insert(.init(rhythm:"clef_F4",position:staffIndex==1 ? "lower":"upper",
                    point:CGPoint(x:localX,y:(staff.center-u-region.rect.minY)*region.scale+region.offsetY)),at:boundary)
                recovered+=1;changed+=notes.count
            }
        }
        return .init(symbols:result,recovered:recovered,changedNotes:changed)
    }
}
#endif
