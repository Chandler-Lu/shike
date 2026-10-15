# 跨平台小组件宣传图生成说明

- 文件：`../05-widgets-everywhere.png`
- 方式：内置 imagegen；未使用 CLI/API 工作流。
- 定位：README 与产品宣传用手绘示意图，延续既有配色与兔兔、缅因猫形象。
- 素材引用相对仓库根目录；生成后保留原始 PNG，未缩放或裁剪。

## 主提示词

```text
Use case: ads-marketing
Asset type: one finished Chinese promotional banner for the real app 拾刻计划, intended for its GitHub README and promotion folder.
Create a polished landscape image, preferably 1600 × 1000 px (8:5), with generous margins. This is an additional image in an existing campaign, not a redesign of the app.
Input images and roles:
1. promotion/04-widgets.png is the existing campaign STYLE reference only: warm ivory dotted paper, charcoal handwritten Chinese, cobalt blue and sage green accents, elegant restrained layout.
2. promotion/assets/widget-medium.png is the actual desktop widget CONTENT reference: reproduce the essential two-column countdown/count-up structure faithfully, never add buttons or invented functions.
3. promotion/assets/watch-widget.png is the actual Watch rectangular widget CONTENT reference: two rows, blue day counts on charcoal background.
4. promotion/assets/companions.png is the mascot IDENTITY reference: white lop-eared bunny wearing blue scarf and fluffy brown long-haired Maine Coon, lying together reading an open notebook. Keep their identity and pose, render small in the footer area, without the dark backdrop.
Primary request: Promote countdown AND count-up widgets across desktop, iPhone Lock Screen, and Apple Watch Smart Stack. Focus on the feeling of having important dates always in sight.
Composition:
Top left small brand “拾刻计划”.
Top main headline, large and beautifully legible: “在意的日子，一眼就看见。”
Subtitle: “从桌面，到锁屏，再到腕间。”
Below, a carefully balanced editorial display across three areas with distinct scales and no overlaps:
- Left, largest area, a paper-colored rounded medium desktop widget, subtly floating with soft shadow, two equal columns labeled “值得期待” in blue and “已经走过” in green. The first title “一起去看海”, large “12 天”; second title “在一起的日子”, large “1,421 天”. A subtle blue-green-yellow year progress bar along its bottom. Above or below this area label “桌面小组件”; small caption “iPhone · iPad · Mac”. This widget must be clearly readable and dominant.
- Center, a slim straight-on iPhone lock-screen presentation mockup with a soft sage pencil-textured wallpaper, time “09:41” near the top, underneath a restrained white monochrome rectangular accessory widget matching the actual app behavior: “一起去看海”, “还有 12 天”, secondary smaller line “在一起的日子  已经 1421 天”. Keep it a genuine small lock-screen accessory under the clock, not an oversized full-screen app. No app icons. Small label “锁屏小组件”.
- Right, a neat straight-on Apple Watch presentation mockup with neutral sage strap and dark screen. The screen shows a small rectangular Smart Stack widget based on input 3: “全部日子”, row “一起去看海  还有 12 天”, row “在一起的日子  已经 1421 天”. Small label “Apple Watch” and caption “智能叠放”.
Use hand-drawn pencil device outlines combined with crisp readable UI, not glossy 3D renders. Avoid huge devices swallowing the banner. Clear whitespace between objects.
Bottom area: small bunny/Maine Coon notebook vignette at left; to its right two short feature lines “正数日与倒数日，一起珍藏。” and “显示全部、选择分组，或指定一到两个日子。” Keep typography clear and hierarchy restrained.
Tiny footer “界面示意 · 示例数据” and “Chandler-Lu”, unobtrusive but readable.
Style: refined hand-drawn stationery, premium editorial layout, muted watercolor and colored-pencil accents, airy ivory paper, exceptionally clean Chinese typography, authentic gentle charm.
Constraints: use exactly the provided Chinese words, no garbled text, no extra slogans, no QR code, no download/store badges, no claims of new unsupported functions, no calendar event UI, no extra animals. Keep all words within margins. Realistic functional layout, simplified promotional mockups clearly marked as such. Make the countdown numbers blue and elapsed numbers green in the desktop widget; white/blue as appropriate on the watch and lock-screen.
```

## 最终校正指令

对首轮成图执行以下编辑，输出为最终宣传图：

```text
Edit this existing promotional image with ONE precise correction only. In the iPhone Lock Screen, change the small date line currently reading “10月26日 星期一” to exactly “10月14日 星期三”. Keep the time 09:41. This aligns the lock screen date with the desktop widget's countdown of 12 days until 2026-10-26. Preserve every other pixel as closely as possible: overall composition, all Chinese headings and captions, illustrations, devices, colors, typography, widget data, branding, dimensions and footer. Do not redesign, add, remove, reword, or reposition anything else. Opaque background.
```
