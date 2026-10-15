# 本地开发与调试

产品介绍见 [README](README.md)，使用说明见 [SUPPORT](SUPPORT.md)。`docs/` 中的上架资料、签名文件、调试产物和个人备份不进入 Git。

## 模型请求与诊断

提取日程、帮我安排、倒数日识别与日历总结复用 `LLMClient`。OpenAI 兼容接口、Claude Messages、Gemini 默认使用各自的 SSE 协议；按字节拼接 UTF-8，只在完整结束并通过 JSON 校验后生成结果。推理片段只统计首段时间与字符数，不混入日程正文，也不保存其内容。

每次操作共享 300 秒总时限；首次响应数据最多等待 90 秒，收到数据后连续 60 秒没有新数据才判定中断。心跳与推理片段可以续接接收状态，但不能延长总时限。取消会停止底层 URLSession 请求。HTTP 504、无首次数据、中途停滞、总时限和用户取消分别报告。

仅在 HTTP 400 / 422 明确拒绝流式或 JSON 参数时兼容降级，每种参数最多移除一次，总共最多三次请求，全部共用总时限。超时、断线、认证失败、限流或服务端异常不会自动重试。已确认不支持的能力按接口地址、协议和模型在本机缓存 24 小时，不随 iCloud 同步。

设置 → API → 测试连接会显示可展开、可复制的“请求诊断”，包含总耗时、首个响应数据、首段推理、首段正文、DNS / 连接 / TLS、HTTP 状态、代理与连接复用信息。缺失指标显示“未取得”，不推断为零。诊断不包含 API Key、原文、模型正文、推理正文或服务端请求 ID。

Debug 启动参数 `-llm-probe -llm-probe-profile 0 -llm-probe-mode stream -llm-probe-repeat 1` 可对已保存的指定接口做固定样例测试；接口序号从零起，重复次数限制 1–3。`legacy` 模式复现旧版缓冲式 `URLSession.data(for:)` 与 60 / 90 秒超时，用相同提示词、参考时间、输入与模型参数对照。测试只发送内置的一条 / 三条虚拟日程，不保存为用户日程；可能产生接口调用费用。仅使用本机钥匙串中已有密钥，锁屏可能阻止读取。脱敏报告位于 App 缓存目录 `LLMProbe-<mode>-<profile>.txt`，不要将个人诊断产物提交到 Git。

`LLMStreamingTests` 覆盖三种 SSE 协议、拆分 UTF-8、推理与正文分离、心跳、三种超时、取消、截断与拒绝、不完整响应、有限兼容降级和缓存过期。`NewFeatureUITests.testAPIStreamingDiagnosticsAndCancellation` 使用本地分段响应验证设置中的诊断展开、复制与取消，不请求真实服务。

## 运行目标

| 平台 | Scheme | 运行目标 |
| --- | --- | --- |
| iPhone / iPad，系统 17+ | Shike | 对应模拟器或开发设备 |
| Mac，系统 14+ | ShikeMac | My Mac (Mac Catalyst) |
| Apple Watch，系统 10+ | ShikeWatch | Watch 模拟器或配对开发设备 |

Mac 主应用沿用 Catalyst，同时嵌入 Catalyst 分享扩展与原生 macOS 的 `ShikeMacWidgets`。iOS 主应用嵌入 iOS 小组件及 Watch App；项目中的平台过滤条件保证两者不会混装。锁屏的行内、圆形、矩形组件包含在 iOS `ShikeWidgets` 中，不增加独立 App ID。

`scripts/generate_project.rb` 刷新文件成员关系、平台配置和 Mac Scheme，保留现有版本与签名团队。需要 Ruby 的 `xcodeproj`；也可安装到被忽略的 `build/gems` 后运行。更新源码成员后运行一次该脚本，检查项目差异。

## 编译，不打包

以下脚本只做未签名 Debug 编译，不 Archive、不导出安装包、不安装或上传：

```sh
scripts/build_debug.sh ios
scripts/build_debug.sh ipad
scripts/build_debug.sh mac
scripts/build_debug.sh watch
```

运行 Mac App 或测试共享容器时，应在 Xcode 使用正常的开发签名，不能把未签名编译当成可运行版本。首次运行需在开发者账户中登记本机，并为主应用、分享扩展和 Mac 小组件生成对应的开发描述文件；Xcode 的 Automatically manage signing 可处理这些步骤。不要提交描述文件、证书或个人配置。

## 数据与权限边界

