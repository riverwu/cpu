# CPU：大模型驱动的 macOS Computer Use 助手

只有一个输入框，以语音为主。按下快捷键直接说话，CPU 会读懂当前屏幕，替你在本机完成操作。

## 快速开始

```bash
scripts/bundle.sh --open        # 构建 release 版 build/CPU.app，签名并启动
```

首次启动时需要授权，都在 系统设置 → 隐私与安全性 中开启：
- **辅助功能**：读取界面、执行操作（必需）
- **屏幕录制**：截图和 OCR，用于微信这类自绘界面
- **麦克风** 和 **语音识别**：第一次说话时系统会弹窗

用法：
| 操作 | 效果 |
|---|---|
| 连按两次 `Fn`（卡片关着时） | 唤起并开始听；停顿约 1 秒自动提交 |
| 连按两次 `Fn`（卡片开着时） | 关闭卡片；任务进行中时只收起卡片，任务继续，完成后结果卡片自动回来 |
| 按住 `Fn`（卡片开着时） | 按住说话，松开提交 |
| 直接打字，回车提交 | 开始打字后语音自动停止 |
| `Esc` | 执行中按下立即停止（全局有效）；聆听中按下取消；其他情况关闭卡片 |

一张卡片就是一个任务：
- 标题是模型改写的目标，下面用人话列出每一步。
- 完成后显示结果和〔打开 应用〕按钮。
- 卡片开着时，再说话或输入就是**跟进**，从当前界面继续。
- 执行中按住 `Fn` 说话就是**插话**，模型下一步就会看到。
- 需要你时，卡片会变成问题、确认（带预览）或交还（比如请你登录）。
- 卡片保留到你主动关闭（`Fn Fn`、`Esc` 或 ✕）为止。

融入日常：
- 空闲卡片和菜单栏列出最近任务，点一下就重做；说"再做一次"也行。
- 完成的任务可以"存为快捷说法"（比如"日报"），以后说名字就执行。
- 把文件拖到卡片上作为附件。
- 同样的任务再做时，直接回放上次的步骤，只用一次模型调用核对结果。
- 可以在 `~/.config/cpu/hints/<bundle id>.md` 为某个应用补充操作提示。
- **看我做一遍**：示范一次操作，CPU 学成技能。之后说技能名就原样重做，说"用 X 给…"就换参数去做。
- 完成卡片上的〔撤销〕：引擎记录过的文字修改直接还原，其余修改由模型用 ⌘Z 或反向操作还原。

语音：
- 有 `DOUBAO_API_KEY`（或 `DOUBAO_APP_ID` + `DOUBAO_ACCESS_TOKEN`）时，用豆包流式识别和语音合成；否则用 Apple 本机识别和系统声音。
- 用语音下的任务，结果也会读出来。
- 用 `"voice": "apple"` 强制本机识别，用 `"speakReplies": "never"` 关闭朗读。
- `DOUBAO_TTS_VOICE` 可以换朗读的音色。

`Fn Fn` 需要辅助功能权限。如果系统设置里"按下 🌐 键时"绑定了功能，或者听写快捷键设为"按两下 🌐"，会和 `Fn Fn` 冲突。请在 系统设置 → 键盘 里改掉，或者在配置里把 `hotkey` 换成组合键（例如 `"ctrl+alt+space"`）。

产品设计（定位、交互模型、路线图）见 [docs/PRODUCT.md](docs/PRODUCT.md)。

模型配置写在 `~/.config/cpu/config.json`，首次启动时自动生成，可以只写需要改的字段：

```json
{
  "baseURL": "https://api.deepseek.com/anthropic",
  "model": "deepseek-flash",
  "apiKeyEnv": "DEEPSEEK_API_KEY",
  "hotkey": "fn fn"
}
```

其他可选字段（不写则用默认值）：`effort`（"low"）、`vision`、`screenshots`（"auto"/"always"/"never"）、`locale`（"zh-CN"）、`voice`（"auto"/"doubao"/"apple"）、`speakReplies`（"voice"/"always"/"never"）、`listenAfterResult`（false；语音任务完成后自动再听 8 秒，安静环境可打开）、`maxSteps`（30）、`stallTimeout`（20 秒）、`blockedApps` 等，完整列表见 `Sources/CPUCore/Agent/Config.swift`。

API Key 从 `apiKeyEnv` 指定的环境变量读取。从 Finder 启动的 App 拿不到 `~/.zshrc` 里的变量，这时会从登录 shell 补读，所以 Key 不需要写进文件。任何兼容 Anthropic Messages 协议的端点都可以用，例如 DeepSeek、MiniMax、Kimi、Claude。

## 架构

