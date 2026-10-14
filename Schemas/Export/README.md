# 拾刻 JSON 导出 v1

入口：设置 → iCloud 同步下方的「数据与备份」→ 导出 JSON 文件。使用系统文件选择器保存 `Shike_Export_yyyyMMdd_HHmmss.json`，也可选择 iCloud Drive。该操作与应用内同步开关无关；文件包含个人原文、备注和问答，请自行保管。

- [JSON Schema 2020-12](shike-export-v1.schema.json)
- [真实导出器生成的虚构数据示例](example-v1.json)
- 编码为 UTF-8，键名使用稳定的英文标识，格式标识 `shike-export`，`schemaVersion` 为整数 `1`。
- 时间戳使用 RFC 3339 UTC（如 `2026-10-13T16:00:00Z`）；纯日期使用 `YYYY-MM-DD`。缺省的可选值省略字段，不用空字符串冒充日期。
- 导出从主线程取得一个一致快照，全部编码成功后才打开系统保存界面。任何读取或编码失败都不会生成部分“成功”文件。
- 支持拾刻 JSON 备份恢复；完整校验后预览，导入前自动备份当前数据。按记录 ID 合并，不覆盖本机同 ID 内容；同名分组复用。
- 可选择恢复普通设置。已存在接口及其 Key 保留，新增接口需补充 Key；iCloud 开关仍使用本机值。
- 已保存日程恢复为未勾选、待核对的历史记录，不自动重建系统日历事件。图片和 API Key 不在备份中。
- 自动备份保留最近 30 份本地副本，可镜像到 iCloud Drive 的拾刻 / Backups / 设备目录；云端也按设备保留 30 份。
- 不解析 Days Matter 的加密 `.idmbaks`。

## 顶层字段

| 字段 | 内容 |
| --- | --- |
| `format` / `schemaVersion` | 固定格式名和版本；消费者遇到未知主版本应拒绝静默解析 |
| `exportedAt` / `app` | 导出时间、应用名称、版本、构建号 |
| `preferences` | 统一 iCloud 开关、类别路由、默认和分类目标日历、当前接口 ID、日历显示偏好 |
| `apiProfiles` | 已保存接口的 ID、名称、格式、地址、模型。URL 中的用户信息、查询串和片段被去除 |
| `prompts` | `extraction` 和 `planning` 分别含 `isCustom` 与实际生效的 `text`，包含默认提示词 |
| `countdowns` | 倒数日当前有效记录；不含已删除的同步墓碑 |
| `countdownCategories` | 分类 UUID 和名称；删除分类后对应条目导出为未分类 |
| `importSessions` | 本地原文、来源、参考时区、草稿、保存状态与安排问答 |

## 倒数日

`id` 是稳定 UUID；`anchorDate` 始终表示最初日期的**公历民用日期**，与 `calendar` 字段组合解释重复规则。`calendar` 为 `chinese` 时，`lunarDate` 明确提供 `month`、`day`、`isLeapMonth`，用于跨语言消费。农历年以原始公历锚点确定，避免把六十年循环中的年序号误当作公历年份。

`recurrence.frequency` 为 `none / weekly / monthly / yearly`。`missingDatePolicy=clampToLastDay` 表示公历月末、2 月 29 日或农历三十不存在时取该月最后一天；`missingLeapMonthPolicy=ordinaryMonth` 表示某年没有指定闰月时取同名普通月。下一次发生日期是计算结果，不覆盖 `anchorDate`。

`timeZoneIdentifier` 缺省表示跟随系统；指定时为 IANA 时区名称。日历全天区域按对应民用日期展示，不因时差移到前一天。`categoryID` 引用分类 UUID，可省略；`notes`、`pinned` 分别为备注和置顶。

`reminder.daysBefore` 是 `[0,1,3,7]` 的任意不重复子集，空数组表示未选择提前提醒。`hour`、`minute` 为该倒数日时区下的提醒时刻。系统通知授权、排队状态不导出；设备根据自己的权限独立安排提醒。

`targetTime` 可选，格式为 `{hour, minute, second}`，省略表示日精度。它是倒数日时区的当地时间，不是 UTC 时间。秒精度显示实际时长；夏令时空缺向后顺延并保留分秒，重复时刻取第一次。

`includesStartDay` 表示正数日自然日计数是否将起始日期算作第 1 天，默认 false。`reminder.milestoneDays` 为可选的不重复正整数数组（1–100000，最多 60 个），例如 `[520,1314]`；不受周期重复重置。包含起始日时提醒在原始日期后 N−1 天，否则在 N 天。

`reminder.anniversaries` 为可选布尔值，缺省关闭；开启后按条目所选公历或农历，每满一周年提醒，不改变 `recurrence`，也不因包含起始日而提前。`reminder.dayInterval` 为可选整数（1–100000），例如 100 表示每到第 100、200、300…天提醒；缺省关闭。整数日遵循包含起始日规则。四类提醒均未开启时才是关闭提醒；同一条目同一时刻重合的提醒合并为一条。

`preferences.calendar.countdownLayout` 为 `single / double / strip`，缺省使用 `single`。上述可选字段缺失时使用默认值，以便读取早期 v1 输出。本版本新增字段不改变现有字段的含义。

## 草稿与问答

`importSessions[].drafts[]` 包含标题、类别、起止时间、全天标记、时区、地点、备注、原文依据、提醒分钟、用户选择、核对建议、`saved` 和 `saveInterrupted`。

目标和建议日历只导出可解析的 `{title, account}`，无法从当前授权日历中解析时省略，不输出 EventKit 标识。历史记录里的日期与时间不会被重新解释。`planning` 包括目标、时间范围、轮次 ID/角色/文字/选项和方案状态，保留多行及 Unicode 内容。

## 明确排除

API Key、Keychain 凭据 ID、模型发送授权、CloudKit 账户标识/同步令牌/版本元数据、暂存图片及路径、EventKit 事件和日历内部 ID、临时错误日志和调试开关。原文中用户自行写入的信息仍作为原文导出，并不自动脱敏。

## 验证

```sh
python3 -m venv /tmp/shike-export-validation
/tmp/shike-export-validation/bin/pip install 'jsonschema>=4.18,<5'
/tmp/shike-export-validation/bin/python scripts/validate_export.py Schemas/Export/example-v1.json
```

验证器使用 Draft 2020-12，验证日期格式、记录 ID 唯一性及分类/当前接口引用；失败只报告字段路径，不打印个人字段内容。核心测试另用哨兵值验证凭据、图片路径和系统内部标识不会进入 JSON。
