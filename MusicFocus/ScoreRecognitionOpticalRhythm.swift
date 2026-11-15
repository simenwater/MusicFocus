#if DEBUG || MUSICFOCUS_HOMR
import Foundation
import CoreGraphics

/// Repairs require independent musical clocks AND evidence in the original
/// print. No note is stretched merely to make a bar look regular.
enum ScoreRecognitionOpticalRhythm {
    struct Result {var symbols:[ScoreRecognitionSymbol];var corrected:Int}
    struct Event {var group:Int;var indices:[Int];var duration:Double}
    static func groups(_ symbols:[ScoreRecognitionSymbol])->[[Int]] {
        var result:[[Int]]=[],join=false
        for i in symbols.indices {
            if symbols[i].rhythm=="chord" {join=true;continue}
            if join && !result.isEmpty {result[result.count-1].append(i)} else {result.append([i])}
            join=false
        }
        return result
    }
    static func voices(_ symbols:[ScoreRecognitionSymbol],groups:[[Int]])->[String:[Event]] {
        var output:[String:[Event]]=[:]
        for (g,indices) in groups.enumerated() {
            for (voice,notes) in Dictionary(grouping:indices.filter{symbols[$0].duration>0},by:{symbols[$0].position}) {
                output[voice,default:[]].append(.init(group:g,indices:notes,duration:notes.map{symbols[$0].duration}.min()!))
            }
        }
        return output
    }
    static func starts(_ events:[Event])->[Int:Double] {
        var result:[Int:Double]=[:],time=0.0
        for event in events {result[event.group]=time;time+=event.duration}
        return result
    }
    static func ordinary(_ symbol:ScoreRecognitionSymbol)->Bool {
        guard symbol.duration>0,let n=Int(symbol.rhythm.split(separator:"_").last?.prefix(while:\.isNumber) ?? ""),n>0 else{return false}
        return n & (n-1)==0
    }
    /// Supported compound duplet: a bracketed 2 containing an explicitly
    /// printed inner 3 and a longer final event. The complete bar must be
    /// bracketed on both staves and the page must supply a printed meter unit.
    static func repairNested(_ symbols:[ScoreRecognitionSymbol],raster:ScoreRecognitionRaster,region:ScoreRecognitionRegion,unit:Double?) throws -> Result {
        guard region.staffs.count==2,let unit,[0.125,0.25,0.5].contains(unit) else{return .init(symbols:symbols,corrected:0)}
        let brackets=try ScoreRecognitionTupletEvidence.brackets(raster:raster,region:region)
        guard brackets.count>=4 else{return .init(symbols:symbols,corrected:0)}
        let grouped=groups(symbols)
        var bars:[[Int]]=[],bar:[Int]=[]
        for (g,indices) in grouped.enumerated() {
            if indices.contains(where:{symbols[$0].rhythm.contains("barline") || symbols[$0].rhythm.hasPrefix("repeat")}) {bars.append(bar);bar=[]}
            else if indices.contains(where:{symbols[$0].duration>0}) {bar.append(g)}
        }
        var result=symbols,corrected=0
        func median(_ values:[Double])->Double {let sorted=values.sorted();return sorted[sorted.count/2]}
        let x=grouped.map{indices in median(indices.map{region.sourcePoint(symbols[$0].point).x})}
        func token(_ old:String,beats:Double)->String? {
            for denominator in [4,8,16,32,64] {for (suffix,factor) in [("",1.0),(".",1.5)] where abs(4.0/Double(denominator)*factor-beats)<1e-6 {
                return (old.hasPrefix("rest_") ? "rest_":"note_")+String(denominator)+suffix
            }}
            return nil
        }
        for bar in bars {
            var changes:[Int:String]=[:],staffLengths:[Double]=[],valid=true
            for staff in 0...1 {
                let events=bar.filter{g in grouped[g].contains{symbols[$0].duration>0 && (symbols[$0].position.hasPrefix("lower") ? 1:0)==staff}}
                let matches=brackets.filter{$0.staff==staff}.sorted{$0.left<$1.left}
                var covered=Set<Int>(),length=0.0,used=0
                for bracket in matches {
                    let inside=events.filter{x[$0]>=bracket.left-bracket.unit*1.4 && x[$0]<=bracket.right+bracket.unit*0.8}
                    guard inside.count==4 || inside.count==2 else{continue}
                    guard Set(inside).isDisjoint(with:covered) else{valid=false;break}
                    if inside.count==4 {
                        guard inside.prefix(3).allSatisfy({g in grouped[g].contains{(symbols[$0].position.hasPrefix("lower") ? 1:0)==staff && ["note_24","note_48","note_12"].contains(symbols[$0].rhythm)}}),
                              ScoreRecognitionTupletEvidence.hasInnerTriplet(bracket,first:x[inside[0]],third:x[inside[2]],raster:raster) else{continue}
                    } else {
                        guard grouped[inside[0]].contains(where:{symbols[$0].rhythm.hasPrefix("rest_") && (symbols[$0].position.hasPrefix("lower") ? 1:0)==staff}) else{continue}
                    }
                    for (position,g) in inside.enumerated() {
                        let beats=inside.count==2 || position==3 ? unit*1.5:unit*0.5
                        for i in grouped[g] where symbols[i].duration>0 && (symbols[i].position.hasPrefix("lower") ? 1:0)==staff {
                            guard symbols[i].duration<=unit*2,let replacement=token(symbols[i].rhythm,beats:beats) else{valid=false;break}
                            changes[i]=replacement
                        }
                    }
                    covered.formUnion(inside);length+=unit*3;used+=1
                }
                guard valid,used>=2,used<=3,covered==Set(events) else{valid=false;break}
                staffLengths.append(length)
            }
            guard valid,staffLengths.count==2,abs(staffLengths[0]-staffLengths[1])<1e-6 else{continue}
            var proposed=result
            for (i,rhythm) in changes {proposed[i].rhythm=rhythm}
            let indices=bar.flatMap{grouped[$0]}
            // Reconstitute original simultaneous groups for a timing check.
            var fragment:[ScoreRecognitionSymbol]=[]
            for g in bar {for (offset,i) in grouped[g].enumerated() {
                if offset>0 {fragment.append(.init(rhythm:"chord"))};fragment.append(proposed[i])
            }}
            guard let timeline=try? ScoreRecognitionTimeline.convert(fragment,options:.init(enabled:false)),abs(timeline.duration-staffLengths[0])<1e-6 else{continue}
            corrected+=indices.filter{result[$0].rhythm != proposed[$0].rhythm}.count
            result=proposed
        }
        return .init(symbols:result,corrected:corrected)
    }
    static func repairBeams(_ symbols:[ScoreRecognitionSymbol],raster:ScoreRecognitionRaster,region:ScoreRecognitionRegion)->Result {
        let evidence=ScoreRecognitionBeamEvidence(raster:raster)
        var output:[ScoreRecognitionSymbol]=[],bar:[ScoreRecognitionSymbol]=[],count=0
        func repair(_ input:[ScoreRecognitionSymbol])->[ScoreRecognitionSymbol] {
            let grouped=groups(input),original=voices(input,groups:grouped)
            guard original.count>=2 else{return input}
            var beamCache:[Int:Int]=[:]
            func beams(_ i:Int)->Int? {
                if let saved=beamCache[i] {return saved>0 ? saved:nil}
                let symbol=input[i]
                let staff=region.staffs[min(symbol.position.hasPrefix("lower") ? 1:0,region.staffs.count-1)]
                let value=evidence.count(at:region.sourcePoint(symbol.point),unit:staff.unit)
                beamCache[i]=value ?? 0;return value
            }
            var proposed=input
            // Short partial beams are easy to miss in a scan. Require a
            // majority of the chord's heads to support the second beam.
            if input.filter({$0.duration>0}).allSatisfy(ordinary) {
                for events in original.values {for event in events {
                    guard let rhythm=event.indices.first.map({input[$0].rhythm}),
                          ["note_2","note_8"].contains(rhythm),
                          event.indices.allSatisfy({input[$0].rhythm==rhythm && input[$0].midi != nil}) else{continue}
                    for count in (rhythm == "note_2" ? [1] : [2]) {
                        let replacement="note_\(1 << (count+2))"
                        guard ScoreRecognitionSymbol(rhythm:replacement).duration < event.duration,
                              event.indices.filter({beams($0)==count}).count*3>=event.indices.count*2 else{continue}
                        for i in event.indices {proposed[i].rhythm=replacement};break
                    }
                }}
                let changed=Set(input.indices.filter{input[$0].rhythm != proposed[$0].rhythm}.map{input[$0].position})
                let revised=voices(proposed,groups:grouped)
                for (_,anchor) in original where !changed.contains(input[anchor[0].indices[0]].position) && anchor.count>=2 {
                    let length=anchor.reduce(0){$0+$1.duration},reference=starts(anchor)
                    guard !changed.isEmpty else{continue}
                    let valid=changed.allSatisfy { key in
                        let old=original[key]!,new=revised[key]!,newStarts=starts(new)
                        let shared=reference.keys.filter{newStarts[$0] != nil}
                        return old.first?.group==anchor.first?.group && old.reduce(0){$0+$1.duration}>length+0.1
                            && abs(new.reduce(0){$0+$1.duration}-length)<1e-6 && shared.count>=2
                            && shared.allSatisfy{abs(reference[$0]!-newStarts[$0]!)<1e-6}

                    }
                    if valid,let result=try? ScoreRecognitionTimeline.convert(proposed,options:.init(enabled:false)),abs(result.duration-length)<1e-6 {return proposed}
                }
            }
            // A tuplet label can leak into following ordinary beamed chords.
            // Mixed sustained notes in that chord are retained; two independent
            // ordinary voices must establish every shared attack and bar end.
            for key in original.keys.sorted() {
                let events=original[key]!
                guard events.count>=6,events.allSatisfy({abs($0.duration-1.0/6)<1e-6 && $0.indices.contains{input[$0].rhythm=="note_24"}}) else{continue}
                let supported=events.filter {event in
                    let notes=event.indices.filter{input[$0].rhythm=="note_24"}
                    return notes.contains{beams($0)==2}
                }.count
                guard supported*2>=events.count else{continue}
                proposed=input
                for event in events {for i in event.indices where input[i].rhythm=="note_24" {proposed[i].rhythm="note_16"}}
                let revised=voices(proposed,groups:grouped)[key]!,candidate=starts(revised),length=revised.reduce(0){$0+$1.duration}
                let anchors=original.filter { other,value in
                    other != key && value.count>=2 && value.first?.group==events.first?.group && abs(value.reduce(0){$0+$1.duration}-length)<1e-6
                    && value.allSatisfy{$0.indices.allSatisfy{ordinary(input[$0])}}
                }
                guard anchors.count>=2 else{continue}
                var shared=Set<Int>(),consistent=true
                for value in anchors.values {for (g,t) in starts(value) {
                    if let own=candidate[g] {shared.insert(g);if abs(own-t)>1e-6 {consistent=false}}
                }}
                guard consistent,shared.count>=3,shared.compactMap({candidate[$0]}).max() ?? 0 >= length*0.5 else{continue}
                if let result=try? ScoreRecognitionTimeline.convert(proposed,options:.init(enabled:false)),abs(result.duration-length)<1e-6 {return proposed}
            }
            return input
        }
        for symbol in symbols {
            if symbol.rhythm.contains("barline") || symbol.rhythm.hasPrefix("repeat") {
                let revised=repair(bar);count+=zip(bar,revised).filter{$0.rhythm != $1.rhythm}.count
                output+=revised;output.append(symbol);bar=[]
            } else{bar.append(symbol)}
        }
        output+=bar
        return .init(symbols:output,corrected:count)
    }
}
#endif
