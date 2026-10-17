# 素材来源与复现

更新：2026-10-17。本目录只保留当前五张宣传图及其使用的素材。第 04 张为 1586 × 992 PNG，其余四张为 1600 × 1000 PNG；纸张底色、手写字与兔兔／长毛缅因猫插画延续应用风格。README 以五设备产品图为首图。

## 小组件手绘场景

`04-widgets.png` 使用内置 imagegen 重绘，保留彩铅设备、鼠尾草绿草地、植物与兔兔猫咪的视觉风格。当前原生小组件视图提供内容参考：桌面为野餐还有 7 天、起点已经 100 天；锁屏为看海还有 12 天、相伴已经 365 天；年度进度为已过 289 天、还剩 76 天。它是宣传场景示意，不是系统桌面截图。

完整提示词见 [04-widgets.md](prompts/04-widgets.md)。生成时使用的旧封面和旧版小组件宣传图已被替换并移除；当前内容参考保留在 `assets/`。Swift 排版脚本不会覆盖此图。

## 界面与数据

第 01、02、03、05 张的应用画面来自当前工作区的 Debug 构建（界面版本 1.2 / 15），使用隔离的自动化数据，不读取个人日历、备份或模型密钥。第 03 张“和你在一起”的起始日由作者指定为真实纪念日 2022-11-23，其余内容为示例。这四张的界面不由生成式模型重画。外框仅用于展示，不是设备外观规格图，也不作为原始 App Store 截屏。

| 素材 | 来源与处理 |
| --- | --- |
| `iphone-home.png` | iPhone 18 Pro 模拟器，`PlatformWorkspaceUITests/testPromotionWorkspace` 的实际截图 |
| `duo-workspace.png` | iPhone Duo 模拟器打开并横置，直接采集活动内屏 `primary-1`；展示原文和日程结果双栏 |
| `ipad-countdowns.png`、`ipad-planning.png` | iPad Pro 13-inch (M5) 横屏，直接采集当前显示屏；规划图放大展示原截图中的弹窗区域 |
| `mac-workspace.png` | Mac Catalyst 当前应用窗口截图，不包含桌面、其他应用或菜单栏 |
| `watch-detail.png` | Apple Watch SE 3 (40mm) 模拟器；分组选择、持久化与离线详情测试截图 |
| `color-peach.png` | 应用实际 `CountdownCard` 蜜桃粉卡片，3× 渲染；其余纸色以应用配色绘制圆点色样 |
| `share-card.png` | 应用 `CountdownCardExporter` 实际导出的竖版分享卡片，使用示例日期和原有兔猫插画 |
| `art-rabbit.png`、`art-cat.png`、`art-together.png` | 应用实际可选插画 `CountdownArtRabbit03`、`CountdownArtCat02`、`CountdownArtPair06`，透明素材等比排版 |
| `widget-medium.png`、`watch-widget.png` | 实际 `CountdownWidgetContent`，3× 原生渲染，保留作宣传场景的内容核对参考；卡片自选颜色不应用到小组件 |
| `lock-widget.png` | 实际 `CountdownLockScreenContent` 矩形样式，指定旅行为第一个日子、纪念为第二个；保留作锁屏场景的内容核对参考 |
| `backup-controls.png`、`backup-preview.png` | `ShikeUITests/testLocalBackupPreviewAndMergeRestore`；已跑通本地备份、预览与合并恢复 |
| `companions.png` | 沿用应用已有的兔兔与长毛缅因猫趴着看书插画 |

小组件与卡片固定以 **2026-10-17** 为参考日：今年已过 289 天、剩余 76 天；旅行距当天 12 天。第 03 张“和你在一起”从 **2022-11-23** 起计算，显示已经 **1424 天**（不包含起始日）；小组件场景中的相伴 365 天仍为独立示例。App 示例日子相对采集日生成。部分设备使用系统状态栏时间覆盖为 9:41，其他截图保留采集时间，没有重画状态栏。

