#if DEBUG || MUSICFOCUS_HOMR
import Foundation
import CoreGraphics
import CoreText

/// Small printed numerals surrounded by verified notation rules. This is not
/// handwriting recognition: compare several system serif faces and reject
/// ambiguous shapes, rather than forcing an OCR result to be 2 or 3.
enum ScoreRecognitionPrintedDigits {
    struct Match { let digit: Int; let error: Double }
    private static let width = 24, height = 32
    private static let templates: [(Int,[Double])] = {
        var result: [(Int,[Double])] = []
        for name in ["TimesNewRomanPS-ItalicMT","TimesNewRomanPS-BoldItalicMT","TimesNewRomanPSMT","STIXGeneral-Italic","STIXGeneral-BoldItalic"] {
            let font = CTFontCreateWithName(name as CFString,60,nil)
            for digit in 1...9 {
                var character = UniChar(48+digit), glyph = CGGlyph()
                guard CTFontGetGlyphsForCharacters(font,&character,&glyph,1),let path = CTFontCreatePathForGlyph(font,glyph,nil) else { continue }
                let box = path.boundingBoxOfPath
                var transform = CGAffineTransform(a:1,b:0,c:0,d:1,tx:10-box.minX,ty:10-box.minY)
                var pixels = [UInt8](repeating:255,count:100*100)
                pixels.withUnsafeMutableBytes { raw in
                    let context = CGContext(data:raw.baseAddress,width:100,height:100,bitsPerComponent:8,bytesPerRow:100,space:CGColorSpaceCreateDeviceGray(),bitmapInfo:0)!
                    context.setFillColor(gray:0,alpha:1); context.addPath(path.copy(using:&transform)!);context.fillPath()
                }
                if let normalized = normalized(pixels,width:100,height:100) { result.append((digit,normalized)) }
            }
        }
        return result
    }()
    static func read(raster: ScoreRecognitionRaster, center: CGPoint, unit: Double) -> Match? {
        let ranked = scores(raster:raster,center:center,unit:unit)
        guard ranked.count>1,ranked[0].error<0.15,ranked[0].error<ranked[1].error*0.65 else{return nil}
        return ranked[0]
    }
    static func scores(raster: ScoreRecognitionRaster, center: CGPoint, unit: Double) -> [Match] {
        let r = CGRect(x:center.x-unit*0.65,y:center.y-unit,width:unit*1.3,height:unit*2).integral
        let x=Int(r.minX),y=Int(r.minY),w=Int(r.width),h=Int(r.height)
        guard x>=0,y>=0,x+w<raster.width,y+h<raster.height else {return []}
        var pixels = (0..<h).flatMap { Array(raster.pixels[(y+$0)*raster.width+x..<(y+$0)*raster.width+x+w]) }
        // Remove short rule fragments at the edge of the crop, keeping the
        // detached numeral in the central gap, including disconnected serifs.
        var seen=Set<Int>()
        for seed in pixels.indices where pixels[seed]<170 && !seen.contains(seed) {
            var component=[seed],head=0;seen.insert(seed)
            while head<component.count {
                let i=component[head];head+=1
                for (dx,dy) in [(-1,0),(1,0),(0,-1),(0,1)] {
                    let xx=i%w+dx,yy=i/w+dy
                    guard xx>=0,xx<w,yy>=0,yy<h else {continue}
                    let next=yy*w+xx
                    if pixels[next]<170 && !seen.contains(next) {seen.insert(next);component.append(next)}
                }
            }
            let xs=component.map{$0%w},ys=component.map{$0/w}
            if (xs.min()==0 || xs.max()==w-1) && Double(ys.max()!-ys.min()!+1)<unit*0.4 {
                for i in component {pixels[i]=255}
            }
        }
        guard let vector=normalized(pixels,width:w,height:h) else {return []}
        var errors=[Double](repeating:.infinity,count:10)
        for (digit,reference) in templates {
            let error=zip(vector,reference).reduce(0.0){$0+pow($1.0-$1.1,2)}/Double(vector.count)
            errors[digit]=min(errors[digit],error)
        }
        let ranked=(1...9).sorted{errors[$0]<errors[$1]}
        return ranked.map{.init(digit:$0,error:errors[$0])}
    }
    private static func normalized(_ pixels:[UInt8],width w:Int,height h:Int)->[Double]? {
        let ink=pixels.indices.filter{pixels[$0]<170}
        guard !ink.isEmpty else{return nil}
        let xs=ink.map{$0%w},ys=ink.map{$0/w},x0=xs.min()!,y0=ys.min()!,iw=xs.max()!-x0+1,ih=ys.max()!-y0+1
        guard iw>=3,ih>=6,Double(iw)/Double(ih)>0.2,Double(iw)/Double(ih)<1.5 else{return nil}
        // Area sampling keeps thin print comparable across source resolutions.
        return (0..<height).flatMap { y in (0..<width).map { x in
            var sum=0.0
            for sy in 0..<4 {for sx in 0..<4 {
                let xx=min(w-1,x0+Int((Double(x)+(Double(sx)+0.5)/4)*Double(iw)/Double(width)))
                let yy=min(h-1,y0+Int((Double(y)+(Double(sy)+0.5)/4)*Double(ih)/Double(height)))
                sum += pixels[yy*w+xx]<170 ? 1:0
            }}
            return sum/16
        }}
    }
}
#endif
