import AppKit
import Foundation

// Export Apple's installed SF Symbol rather than an approximation of its artwork.
let root = URL(fileURLWithPath:FileManager.default.currentDirectoryPath,isDirectory:true)
let fileManager = FileManager.default
let iconBlue = NSColor(srgbRed:0,green:177.0/255.0,blue:1,alpha:1) // #00b1ff
guard let symbol = NSImage(systemSymbolName:"at.circle.fill",accessibilityDescription:"Mail Dot") else {
    fatalError("The installed macOS does not provide at.circle.fill.")
}

func png(pixels:Int,to url:URL) throws {
    guard let colorSpace = CGColorSpace(name:CGColorSpace.sRGB),
        let bitmap = CGContext(data:nil,width:pixels,height:pixels,bitsPerComponent:8,bytesPerRow:0,
            space:colorSpace,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue) else { fatalError("Cannot create sRGB icon bitmap") }
    let context = NSGraphicsContext(cgContext:bitmap,flipped:false)
    let configuration = NSImage.SymbolConfiguration(pointSize:CGFloat(pixels)*0.92,weight:.regular)
        .applying(NSImage.SymbolConfiguration(paletteColors:[.white,iconBlue]))
    guard let image = symbol.withSymbolConfiguration(configuration) else { fatalError("Cannot configure SF Symbol") }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    NSColor.clear.setFill()
    NSRect(x:0,y:0,width:pixels,height:pixels).fill(using:.copy)
    image.draw(in:NSRect(x:CGFloat(pixels)*0.04,y:CGFloat(pixels)*0.04,width:CGFloat(pixels)*0.92,height:CGFloat(pixels)*0.92))
    NSGraphicsContext.restoreGraphicsState()
    guard let rendered = bitmap.makeImage(), let data = NSBitmapImageRep(cgImage:rendered).representation(using:.png,properties:[:]) else {
        fatalError("Cannot encode sRGB PNG")
    }
    try data.write(to:url)
}

/// The app icon is original artwork, drawn here from plain geometry: Apple's licence allows SF Symbols inside
/// an app's interface but not as its icon. It keeps the same idea, a white at-sign on Mail Dot blue, in the
/// rounded-rectangle shape macOS icons use.
func appIconPNG(pixels:Int,to url:URL) throws {
    guard let colorSpace = CGColorSpace(name:CGColorSpace.sRGB),
        let context = CGContext(data:nil,width:pixels,height:pixels,bitsPerComponent:8,bytesPerRow:0,
            space:colorSpace,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue) else { fatalError("Cannot create sRGB icon bitmap") }
    let size = CGFloat(pixels)
    context.clear(CGRect(x:0,y:0,width:size,height:size))
    // macOS icon grid: the shape occupies 824 of 1024 points, with a continuous corner of about 185.
    let inset = size*100/1024, side = size-2*inset
    let shape = CGPath(roundedRect:CGRect(x:inset,y:inset,width:side,height:side),cornerWidth:side*0.225,cornerHeight:side*0.225,transform:nil)
    context.saveGState()
    context.addPath(shape); context.clip()
    let colors = [CGColor(srgbRed:0.20,green:0.77,blue:1,alpha:1),CGColor(srgbRed:0,green:0.61,blue:0.90,alpha:1)] as CFArray
    let gradient = CGGradient(colorsSpace:colorSpace,colors:colors,locations:[0,1])!
    context.drawLinearGradient(gradient,start:CGPoint(x:0,y:size-inset),end:CGPoint(x:0,y:inset),options:[])
    context.restoreGState()
    // The at-sign: a bowl, a stem, and a tail that sweeps around them and stops short of closing.
    let center = CGPoint(x:size/2,y:size/2), bowl = side*0.125, ring = side*0.285, stroke = side*0.062
    context.setStrokeColor(CGColor(srgbRed:1,green:1,blue:1,alpha:1))
    context.setLineWidth(stroke); context.setLineCap(.round); context.setLineJoin(.round)
    context.addEllipse(in:CGRect(x:center.x-bowl,y:center.y-bowl,width:bowl*2,height:bowl*2))
    context.strokePath()
    context.move(to:CGPoint(x:center.x+bowl,y:center.y+bowl*0.95))
    context.addLine(to:CGPoint(x:center.x+bowl,y:center.y-bowl*0.35))
    context.addQuadCurve(to:CGPoint(x:center.x+ring,y:center.y),control:CGPoint(x:center.x+bowl+(ring-bowl)*0.55,y:center.y-bowl*1.55))
    context.addArc(center:center,radius:ring,startAngle:0,endAngle:.pi*1.72,clockwise:false)
    context.strokePath()
    guard let rendered = context.makeImage(), let data = NSBitmapImageRep(cgImage:rendered).representation(using:.png,properties:[:]) else {
        fatalError("Cannot encode sRGB PNG")
    }
    try data.write(to:url)
}

let appAssets = root.appendingPathComponent("Targets/Companion/Assets.xcassets",isDirectory:true)
let appIcon = appAssets.appendingPathComponent("AppIcon.appiconset",isDirectory:true)
try fileManager.createDirectory(at:appIcon,withIntermediateDirectories:true)
var images:[[String:String]] = []
for size in [16,32,128,256,512] {
    for scale in [1,2] {
        let filename = "at-circle-fill-\(size)@\(scale)x.png"
        try appIconPNG(pixels:size*scale,to:appIcon.appendingPathComponent(filename))
        images.append(["idiom":"mac","size":"\(size)x\(size)","scale":"\(scale)x","filename":filename])
    }
}
let info:[String:Any] = ["author":"xcode","version":1]
try JSONSerialization.data(withJSONObject:["images":images,"info":info],options:[.prettyPrinted,.sortedKeys])
    .write(to:appIcon.appendingPathComponent("Contents.json"))
try JSONSerialization.data(withJSONObject:["info":info],options:[.prettyPrinted,.sortedKeys])
    .write(to:appAssets.appendingPathComponent("Contents.json"))

let toolbarAssets = root.appendingPathComponent("Targets/MailExtension/Assets.xcassets/DotCompose.imageset",isDirectory:true)
try fileManager.createDirectory(at:toolbarAssets,withIntermediateDirectories:true)
// Mail's compose toolbar draws this image as supplied. A PDF made by drawing the symbol into a PDF context
// came out as a solid square, so the toolbar icon is exported as bitmaps with a transparent background.
var toolbarImages:[[String:String]] = []
for scale in [1,2,3] {
    let filename = "at-circle-fill-24@\(scale)x.png"
    try png(pixels:24*scale,to:toolbarAssets.appendingPathComponent(filename))
    toolbarImages.append(["idiom":"universal","scale":"\(scale)x","filename":filename])
}
let toolbarContents:[String:Any] = ["images":toolbarImages,"info":info,
    "properties":["template-rendering-intent":"original"]]
try JSONSerialization.data(withJSONObject:toolbarContents,options:[.prettyPrinted,.sortedKeys])
    .write(to:toolbarAssets.appendingPathComponent("Contents.json"))
print("Exported the original app icon and the Mail compose toolbar icon.")
