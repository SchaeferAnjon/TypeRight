# Type Learn（工作名）产品说明

2026-11-08 和用户讨论后定下。界面以 designer 出稿、用户挑过的为准。

## 要解决的问题

用户想用英文打字，但怕拼写、语法出错，最后还是改打中文。对用户来说，能纠正拼写和语法本身就是鼓励。

## 使用的感觉（用户已确认）

在任何 App 里正常打英文，下面三种时刻各主动弹一次框，不用自己去点下划线：

| 你打到 | 弹出的框 | 你做什么 |
|---|---|---|
| `I want to 预约`（不会说，打了中文） | 预约 → **book** /bʊk/，小喇叭能听发音 | Tab，`预约` 变成 `book` |
| `a meeting room tomorow`（打完这个词） | tomorow → **tomorrow** | Tab 改掉；不理它接着打，框自己消失 |
| `because I has a question.`（一句打完） | 整句改好的版本，改动处高亮，加一句中文讲解：主语是 I，用 have 不用 has | Tab 整句替换 |

## 规则（初定，用下来再调）

- 框不抢键盘：Tab 接受，Esc 关，接着打就消失。
- 拼写：一个词打完就查，在本机查，不用等。
- 中文变英文：中英混打时停顿就自动提示；整句都是中文时按快捷键才翻，免得和朋友用中文聊天时乱弹。英文状态下打拼音（`yuyue`）也能认出来。结果带音标和发音。
- 语法：一句打完时查整句，改动处高亮，配一句中文讲解。
- 被改的地方记进错题本，从中文翻过来的词记进生词本；同一个点正确用 3 次算掌握。

## 技术路线

- 底子：fork [TextWarden](https://github.com/PhilipSchmid/textwarden)（Apache-2.0，Swift，macOS 14+）。它已经做好：用辅助功能读写各 App 的输入框、每个 App 单独适配、算出词在屏幕上的位置、用 Harper 在本机检查拼写和语法。
- 新增：弹框（它原本是下划线加浮标）、AI 层（用 GetNewWord 现成的多家服务商和钥匙串）、中文和拼音变英文、中文讲解、错题本、音标（CMU 发音词典）、发音（用 GetNewWord 的 AudioService）。
- 协议：TextWarden 的 Apache-2.0 代码和 GetNewWord 的 GPL-3.0 代码合在一起，整个 App 按 GPL-3.0 开源，保留 TextWarden 的 NOTICE。
- 用户的 Mac 是 macOS 15.8，所以不能依赖 Apple Intelligence（要 macOS 26）。

## 调研：GitHub 上的同类项目（2026-11-08）

| 项目 | 协议 | 做什么 | 可以拿来用的 |
|---|---|---|---|
| [TextWarden](https://github.com/PhilipSchmid/textwarden) | Apache-2.0 | 最接近开源版 Grammarly：实时下划线、每个 App 单独适配，982 次提交 | 当底子 |
| [Parrot](https://github.com/thousandflowers/Parrot) | MIT | 选中文字按快捷键，弹出改动对比，回车写回；引擎分四层（规则 → LanguageTool → Harper → 本地模型） | 改动对比面板、分层引擎 |
| [Harper](https://github.com/Automattic/harper) | Apache-2.0 | 离线英文语法检查引擎，毫秒级出结果 | TextWarden 已经内置 |
| [hallelujahIM](https://github.com/dongyuwei/hallelujahIM) | GPL-3.0 | 英文输入法：按发音拼也能出对的词，打拼音出英文，候选栏带音标和中文意思 | 读音相近的纠错、拼音变英文、CMU 发音词典转 IPA 的数据 |
| [GSpot](https://github.com/Blueturboguy07/gspot) | AGPL-3.0 | 界面像 Grammarly 的侧边栏；附一篇拆解 Grammarly 桌面版的文档 | 只参考思路，不搬代码 |
| [Writing Tools](https://github.com/theJayTea/WritingTools) | GPL-3.0 | 按快捷键让 AI 校对或改写，直接替换 | 自定义指令的做法 |
| [Plumb](https://github.com/nagavineerpasam/plumb) | Apache-2.0 | 只标出错处、不替你改，正确率分数，进步曲线 | 进步曲线 |
| [prompt-language-coach](https://github.com/leeguooooo/prompt-language-coach) | README 写 MIT | Claude Code 插件：原文 / 纠正 / 更自然 / 关键点；生词正确用 3 次算掌握 | 错题本的掌握规则 |
| [TabType](https://github.com/nilava/TabType)、[Pretype](https://github.com/nikiomori/Pretype) | MIT | 在所有 App 里用灰字提示下一个词，按 Tab 接受 | 全局截获 Tab 的做法 |
| [Glint](https://github.com/jsogn/Glint)、[Monkey](https://github.com/jiaqianjing/monkey) | MIT | 打中文时显示或预览英文 | 中文变英文的交互 |

## 后来定的（2026-11-08）

- 名字 **TypeRight**，独立 App，有自己的官网和会员，官网和付费全面对照 MeetCaption，见 `docs/LAUNCH.md`。
- 界面用方向 A「贴词小卡」，见根目录的 `DESIGN.md`。
- 测试范围：微信、浏览器、给 Agent 打提示词的地方（Orca、终端）、邮件、备忘录、文档，都要测一遍。
