<h1 align="center">TypeRight</h1>

<p align="center"><b>Mac 菜单栏上的英文打字助手：拼错一个词、不会说先打了中文、一句打完语法不对，它在那个词旁边弹一张小卡，按 Tab 改好，按 Esc 不改。</b></p>

<p align="center">
<a href="https://github.com/SchaeferAnjon/TypeRight/releases/latest"><b>下载 Mac 版</b></a> · Apple 芯片和 Intel 通用 · macOS 14 以上 · <a href="https://typeright.us-cloud.uk">官网</a> · <a href="#english">English</a>
</p>

<p align="center">
<a href="https://github.com/SchaeferAnjon/TypeRight/releases/latest"><img src="https://img.shields.io/github/v/release/SchaeferAnjon/TypeRight?label=latest&color=1d1d1f" alt="最新版本"></a>
<a href="LICENSE"><img src="https://img.shields.io/badge/license-GPL--3.0--or--later-1d1d1f" alt="GPL-3.0-or-later"></a>
<img src="https://img.shields.io/badge/macOS-14%2B-1d1d1f" alt="macOS 14+">
</p>

<!-- 截图：首屏放一张小卡在真 App 里弹出来的截图（中文变英文那张），发版前补上 -->

## 它做什么

在任何 App 里照常打英文，下面三种时刻它自己弹一张小卡，不用去点下划线：

| 你打到 | 小卡里 | 你做什么 |
|---|---|---|
| `I want to 预约`（不会说，先打了中文；英文状态下打拼音 `yuyue` 也认得） | 预约 → **book** /bʊk/，点喇叭能听发音 | Tab，`预约` 换成 `book` |
| `a meeting room tomorow`（拼错一个词） | tomorow → **tomorrow** | Tab 改好；不理它接着打，卡自己让开 |
| `because I has a question.`（一句打完） | 整句改好的版本，改动处标出来，加一句讲解：主语是 I，用 have | Tab 整句换掉 |