小组件内容渲染不等于真实桌面的系统合成或后台刷新验证。Watch 截图来自模拟器，不代表本次进行了手机到实体手表的数据传输验证。备份图展示本地恢复流程与现有云端选项，不声称本次重新验证了真实 iCloud 上传。

## 联网规划示例

“北京一日游”通过仅在 Debug 自动化模式启用的 `-promotion-search-fixture` 提供稳定示例。资料在 2026-10-17 核对自：

- [故宫博物院参观服务](https://www.dpm.org.cn/Visit.html)：开放时间、入口等信息。
- [故宫博物院官方预约入口](https://ticket.dpm.org.cn/)：实名预约与官方购票渠道。

示例方案为故宫慢游、午餐休息、景山散步，参考来源展示在应用原有的“参考资料”区域。它没有调用真实模型或搜索 API，没有订票，也不构成路线或交通时间保证。用于截图的颜色数据同样仅由 Debug 自动化参数启用。

## 本次采集结果

结果包与日志保存在被 Git 忽略的 `build/promotion-refresh/`：

- `Phone.xcresult`：iPhone 界面、卡片／小组件视图、备份预览恢复。
- `MacFinal.xcresult`：Mac 应用窗口及规划、倒数日流程。
- `ipad-native/Capture.xcresult`：iPad 原生显示屏采集。
- `duo-native/Capture.xcresult`：Duo 活动内屏采集。
- `Watch.xcresult`：Watch 分组与离线详情。
- `Share.xcresult`：实际竖版分享卡片导出。
- `Countdowns.xcresult`：使用真实纪念日起始日重新渲染的色卡素材。

## 重新生成

原始素材齐全时，仅需：

```sh
swift scripts/render_promotion.swift
```

脚本输出第 01、02、03、05 张，保留第 04 张，并更新 [素材清单](assets-manifest.txt)。清单包含排版素材及手绘小组件场景的内容参考。第 04 张按已保存提示词使用内置 imagegen 重绘，生成结果可能有所不同。

重新采集时，在 Xcode 的 Debug 测试中运行：

- `PlatformWorkspaceUITests/testPromotionWorkspace`：iPhone / Mac 的实际窗口与界面。
- `CompanionBackupTests/testPromotionViewAssets`：原生卡片及小组件。
- `ShikeUITests/testLocalBackupPreviewAndMergeRestore`：备份与恢复。
- `ShikeWatchUITests/testGroupSelectionPersistsAndDetailsOpenOffline`：Watch。
- `CountdownServiceTests/testCardImageExportsARealPNGWithLongTitleAndSeconds`：竖版分享卡片。

Duo 和 iPad 的 XCTest 截图在部分模拟器状态下可能抓到非活动屏或错误裁切区域，使用宿主采集脚本读取原生显示屏。在 Device Hub 中先展开并横置 Duo，然后运行（输出目录名须未使用）：

```sh
python3 scripts/capture_promotion_device.py IPAD_SIMULATOR_UDID ipad-native
python3 scripts/capture_promotion_device.py DUO_SIMULATOR_UDID duo-native \
  --display primary-1 --without-building
```

导出本次使用的素材，再重建：

```sh
python3 scripts/export_promotion_assets.py \
  --phone build/promotion-refresh/Phone.xcresult \
  --views-result build/promotion-refresh/Countdowns.xcresult \
  --mac build/promotion-refresh/MacFinal.xcresult \
  --ipad build/promotion-refresh/ipad-native \
  --duo build/promotion-refresh/duo-native \
  --watch build/promotion-refresh/Watch.xcresult \
  --card-result build/promotion-refresh/Share.xcresult
swift scripts/render_promotion.swift
```

原生截图与素材均等比缩放；联网规划图只裁取并放大原弹窗，不改动其中的文字、来源和安排。这里的导出脚本不写入 `docs/`，不执行 Archive 或 IPA 打包。
