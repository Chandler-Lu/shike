# 拾刻计划 · 素材来源与复现

更新：2026-10-15。原有四张横版图基于更名后的 1.0（5），由实际界面、原生视图渲染与已有插画排版组成，未重绘应用 UI。保持纸张底色、霞鹜文楷、蓝绿计数与兔兔/缅因猫风格。新增第五张为手绘宣传示意图，其来源单独记录如下。

## 跨平台小组件宣传图

`05-widgets-everywhere.png` 为 1586 × 992 PNG，由内置 imagegen 生成，主题是「在意的日子，一眼就看见」，呈现桌面、iPhone 锁屏与 Apple Watch 智能叠放三种场景。

- 风格参考：`04-widgets.png`。
- 内容参考：`assets/widget-medium.png`、`assets/watch-widget.png`。
- 插画参考：`assets/companions.png` 中的垂耳兔与长毛缅因猫。
- 画面中的设备与界面为宣传示意，已标注「界面示意 · 示例数据」，不是系统原始截图。锁屏示例日期统一为 10 月 14 日，距示例目标 2026-10-26 为 12 天。
- 完整生成提示词与日期校正指令见 [生成说明](prompts/05-widgets-everywhere.md)。该图片不由下方 Swift 排版脚本重建。

## 原有四张宣传图

| 素材 | 来源 |
| --- | --- |
| iPhone 导入、安排、倒数日 | `build/ShikePlanStoreMaterials.xcresult`，`ShikeUITests/testAppStoreScreenshots` |
| 备份导入预览 | 同一结果包，`ShikeUITests/testLocalBackupPreviewAndMergeRestore` |
| 小、中、大桌面组件及智能叠放视图 | 同一结果包，`CompanionBackupTests/testWidgetsRenderEverySizeAndEmptyStates`；SwiftUI ImageRenderer，光栅比例 2× |
| Watch 分组、详情 | `build/ShikePlanWatchMaterials.xcresult`，`ShikeWatchUITests/testGroupSelectionPersistsAndDetailsOpenOffline` |
| 竖版分享卡片 | `build/ShikePlanShareMaterial.xcresult`，`CountdownServiceTests/testCardImageExportsARealPNGWithLongTitleAndSeconds` 中的公开示例；使用应用实际导出函数，固定参考时间为 2026-10-14 09:41（上海） |
| 兔兔与缅因猫 | 沿用已入库的 `assets/companions.png`，与应用插画一致 |

示例均为虚构数据。iPhone 为 1320 × 2868 原始截图，Watch 为 368 × 448。Watch 模拟器不支持状态栏时间覆盖，保留实际采集时间；没有重画状态栏。小组件图为原生内容渲染，不表示已验证真实桌面系统合成、后台刷新或手机到手表传输。

应用 UI 当前可见文字使用“拾刻计划”；内部 Scheme、Bundle ID、备份文件格式和既有 URL 沿用原标识。iPhone 商店截图、Watch 商店截图与横版宣传图分别存放，不能混用尺寸。

重新采集对应测试后执行：

```sh
python3 scripts/export_store_screenshots.py build/ShikePlanStoreMaterials.xcresult \
  --watch-result build/ShikePlanWatchMaterials.xcresult \
  --promotion --card-result build/ShikePlanShareMaterial.xcresult
swift scripts/render_promotion.swift
```

导出脚本仅按原尺寸转为无透明通道 JPEG，宣传素材保留原始 PNG。排版脚本将素材等比放置到 1600 × 1000 纸张画布，不修改素材中文字与界面。结果包位于被忽略的 `build/`；可分享的最终图片和素材放在本目录。