- 拼写和几类常见语法错在你的 Mac 上用开源的 [Harper](https://github.com/Automattic/harper) 查，不联网，不算次数。查的是这几类：代词作主语时的主谓一致（I has、he don't、they was）、a / an、did 和 have 后面的动词形式（didn't went、have went）、more taller 这类多余的 more / most、advices 这类不可数名词加了 s、could of、discuss about、its / it's、their / they're。没开 AI 时一句打完，查到这几类就弹一张写着「本机查」的整句卡，Tab 跟着打，Esc 不改。
- 中文变英文和整句检查要用 AI，用法见下面「三种用法」。
- 讲解默认用简体中文，设置里能换成繁體中文、English、日本語、한국어、Deutsch、Français、Español、Italiano。
- 你按 Tab 接受的改法记进错题本，从中文变来的词记进生词本，同一个点用对 3 次算会了；主窗口的「进步」看最近 14 天。
- 能用的地方：微信、浏览器、邮件、备忘录、文档、给 AI 写提示词的地方。每个 App 一个开关，终端默认关着；菜单栏里能在当前 App 暂停，或全部暂停 1 小时。

<!-- 截图：菜单栏菜单、主窗口「今天」、设置「AI 服务商」各一张，发版前补上 -->

## 下载安装

1. 从 [GitHub Releases](https://github.com/SchaeferAnjon/TypeRight/releases/latest) 下载 `TypeRight-<版本>-Universal.dmg`，把 TypeRight 拖进「应用程序」，打开。
2. 第一次打开如果提示无法验证开发者：打开「系统设置 › 隐私与安全性」，拉到最下面，点「仍要打开」。
3. 跟着引导给「辅助功能」权限：TypeRight 要靠它读到你正在打的那一句，并在你按 Tab 时把改法写回去。
4. 选一种用法，然后回到任何 App 打一句英文试试。

更新：设置 › 高级 › 关于，点「检查更新」，或打开「打开时自动检查更新」。

## 三种用法

| | 怎么开始 | 花多少 |
|---|---|---|
| **只用本机检查** | 设置里把用法选成「只用本机检查」 | 免费。只查拼写和几类常见语法错，什么都不发出去；没有中文变英文和 AI 整句检查 |
| **自带 Key** | 在「设置 › AI 服务商」里点一家，粘贴你的 API Key（[5 分钟图文教程](https://typeright.us-cloud.uk/#page=guide)） | 永久免费，不限次数；服务商按用量向你自己的账户收费，用 DeepSeek 查一句约 0.003 元 |
| **会员** | 不用申请 Key：在「设置 › 账号与会员」里开会员，浏览器打开 Stripe 付款页，付完回到应用就生效 | 每月 ¥9.9 / $1.99，或每年 ¥99 / $19.9，Stripe 自动续费，随时取消；人民币也能用微信一次买 1 个月或 1 年，不自动续费。每天 500 次 AI 检查（一个用到 AI 的小卡算一次），按 UTC 日期重置；一个授权码最多 2 台 Mac |

<!-- 会员这一行按上线时的「账号与会员」界面核对，见 docs/RELEASE.md -->

自带 Key 能选 DeepSeek、智谱 GLM、通义千问、Kimi、豆包、OpenAI、Gemini、Claude、OpenRouter，或任何兼容 OpenAI 的接口（「自定义」）。每家的 Key 分开存在 macOS 的钥匙串里。

## 隐私

拼写和几类常见语法错在你的 Mac 上查，不联网；用到 AI 时只发你正在打的这一句：自带 Key 时直接发给你选的服务商，会员时经我们的服务器转给 DeepSeek，服务器不存你打的字。系统标成密码的输入框不读，密码管理器和钥匙串访问整个不看。全文见[隐私政策](https://typeright.us-cloud.uk/#page=privacy)。

## 从源码编译

需要 Xcode 26 或更新、用 [rustup](https://rustup.rs/) 装的 Rust，以及两种芯片的 Rust 目标：

```bash
rustup target add x86_64-apple-darwin aarch64-apple-darwin
make build      # 先编 Rust 的语法引擎（GrammarEngine），再用 Xcode 编 App
make run        # 编好、换掉 /Applications/TypeRight.app、重新打开
make test       # Rust 和 Swift 的单元测试
```

Xcode 工程和 scheme 还叫 TextWarden，编出来的是 `TypeRight.app`。工程用的是作者的开发者团队签名；自己编时在 Xcode 的 Signing & Capabilities 里换成你的 Team，或者不签名：`xcodebuild -project TextWarden.xcodeproj -scheme TextWarden -configuration Release CODE_SIGNING_ALLOWED=NO build`。更多细节见 [BUILD.md](BUILD.md)（沿用 TextWarden 的英文文档）。

## 许可证和致谢

TypeRight 按 [GPL-3.0](LICENSE)（或更高版本）开源。

TypeRight 的底子是 Philip Schmid 的 [TextWarden](https://github.com/PhilipSchmid/textwarden)，按 Apache-2.0 发布，许可全文保留在 [LICENSES/Apache-2.0-TextWarden.txt](LICENSES/Apache-2.0-TextWarden.txt)，改了哪些见 [NOTICE](NOTICE)。谢谢 TextWarden 做好了最难的部分：用辅助功能在各个 App 里读写文字、为每个 App 单独适配、算出每个词在屏幕上的位置。TextWarden 的名字和标志归它的作者，TypeRight 和 TextWarden 项目没有关联。

拼写和语法检查用的是 Automattic 的 [Harper](https://github.com/Automattic/harper)（Apache-2.0），自动更新用的是 [Sparkle](https://sparkle-project.org)（MIT）。

---

<h2 id="english">English</h2>

TypeRight is an English typing assistant in the Mac menu bar. Misspell a word, type Chinese (or pinyin) where you don't know the English word, or finish a sentence with a grammar mistake, and a small card pops up next to the word. Press Tab to take the fix, Esc to leave it. Explanations are in Simplified Chinese by default and can be switched to eight other languages.

- **Download**: [GitHub Releases](https://github.com/SchaeferAnjon/TypeRight/releases/latest), one DMG for Apple silicon and Intel, macOS 14 or later. If macOS says it cannot verify the developer the first time, open System Settings › Privacy & Security and click Open Anyway. TypeRight needs the Accessibility permission to read the sentence you are typing and write the fix back.
- **Three ways to use it**: on your Mac only (free, spelling and basic grammar, nothing leaves the Mac); your own AI key (free, the provider bills you directly); or membership ($1.99 a month or $19.90 a year, 500 AI checks a day, through Stripe).
- **Privacy**: spelling and basic grammar are checked on your Mac with [Harper](https://github.com/Automattic/harper). AI features send only the sentence you are typing, straight to your provider with your own key, or through our server to DeepSeek for members; the server does not keep what you typed. Password fields are never read.
- **Build from source**: Xcode 26, Rust with the `x86_64-apple-darwin` and `aarch64-apple-darwin` targets, then `make build`. Set your own signing team in Xcode, or build with `CODE_SIGNING_ALLOWED=NO`.
- **License**: GPL-3.0-or-later. Based on [TextWarden](https://github.com/PhilipSchmid/textwarden) by Philip Schmid (Apache-2.0, kept in [LICENSES/](LICENSES/) with a [NOTICE](NOTICE)). TypeRight is not affiliated with or endorsed by the TextWarden project.