```
Sources/
  CPUCore/Computer/   本机操作引擎（Swift，进程内，移植自 ~/LocalDev/computer-use）
    Accessibility     AX 树 → 带索引的大纲 "[12] button "发送" (disabled)"
    Input             后台优先的点击/输入/按键；必要时短暂切到前台再操作
    Capture           ScreenCaptureKit 窗口截图
    TextRecognition   Vision OCR（本机）：AX 信息太少时，把屏幕文字变成可点击坐标
    BackgroundInput   不抢前台的后台点击、菜单快捷键、粘贴；借用前台的规矩
    Demonstration     示范录制：把用户的点击、按键、输入记成带文字标签的步骤
  CPUCore/Voice/      语音
    Transcriber       识别后端：豆包流式、Apple SpeechAnalyzer、Apple SFSpeech
    DoubaoSpeech      豆包二进制帧协议（识别）、流式合成与播放（Speaker）
    Settle            监听 AX 通知判断"界面已稳定"，不再固定 sleep
    Computer          对外 API：observe / runBatch / open / launch
  CPUCore/Agent/      模型循环
    AnthropicClient   原生 SSE 流式客户端（Swift 没有官方 SDK）
    Prompt            系统提示词 + 5 个工具：act / open / observe / windows / ask_user
    Agent             主循环、快速通道、上下文裁剪、动作翻译
  CPUApp/             悬浮面板（SwiftUI）、语音（SFSpeech）、全局热键（Carbon）
  cpuctl/             开发用命令行：windows / observe / run / config
```

跟参考项目相比的主要改动：参考项目是 Node 客户端 + Swift helper，通过 JSON-lines 进程通信，服务于 LobsterAI 的 MCP bridge。这里把引擎直接放进 App 进程，模型循环也自己写，因此可以做下面这些针对速度的优化。

## 速度与准确率的设计

| 手段 | 效果 |
|---|---|
| **以 AX 文本为主**：只在需要时才截图（`screenshots: auto`） | 每步输入从几千个图像 token 降到几百个文本 token，首 token 更快 |
| **`act` 批量执行**：一次调用里依次点击、输入、回车 | 7×8 这个例子里 5 次点击只用 1 次模型调用 |
| **动作后自动观察**，并自动跟随新弹出的窗口或应用 | 每步省掉一次单独的 observe 往返 |
| **AX 通知判断稳定**（安静 180ms 即返回，最长 2s） | 不用固定等待，快的界面约 0.15s 就能返回 |
| **说话时就预取**：观察前台窗口，预热 TLS | 首次模型调用不用等观察完成 |
| **提示词缓存**：tools + system 断点，加滚动断点；JSON key 排序 | 实测第 2 步起约 85% 的输入命中缓存 |
| **旧观察结果替换为占位符**（只保留最近 2 个） | 上下文不随步数膨胀，旧截图也一起清掉 |
| **快速通道**：「打开微信」这类精确应用名不调用模型 | 约 0.3s 完成 |
| `effort: low` + deepseek-flash | 每步约 1s |
| **元素索引优先于坐标**；AX 稀疏时用 OCR 给出文字坐标 | 不靠模型猜像素，点得准 |
| **大纲显示只读控件的值**（修复了参考实现漏掉的 static text value） | 能直接读出计算器结果之类的数值，不用再截图核对 |
| **OCR**：Apple Vision 本机识别；在原始分辨率上识别（比降采样多识别出小字，耗时几乎不变）；启动时后台预热（首次加载最长约 13 秒）；对已知 AX 稀疏的应用，OCR 与 AX 读取并行；`target` 命中长行中的几个字时，点击那几个字的位置而不是整行中心 | 微信这类自绘界面也能准确定位 |
| **索引 + 文字双重核对**：动作带上 `target`（元素文字），执行前由引擎核对 | 模型对错索引时自动纠正或拒绝执行，不会点错；只给 `target` 也能按文字或 OCR 文字定位 |
| **和用户共享这台电脑**：后台坐标点击（只发给目标进程，窗口被挡住也能点）、⌘ 快捷键走菜单、在后台打开应用；必须借用前台时先等用户停手，用完把前台还回去 | 用户照常工作，CPU 不抢鼠标、不抢前台（见 docs/PRODUCT.md §4.8） |
| **遮挡由引擎自动处理**：置前目标窗口（AXFrontmost）→ 关闭菜单 → 挪开浮动窗口 → 移开目标窗口 | 不会卡在"被遮挡"上；挪动过的窗口在任务结束后复原 |
| **对话框层级**：窗口列表包含应用级模态对话框（存储/打开面板、警告框，它们处在更高的窗口层级）；表单标明挂在哪个窗口上；观察被对话框挡住的窗口时，自动改为观察最前面的对话框（嵌套表单取最里层）；点击被挡住窗口里的元素会被拒绝 | 打印预览和保存面板都有"保存"时不会点错层，也不会看不见保存面板 |
| **终端默认不碰**：用户没提到终端时，不观察、不操作终端类应用（终端、iTerm、Warp、Ghostty 等），前台是终端时也不把它的内容作为上下文 | 不会在用户的 shell 里执行命令，不会把终端历史发给模型 |