- iCloud Drive 的 `NSUbiquitousContainers` 字典键必须使用容器标识的字面量；Xcode 只展开值中的构建变量。修改公共名称或可见性后需递增 Build，让系统刷新容器元数据。本次修复使用 Build 6，保持原容器与 `Documents/Backups/<deviceID>` 路径，已有备份可继续读取。
- 云端备份写入结束不等于上传完成。通过 `NSMetadataQuery` 的初始/变更通知读取文件上传标记、进度与错误；状态读取在文件协调结束后进行。本地保存状态独立展示，账号变化或关闭云端备份会停止监听并忽略过期回调。
- 各平台沿用既有 Bundle ID、App Group、CloudKit 容器、iCloud 键值存储和钥匙串访问组。
- Mac 主应用、分享扩展分别使用 `ShikeMac.entitlements`、`ShikeMacShare.entitlements`，Mac 小组件使用 `MacWidget.entitlements`。
- Mac 小组件只读展示快照；无 CloudKit 或 API Key 权限。手表仍由配对 iPhone 传送数据，Mac 不启动 WatchConnectivity。
- 原文、问答和历史仍在各设备本地。设置及倒数日按已有开关同步；JSON 备份格式不变，不自动同步原文或恢复后重复写入日历。
- Mac 文件和拖放导入只读取用户选定的图片与纯文本；分享扩展复用 OCR、发送授权、核对及保存流程。
- `ShortcutImport.swift` 提供图片、文字两个 App Intent。图片先经 Vision OCR，文字逐条原子写入共享队列；启动后保存为固定编号的导入会话，再确认消费队列，避免冷启动或重复消费丢失内容。捷径本身不绕过模型发送授权和日历核对。
- `VoiceInput.swift` 使用 Speech 与 AVAudioEngine，申请权限后录音，停止或退出时释放麦克风。优先设备端识别；无设备端支持时由 Apple 处理。Mac 额外声明 audio-input 沙盒权限。
- 日历总结采用独立字段白名单，仅包含当前筛选范围的标题、起止时间、全天标记和地点；点击立即请求当前 API，不复用提取授权提示，也不发送备注或内部标识。格式与范围边界由核心测试覆盖。
- 小组件支持指定一到两个日子，优先于分组；沿用原 `countdown` 参数，新增可选 `secondCountdown`，避免丢失原选择。指定后保持槽位顺序，不按日期、正倒数或置顶排序；小号与锁屏第一个为主、第二个为辅，中大号平等展示。选择器提供稳定 UUID 标识的“留空”项，兼容旧配置的 `nil`；两项清空才恢复分组自动选择。去重后只显示仍存在的选择，全部删除时不自动回退到其他日子。锁屏样式复用相同筛选与深链。
- 分享插画共 21 张，目录、提示词和预览在 `artwork/countdown/`；实际 PNG 位于主应用资源目录。图片离线使用，不在分享时生成或联网。

## 验证

```sh
swift test --package-path Packages/ShikeCore
python3 scripts/release_preflight.py
xcodebuild -project Shike.xcodeproj -scheme ShikeMac \
  -destination 'platform=macOS,variant=Mac Catalyst' \
  -only-testing:ShikeUITests/PlatformWorkspaceUITests test
```

iPad / iPhone 测试用 `Shike` Scheme 和相应模拟器 destination。模拟器服务测试也需要保留默认的本地签名，以便验证钥匙串和 App Group；不要设置 `CODE_SIGNING_ALLOWED=NO` 来运行这组测试。EventKit 集成测试会申请日历权限，并创建、修改、删除专用测试日历。测试设备不要存放真实业务数据。

`PlatformWorkspaceUITests` 覆盖自适应页面、旋转时的原文和未保存编辑、Mac 快捷键与窗口缩放；`FileImportTests` 验证文件和 Finder 文件 URL、图片数量/大小限制及无效内容。小组件渲染测试含倒数日、正数日、空组、已删除分组和不可读快照。

`CalendarInteractionTests` 验证夏令时、只读与过期事件保护、真实 EventKit 重复事件单次移动及备注/提醒保留。`ShortcutAndArtworkTests` 验证原生截图 OCR 到捷径队列、重启恢复及 21 张插画资源与 PNG 导出。`NewFeatureUITests` 验证冷启动自动提取、总结复制、输入框内实时语音转写（含保留原文、停止与离开页面、不会自动提取）、设置中的使用技巧与卡片选图。UI 自动化使用模拟的分段转写结果，不启动麦克风；语音麦克风采集和系统快捷指令 App 的完整组合仍需在设备上验收。

全天日程测试同时覆盖 EventKit 返回的 23:59:59 结束时间、App 写入时全天标记保留，以及跨时区读回后保持原日期。模拟器上的 `CalendarInteractionUITests` 使用 `-native-calendar-testing` 走真实 EventKit，验证创建、系统编辑器删除和返回日历的完整链路；该开关不在真机和 Release 生效。系统编辑器漏发删除完成回调时，通过日历变化通知重新查询原事件的准确日期与标识，确认原事件已消失后关闭编辑页；取消编辑不触发该关闭路径。

Mac UI 测试需保持桌面解锁，并允许 Xcode 进行 UI 自动化。不要同时运行 Mac 和模拟器的 UI 测试，以免争用输入焦点。模型响应使用固定测试数据，不能将其描述为真实模型服务验证；本机测试也不能替代同一 Apple 账户下跨设备 iCloud 同步验收。

系统注册排查时，原生 Mac 小组件与 Catalyst 分享扩展需要使用不同平台查询：

```sh
pluginkit -m -A -D -v -i com.chandler.shike.macwidgets
pluginkit -m -A -D -v -P maccatalyst -i com.chandler.shike.share
```
