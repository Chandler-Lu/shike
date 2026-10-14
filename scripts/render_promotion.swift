// Compose product artwork from actual screenshots; run at the repository root.
import AppKit
import CoreText
let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
CTFontManagerRegisterFontsForURL(root.appendingPathComponent("Shared/Resources/Fonts/LXGWWenKai-Regular.ttf") as CFURL, .process, nil)
let paper = NSColor(srgbRed: 0.973, green: 0.976, blue: 0.953, alpha: 1)
let ink = NSColor(srgbRed: 0.15, green: 0.20, blue: 0.24, alpha: 1)
let blue = NSColor(srgbRed: 0.18, green: 0.34, blue: 0.79, alpha: 1)
let muted = NSColor(srgbRed: 0.39, green: 0.44, blue: 0.47, alpha: 1)
let green = NSColor(srgbRed: 0.72, green: 0.79, blue: 0.67, alpha: 1)
func rounded(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ r: CGFloat, _ color: NSColor) {
    color.setFill(); NSBezierPath(roundedRect: NSRect(x:x,y:y,width:w,height:h), xRadius:r,yRadius:r).fill()
}
func text(_ string: String, _ x: CGFloat, _ y: CGFloat, _ width: CGFloat, _ size: CGFloat, _ color: NSColor = ink, system: Bool = false, height: CGFloat = 350) {
    let style = NSMutableParagraphStyle(); style.lineSpacing = size * 0.16
    let font = system ? NSFont.systemFont(ofSize:size, weight:.regular) : NSFont(name:"LXGWWenKai-Regular", size:size)!
    (string as NSString).draw(in: NSRect(x:x,y:y,width:width,height:height), withAttributes:[.font:font,.foregroundColor:color,.paragraphStyle:style])
}
func asset(_ name: String) -> NSImage { NSImage(contentsOf:root.appendingPathComponent("promotion/assets/"+name))! }
func pic(_ name: String, _ x: CGFloat, _ y: CGFloat, _ w: CGFloat, h: CGFloat? = nil) {
    let image=asset(name); let height=h ?? w*image.size.height/image.size.width
    image.draw(in:NSRect(x:x,y:y,width:w,height:height), from:.zero, operation:.sourceOver, fraction:1, respectFlipped:true,hints:[.interpolation:NSImageInterpolation.high])
}
func screen(_ name: String, _ x: CGFloat, _ y: CGFloat, _ width: CGFloat, radius: CGFloat=32, border: CGFloat=7, dark: Bool=false) {
    let image=asset(name); let height=width*image.size.height/image.size.width
    NSGraphicsContext.saveGraphicsState()
    let shadow=NSShadow(); shadow.shadowColor=ink.withAlphaComponent(0.13); shadow.shadowBlurRadius=26;shadow.shadowOffset=NSSize(width:0,height:10);shadow.set()
    rounded(x-border,y-border,width+border*2,height+border*2,radius+border,dark ? .black : NSColor(srgbRed:0.91,green:0.92,blue:0.88,alpha:1))
    NSGraphicsContext.restoreGraphicsState()
    NSGraphicsContext.saveGraphicsState()
    NSBezierPath(roundedRect:NSRect(x:x,y:y,width:width,height:height),xRadius:radius,yRadius:radius).addClip()
    pic(name,x,y,width);NSGraphicsContext.restoreGraphicsState()
}
func underline(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, color:NSColor=green) {
    let p=NSBezierPath();p.move(to:NSPoint(x:x,y:y));p.curve(to:NSPoint(x:x+w,y:y-4),controlPoint1:NSPoint(x:x+w*0.3,y:y+5),controlPoint2:NSPoint(x:x+w*0.75,y:y-7));p.lineWidth=7;p.lineCapStyle = .round;color.setStroke();p.stroke()
}
func brand(_ suffix:String) {
    text("拾刻计划",70,52,220,42);text(suffix,300,68,1080,20,muted,system:true)
}
func footer(_ s:String) { text(s,72,945,1350,18,muted,system:true);text("Chandler-Lu",1380,945,180,18,muted,system:true) }
func render(_ name:String, draw:()->Void) throws {
    let w=1600,h=1000
    let bitmap=NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:w,pixelsHigh:h,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:w*4,bitsPerPixel:32)!
    let base=NSGraphicsContext(bitmapImageRep:bitmap)!,cg=base.cgContext
    cg.translateBy(x:0,y:CGFloat(h));cg.scaleBy(x:1,y:-1)
    NSGraphicsContext.saveGraphicsState();NSGraphicsContext.current=NSGraphicsContext(cgContext:cg,flipped:true)
    paper.setFill();NSRect(x:0,y:0,width:w,height:h).fill()
    ink.withAlphaComponent(0.07).setFill()
    for y in stride(from:22,to:h,by:30) { for x in stride(from:22,to:w,by:30) { NSBezierPath(ovalIn:NSRect(x:CGFloat(x),y:CGFloat(y),width:1.4,height:1.4)).fill() } }
    draw();NSGraphicsContext.restoreGraphicsState()
    try bitmap.representation(using:.png,properties:[:])!.write(to:root.appendingPathComponent("promotion/"+name))
}
try render("01-shike.png") {
    brand("日程 · 计划 · 值得记住的日子")
    text("把零散安排，\n收进日历。",70,180,650,76)
    underline(76,397,470)
    text("一段文字，一张截图，\n或一个终于想开始的念头。",76,445,650,30,muted)
    text("提取日程  /  问答安排  /  手动核对",78,570,650,22,blue,system:true)
    pic("companions.png",92,634,410)
    screen("iphone-planning.jpg",1120,215,326)
    screen("iphone-import.png",745,145,342)
    footer("原生 iPhone App · 手绘手帐风 · AI 功能需自备模型接口")
}
try render("02-countdowns.png") {
    brand("倒数日 · 桌面小组件 · Apple Watch")
    text("重要的日子，\n一眼就看见。",70,170,600,70)
    underline(78,372,460)
    text("桌面一瞥，抬腕可见。\n显示全部，或只看在意的那一组。",76,418,580,28,muted)
    screen("iphone-countdowns.png",1166,152,330)
    screen("widget-small.png",690,177,260,radius:35,border:2)
    text("一主一辅，期待与纪念",676,467,460,21,muted,system:true)
    screen("widget-medium.png",672,552,444,radius:30,border:2)
    text("小、中、大三种尺寸 · 独立选择分组",674,790,485,21,muted,system:true)
    // A neutral presentation frame; the content is an actual Watch screenshot.
    rounded(114,575,218,321,55,ink)
    screen("watch-detail.png",130,602,186,radius:27,border:0,dark:true)
    text("Apple Watch",370,597,260,25,ink,system:true)
    text("离线也能查看\n已同步的日子",370,650,260,24,muted)
    text("智能叠放",371,746,260,20,muted,system:true)
    screen("watch-widget.png",367,783,244,radius:21,border:0,dark:true)
    footer("公历与农历 · 周年与整数日提醒 · 秒级计时 · 竖版卡片分享")
}
try render("03-backup.png") {
    brand("iCloud 同步 · 自动备份 · JSON 恢复")
    text("记下的日子，\n好好留住。",70,176,660,74)
    underline(77,392,455)
    text("本地一份，iCloud Drive 再一份。",77,443,680,30,muted)
    let rows:[(String,String)] = [("自动留存","数据变化后检查备份，各保留最近 30 份。"),("先看再恢复","导入前预览，并备份当前内容。"),("把新内容带回来","合并新记录，保留本机已有内容。")]
    for (i,row) in rows.enumerated() {
        let y=CGFloat(548+i*103)
        rounded(78,y+10,7,45,3,green)
        text(row.0,105,y,600,31)
        text(row.1,107,y+45,665,21,muted,system:true)
    }
    screen("share-card.png",1215,267,267,radius:16,border:2)
    text("值得分享，也值得收藏",1193,762,330,23,muted)
    screen("backup-preview.png",812,143,340)
    footer("支持拾刻计划 JSON 备份 · API Key 与原图不写入备份 · 历史日程不会自动重复加入日历")
}
try render("04-widgets.png") {
    brand("正数日与倒数日 · 同在桌面")
    text("期待将来的，\n也珍惜走过的。",70,170,730,66)
    underline(78,365,540)
    text("小号一主一辅，中大号正倒分区。\n日期、置顶与年度进度，一眼看清。",76,412,730,28,muted)
    screen("widget-small.png",680,170,240,radius:30,border:2)
    text("小号 · 一主一辅",706,434,280,20,muted,system:true)
    screen("widget-medium.png",80,596,690,radius:36,border:2)
    text("中号 · 留一份期待，也留一份纪念",82,558,720,21,muted,system:true)
    screen("widget-large.png",982,174,540,radius:40,border:2)
    text("大号 · 让更多重要日子，一起出现",983,774,550,23,muted)
    text("显示全部，或只看某个分组。",985,820,550,24,ink)
    footer("iPhone 桌面小组件 · 小 / 中 / 大三种尺寸 · 点击查看对应日子")
}
print("Rendered four 1600 × 1000 product images in promotion/.")