实测（deepseek-flash，effort low）：

```
cpuctl run "用计算器算 99 乘以 99"   → 2 次模型调用，3.0s（计算器已在前台）
面板里输入 "用计算器算 7 乘以 8"      → 3 次模型调用，4.6s（含打开计算器）
cpuctl observe（邮件，181 个元素）    → 0.5s；访达 0.1s；计算器 0.04s
```

## 开发

```bash
swift build
.build/debug/cpuctl config                       # 查看生效的配置，不显示密钥
.build/debug/cpuctl windows
.build/debug/cpuctl observe [窗口id] [--shot]
.build/debug/cpuctl run "打开备忘录新建一条：明天买牛奶"
.build/debug/cpuctl run "用计算器算 12 乘以 12 ++ 结果再乘以 3"   # " ++ " 后面是跟进
.build/debug/cpuctl click <窗口id> <x> <y>         # 按窗口坐标点击（含遮挡处理），用于测试引擎
.build/debug/cpuctl act <窗口id> '[{"do":"click","target":"文件格式"},{"do":"click","target":"PDF"}]'   # 按模型的方式执行一次 act（不调用模型），看每步做了什么
.build/debug/cpuctl act <窗口id> '[{"do":"menu","path":"格式 ▸ 字体"}]'   # 列出或选择菜单栏命令
.build/debug/cpuctl read <窗口id|网址>              # 读窗口全文，或在后台打开网页并读全文
scripts/runstats.py [N]                          # 最近 N 次运行的耗时、步数、报错、思考字数汇总
.build/debug/cpuctl code shell 'cpu page https://example.com --png a.png'   # 按 code 工具的方式运行代码（含风险分档），打印返回给模型的报告
.build/debug/cpuctl --cpu-helper help             # 能力库 cpu 的命令（脚本里直接用 cpu …）
.build/debug/cpuctl run --no-context "…"          # 不发送窗口标题和屏幕内容，测试只用代码的任务
.build/debug/CPUApp --render-card reply.md out.png [expanded] [docked] [session]   # 离屏渲染完成状态的卡片（session：前面还有一轮）
.build/debug/CPUApp --render-history reply.md out.png              # 离屏渲染历史窗口（示例数据）
.build/debug/cpuctl speech-bench a.aiff b.aiff      # 按真实语速对比各个语音识别引擎
.build/debug/cpuctl say "已算好"                    # 测试朗读，报告多久开始出声
.build/debug/cpuctl demo-test 七乘八                # 用脚本在计算器上模拟一次示范，学成技能
.build/debug/CPUApp --show                       # 不打包直接打开面板（沿用终端的权限）
scripts/test.sh                                  # 单元测试（Swift Testing；绕过 CLT 的宏插件问题）
```

`cpuctl` 会自动跳过运行它的终端窗口。它使用的是终端的系统权限，与 CPU.app 的权限相互独立。

## 已知限制与下一步

- **微信、POPO、微信读书这类自绘界面**：AX 只有几个元素，要靠截图 + OCR + 坐标点击，需要屏幕录制权限。这部分还没有实测，是下一阶段的重点。可以考虑在截图上叠加元素编号（Set-of-Marks），并给常用应用写快捷键提示（比如微信 `cmd+f` 搜索联系人）。
- **流式提前执行**：现在要等模型输出完整的 tool_use 才开始执行。可以改成解析出第一个 action 就立刻执行。
- **轨迹缓存**：把成功的动作序列按"应用 + 意图"缓存下来，下次直接回放并校验，命中时可以完全跳过模型。
- **多轮对话**：现在每次请求都是新会话，"再发一遍"这类追问暂不支持。
- **语音**：目前用 SFSpeechRecognizer（在设备上识别）。macOS 26 以后可以换成 SpeechAnalyzer，延迟更低；也可以加上 TTS 朗读结果。
- 执行期间面板对鼠标透明，不会挡住真实点击；停止只能用 `Esc`（会立即取消正在进行的模型请求）。

## 排查问题

- 每次任务的完整轨迹在 `~/Library/Logs/CPU/runs/<时间>.md`：权限状态、每步的模型思考和工具调用、界面观察、截图、耗时，保留 7 天。内容包含屏幕信息，只存在本机。
- App 的诊断日志在 `~/Library/Logs/CPU/cpu.log`。
- 模型请求 `stallTimeout`（默认 20 秒）内没有任何新内容会中断并重试，最多重试 2 次；网络错误也会重试。
