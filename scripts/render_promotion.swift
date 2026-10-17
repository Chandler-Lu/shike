// Rebuild four product panels from native screenshots and views; preserve the illustrated widget panel.
// Run from the repository root: swift scripts/render_promotion.swift
import AppKit
import CoreText
let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
CTFontManagerRegisterFontsForURL(root.appendingPathComponent("Shared/Resources/Fonts/LXGWWenKai-Regular.ttf") as CFURL, .process, nil)
func color(_ hex: UInt32) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 255)/255, green: CGFloat((hex >> 8) & 255)/255, blue: CGFloat(hex & 255)/255, alpha: 1)
}
let paper = color(0xF8F9F3), ink = color(0x2B3842), muted = color(0x6B747B)
let blue = color(0x3D59AC), sage = color(0xCCD8C5), metal = color(0xD8DBD5)
var usedAssets = Set<String>()
func rounded(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ r: CGFloat, _ fill: NSColor) {
    fill.setFill(); NSBezierPath(roundedRect: NSRect(x:x,y:y,width:w,height:h), xRadius:r,yRadius:r).fill()
}
func text(_ string: String, _ x: CGFloat, _ y: CGFloat, _ width: CGFloat, _ size: CGFloat, _ fill: NSColor = ink,
          system: Bool = false, height: CGFloat = 300, center: Bool = false) {
    let style = NSMutableParagraphStyle(); style.lineSpacing = size * 0.16; style.alignment = center ? .center : .left
    let font = system ? NSFont.systemFont(ofSize:size, weight:.regular) : NSFont(name:"LXGWWenKai-Regular", size:size)!
    (string as NSString).draw(in: NSRect(x:x,y:y,width:width,height:height), withAttributes:[.font:font,.foregroundColor:fill,.paragraphStyle:style])
}
func asset(_ name: String) -> NSImage {
    usedAssets.insert(name)
    guard let image = NSImage(contentsOf:root.appendingPathComponent("promotion/assets/"+name)) else { fatalError("Missing asset: \(name)") }
    return image
}
func pic(_ name: String, _ x: CGFloat, _ y: CGFloat, _ w: CGFloat) {
    let image=asset(name)
    image.draw(in:NSRect(x:x,y:y,width:w,height:w*image.size.height/image.size.width), from:.zero, operation:.sourceOver, fraction:1, respectFlipped:true,hints:[.interpolation:NSImageInterpolation.high])
}
func screen(_ name: String, _ x: CGFloat, _ y: CGFloat, _ w: CGFloat, radius: CGFloat=24, border: CGFloat=7, dark: Bool=false) {
    let image=asset(name), h=w*image.size.height/image.size.width
    NSGraphicsContext.saveGraphicsState()
    let shadow=NSShadow(); shadow.shadowColor=ink.withAlphaComponent(0.12); shadow.shadowBlurRadius=22; shadow.shadowOffset=NSSize(width:0,height:8); shadow.set()
    rounded(x-border,y-border,w+border*2,h+border*2,radius+border,dark ? color(0x30363A) : metal)
    NSGraphicsContext.restoreGraphicsState()
    NSGraphicsContext.saveGraphicsState()
    NSBezierPath(roundedRect:NSRect(x:x,y:y,width:w,height:h),xRadius:radius,yRadius:radius).addClip()
    pic(name,x,y,w); NSGraphicsContext.restoreGraphicsState()
}
// Enlarge a rectangular portion of the native screenshot without changing its UI.
func planningPanel(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat) {
    let original = asset("ipad-planning.png")
    let cg = original.cgImage(forProposedRect: nil, context: nil, hints: nil)!
    let crop = NSRect(x:CGFloat(cg.width)*0.1235, y:CGFloat(cg.height)*0.114,
                      width:CGFloat(cg.width)*0.753, height:CGFloat(cg.height)*0.772)
    let image = NSImage(cgImage:cg.cropping(to:crop)!, size:.zero)
    let h=w*image.size.height/image.size.width
    NSGraphicsContext.saveGraphicsState()
    let shadow=NSShadow();shadow.shadowColor=ink.withAlphaComponent(0.13);shadow.shadowBlurRadius=23;shadow.shadowOffset=NSSize(width:0,height:8);shadow.set()
    rounded(x-3,y-3,w+6,h+6,25,metal)
    NSGraphicsContext.restoreGraphicsState()
    NSGraphicsContext.saveGraphicsState()
    NSBezierPath(roundedRect:NSRect(x:x,y:y,width:w,height:h),xRadius:24,yRadius:24).addClip()
    image.draw(in:NSRect(x:x,y:y,width:w,height:h),from:.zero,operation:.sourceOver,fraction:1,respectFlipped:true,hints:[.interpolation:NSImageInterpolation.high])
    NSGraphicsContext.restoreGraphicsState()
}
func line(_ points: [NSPoint], _ width: CGFloat=2, _ fill: NSColor=ink) {
    let path=NSBezierPath(); path.move(to:points[0]); points.dropFirst().forEach { path.line(to:$0) }
    path.lineWidth=width;path.lineCapStyle = .round;path.lineJoinStyle = .round;fill.setStroke();path.stroke()
}
func underline(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ fill: NSColor=sage) {
    let p=NSBezierPath();p.move(to:NSPoint(x:x,y:y));p.curve(to:NSPoint(x:x+w,y:y-4),controlPoint1:NSPoint(x:x+w*0.3,y:y+5),controlPoint2:NSPoint(x:x+w*0.75,y:y-7));p.lineWidth=7;p.lineCapStyle = .round;fill.setStroke();p.stroke()
}
func brand(_ topic: String, _ number: Int) {
    text("拾刻计划",64,43,230,39)
    text(topic,285,57,950,20,muted,system:true)
    text(String(format:"%02d / 05",number),1390,57,145,19,muted,system:true,center:true)
    line([NSPoint(x:65,y:113),NSPoint(x:1535,y:113)],1,ink.withAlphaComponent(0.12))
}
func footer(_ string: String) {
    text(string,66,952,1260,16,muted,system:true,height:30)
    text("Chandler-Lu",1370,950,170,18,muted,system:true,height:30)
}
func label(_ string: String, _ x: CGFloat, _ y: CGFloat, _ w: CGFloat) { text(string,x,y,w,21,muted,system:true,height:32,center:true) }
func feature(_ title: String, _ subtitle: String, _ x: CGFloat, _ y: CGFloat, _ w: CGFloat) {
    rounded(x,y+8,5,43,2,sage);text(title,x+24,y,w-24,30);text(subtitle,x+24,y+44,w-24,21,muted,system:true,height:65)
}
func render(_ name:String, draw:()->Void) throws {
    let w=1600,h=1000
    let bitmap=NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:w,pixelsHigh:h,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:w*4,bitsPerPixel:32)!
    let cg=NSGraphicsContext(bitmapImageRep:bitmap)!.cgContext
    cg.translateBy(x:0,y:CGFloat(h));cg.scaleBy(x:1,y:-1)
    NSGraphicsContext.saveGraphicsState();NSGraphicsContext.current=NSGraphicsContext(cgContext:cg,flipped:true)
    paper.setFill();NSRect(x:0,y:0,width:w,height:h).fill()
    ink.withAlphaComponent(0.065).setFill()
    for y in stride(from:20,to:h,by:28) { for x in stride(from:20,to:w,by:28) { NSBezierPath(ovalIn:NSRect(x:CGFloat(x),y:CGFloat(y),width:1.3,height:1.3)).fill() } }
    draw();NSGraphicsContext.restoreGraphicsState()
    try bitmap.representation(using:.png,properties:[:])!.write(to:root.appendingPathComponent("promotion/"+name))
}
try render("01-platforms.png") {
    brand("随身记录 · 宽屏整理 · 抬腕查看",1)
    text("随手记下，在每一块屏幕上展开。",66,148,1480,64)
    underline(72,233,895)
    text("收起轻松记，展开并排看。输入与编辑，跟着屏幕一起延续。",73,263,1410,27,muted)
    label("Mac · 大窗口，慢慢整理",92,316,600)
    screen("mac-workspace.png",84,358,630,radius:12,border:9)
    rounded(315,827,180,18,9,metal)
    label("iPad · 横竖屏，自在展开",906,316,595)
    screen("ipad-countdowns.png",900,358,594,radius:20,border:10)
    screen("iphone-home.png",288,497,178,radius:25,border:6,dark:true)
    screen("duo-workspace.png",515,501,552,radius:25,border:8,dark:true)
    // Neutral device frames; actual screens are never repainted.
    rounded(1324,663,88,244,26,metal)
    rounded(1299,696,138,180,34,ink)
    screen("watch-detail.png",1306,706,124,radius:24,border:0,dark:true)
    pic("companions.png",1095,771,190)
    label("iPhone",273,902,210)
    label("iPhone Duo · 展开后，原文与结果并排",483,902,613)
    label("Apple Watch",1260,912,220)
    footer("iPhone / iPhone Duo / iPad / Mac / Apple Watch · 实际界面 · 示例数据")
}
try render("02-online-planning.png") {
    brand("帮我安排 · 按需联网 · 来源可查",2)
    text("先了解，\n再好好安排。",68,176,590,70)
    underline(75,379,428)
    text("去北京玩一天，\n上午逛故宫，下午慢慢散步。",76,421,530,30,muted)
    feature("查一查，再出发", "开放时间与预约要求，附上参考来源。",77,562,550)
    feature("留一点，给自己", "参考已有安排，规划可以继续追问。",77,675,550)
    feature("看一遍，再加入", "时间、地点、日历，逐条修改和确认。",77,788,550)
    planningPanel(652,184,877)
    text("照常点击「帮我安排」，需要资料时自动查询。",675,887,850,24,blue,center:true)
    footer("支持博查 / Tavily · 需自备搜索 API Key · 界面使用已核对公开资料的示例方案，交通时间为估算")
}
try render("03-countdowns.png") {
    brand("倒数与正数 · 温柔纸色 · 插画分享",3)
    text("把重要的日子，\n画成一张纪念卡。",68,170,590,62)
    underline(75,358,468)
    text("自己收藏，也想与你分享。\n挑一张喜欢的插画，留住这一刻。",76,401,535,27,muted)
    text("柔和的底色，配上清晰的计数",79,514,530,26)
    pic("color-peach.png",78,565,475)
    let colors: [UInt32] = [0xF8F9F3,0xF6EDCA,0xF4E2DF,0xE4ECDD,0xDFE9F1,0xE9E2F1]
    for (i,hex) in colors.enumerated() {
        let circle = NSBezierPath(ovalIn: NSRect(x:CGFloat(90+i*70),y:862,width:33,height:33))
        color(hex).setFill();circle.fill();ink.withAlphaComponent(0.25).setStroke();circle.lineWidth=1.5;circle.stroke()
    }
    text("六种纸色 · 列表与详情随心搭配",80,911,540,21,muted)
    text("21 张手绘插画，自由挑选",664,162,860,32,ink,center:true)
    screen("share-card.png",635,235,405,radius:14,border:2)
    text("分享卡片沿用当前计数方式",636,866,420,22,muted,center:true)
    pic("art-together.png",1100,220,405)
    pic("art-rabbit.png",1114,491,374)
    pic("art-cat.png",1174,716,284)
    footer("天 / 周 / 月 / 年 · 公历与农历 · 周年与整数日提醒 · 插画为应用内实际可选素材")
}
// 04-widgets.png is generated with imagegen; see promotion/prompts/04-widgets.md.
// Keep its native reference assets in the manifest for future content checks.
usedAssets.formUnion(["widget-medium.png", "watch-widget.png", "lock-widget.png"])
try render("05-backup.png") {
    brand("iCloud 同步 · 自动备份 · 预览恢复",5)
    text("记下的日子，\n好好留住。",68,170,670,72)
    underline(75,381,452)
    text("本地一份，iCloud Drive 再一份。",76,428,675,30,muted)
    feature("最近 20 份，安心留存", "每台设备分别保留本地与云端副本。",77,540,620)
    feature("先预览，再恢复", "导入前看清内容，自动备份当前数据。",77,658,620)
    feature("新内容，慢慢带回来", "合并新记录，已有内容留在原处。",77,776,620)
    screen("backup-controls.png",778,190,312,radius:30,border:6)
    screen("backup-preview.png",1169,190,312,radius:30,border:6)
    label("自动备份",770,887,329)
    label("JSON 导入预览",1161,887,329)
    footer("API Key 与原图不写入备份 · 历史日程不会自动重复加入系统日历 · 实际界面与示例数据")
}
let manifest = usedAssets.sorted().joined(separator:"\n")+"\n"
try manifest.write(to:root.appendingPathComponent("promotion/assets-manifest.txt"),atomically:true,encoding:.utf8)
print("Rendered four 1600 × 1000 panels; preserved the illustrated widget panel; asset manifest updated.")
