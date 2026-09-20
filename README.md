# 🐋 DeepSeek 小鲸鱼挂件 · macOS 桌面版

把 [DSH 小鲸鱼记账挂件](https://github.com/MeteorNOX/DeepSeek-Balance-Whale-Widget) 移植成**原生 macOS 桌面挂件**：
不依赖浏览器、不依赖 DSH，直接浮在桌面上，常驻显示 DeepSeek API 余额、今日已用与峰谷时段。

用 Swift + AppKit + SwiftUI 重写，无 Electron、无 WebView —— 一个 2 MB 出头的原生 `.app`。

```
┌──────────────────────────┐
│   ╭───────────────╮      │   气泡：余额 / 今日已用 / 峰谷（可完全自定义）
│   │   余  额      │      │
│   │  ¥ 13.55      │      │
│   │ 今日已用 0.28 │      │
│   ╰──────────╯   │      │
│            ╭──╮  │      │
│         🐋 ─╯ ╰  │      │   小鲸鱼：拖拽 / 四边吸附 / 点击 Q 弹
└──────────────────────────┘
```

## 快速开始

```bash
# 1) 编译 + 打包成 .app
./Scripts/package_app.sh release

# 2) 运行
open dist/WhaleWidget.app
```

也可以开发期直接跑：

```bash
swift run WhaleWidget
```

### 密钥

**开箱即用**：如果本机装过 DSH 插件，会自动读取 `~/.dsh/.credentials.yaml` 里的 `DEEPSEEK_API_KEY`，无需任何配置。
否则按优先级依次尝试：

| 顺序 | 来源 | 说明 |
|---|---|---|
| 1 | 挂件配置 | 菜单 → API 密钥 → 修改密钥（存于 `~/.whale-widget-mac/config.json`） |
| 2 | 钥匙串 | `security add-generic-password -s WhaleWidget -a DEEPSEEK_API_KEY -w <key>` |
| 3 | DSH 凭据库 | `~/.dsh/.credentials.yaml` 的 `refs:` 区段 |
| 4 | 环境变量 | `DEEPSEEK_API_KEY` |

### 权限

挂件窗口是 `.floating` 层级的无边框窗口，会出现在所有桌面空间（含全屏应用之上）。
本应用为 `LSUIElement`（不进 Dock、不抢焦点），入口在**菜单栏的 🐋 图标**。

### 怎么操作

| 操作 | 结果 |
|---|---|
| **点击小鲸鱼** | 显示余额气泡（第 1 次出「首次点击泡」，再点依次出队列内容，最后再点收起） |
| **移动到小鲸鱼上** | 右上角的 ☰ 菜单按钮淡入（**默认隐藏**，离开可交互区域即隐去） |
| **点击 ☰ 按钮** | 弹出菜单（大小 / 音效 / 提醒 / 密钥 / 各设置窗口） |
| **拖动小鲸鱼** | 移动挂件；松手靠近屏幕边缘时自动吸附 |
| **右键小鲸鱼** | 唤出菜单（菜单按钮被禁用时的备用入口） |
| **锁定** | 整个挂件不再响应鼠标（点击穿透到桌面）；解锁走菜单栏 🐋 → 「解锁挂件」 |
| **不透明度** | 菜单里的滑块，20%–100% 实时生效，不影响可点击性 |
| **菜单栏 🐋 图标** | 显示/隐藏挂件、立即刷新、解锁挂件、设置、退出 |

> **可交互区域 = 只有小鲸鱼本体**：命中判定按角色图的 alpha 通道逐像素烘焙，
> 所以既不是规则矩形，也不包含气泡 —— 气泡是纯展示，点它不推进序列。
> 小鲸鱼与菜单按钮之外的**所有**像素（含气泡、透明区域）都 click-through 到桌面：
> 窗口在这些位置会把 `ignoresMouseEvents` 置为 true，事件直接落到下层窗口。

## 与参考实现的功能对照

| 功能 | 状态 | 说明 |
|---|---|---|
| 余额显示 + 60 秒自动刷新 | ✅ | 点击小鲸鱼手动刷新；余额变化时数字滚动动画 |
| 瞬时网络抖动沿用最近余额 | ✅ | 不弹错误，只在菜单里显示一行温和提示 |
| 今日已用（余额下降累计） | ✅ | 无需任何令牌 |
| 充值不冲抵消费 + 待核对提示 | ✅ | 与参考实现同一套观测账本语义 |
| 余额校正 | ✅ | 按「期初 + 累计到账 − 期末」重算 |
| 峰谷定价 | ✅ | 工作日（周一至周五且非法定节假日）9–12 / 14–18 高峰；周末与法定节假日全天谷价；带峰谷倒计时 |
| 模型单价表 | ✅ | Flash / Pro + 旧模型名，未知模型回退 Flash 价 |
| 定点金额（8 位小数） | ✅ | 精确到 1e-8，`0.1 + 0.2 == 0.3` |
| 拖拽 + 四边吸附 | ✅ | 指针事件由原生 AppKit 处理，位移严格等于鼠标位移（不用视图坐标系，避免抖动与误判） |
| 贴左吸附水平镜像 | ✅ | 整机翻转，文字同步反向 |
| 点击 Q 弹效果 | ✅ | 点击时压扁 → 回弹（改由 mouseUp 驱动，不再依赖按下状态） |
| 点击序列泡泡 | ✅ | 点击小鲸鱼：首次出「首次点击泡」，再点依次出队列，最后再点收起 |
| 点按角色推进队列 | ✅ | 可开关；关闭时点小鲸鱼为纯开合 |
| 菜单入口 | ✅ | 点右上角 ☰ 按钮弹菜单（右键也可）；点本体只出余额气泡 |
| 菜单按钮默认隐藏 | ✅ | 鼠标进入可交互区域才淡入，离开即隐去（右键仍可唤出） |
| 可交互区域 = 仅小鲸鱼本体 | ✅ | 按角色图 alpha 逐像素烘焙；气泡与透明区域一律 click-through 到桌面 |
| 气泡非可交互 | ✅ | 气泡是纯展示，点它不推进序列（推进只由点小鲸鱼触发） |
| 模块化泡泡内容 | ✅ | 文本 / 链接 / 随机语句 / 图片 / 随机图片 / 余额 / 今日 / 峰谷 / 消耗金额 |
| 文字不溢出气泡 | ✅ | 文字区按泡泡几何内缩（避开描边），并用 `ViewThatFits` 逐档降字号 |
| 逐模块样式 | ✅ | 字号 50 档、粗斜下划线、纯色或跑马灯渐变、底色 |
| 随机语句不连续重复 | ✅ | 带权重抽取，避免连续抽到同一条 |
| 图片模块独占一行 | ✅ | 每行最多 6 个模块、最多 6 行、每泡泡一个图片 |
| 模块库 | ✅ | 常用模块存库后复用 |
| 泡泡图库 + 自定义图片导入 | ✅ | 内置 petpet / money1 / rua，可导入 png/gif |
| 余额预警 / 今日预算 | ✅ | 金额与自动关闭秒数可设 |
| 每轮消耗泡泡 | ✅ | `{cost}` 占位符；自动关闭秒数可设 |
| 音效 | ✅ | 小黄鸭 / 音效1 按压松开音；任务结束音（经验球 / 预设 A） |
| 菜单按钮可隐藏 | ✅ | 隐藏后右键小鲸鱼唤出菜单；默认常驻可见（悬停变清晰） |
| 锁定（整块窗口穿透） | ✅ | 锁定后角色本体 / 气泡 / 菜单按钮 / 右键全部让出鼠标，点击直达下层应用；拖动与吸附一并停用；解锁只能从菜单栏 🐋 |
| 不透明度调节 | ✅ | 菜单滑块，20%–100%；下限刻意不为 0（免得挂件「消失」无从找回）；减淡不影响点击与位置 |
| 用量记录窗口 | ✅ | 今日模型占比、近 7 天、搜索、逐条明细 |
| DSH 历史账本导入 | ✅ | 首次运行自动导入，口径与 DSH 连续 |
| 多厂商自定义 API | ❌ | 桌面版聚焦 DeepSeek 内置余额，未移植 34 个厂商模板 |
| 气泡式提醒（可穿透点击） | ❌ | 桌面窗口无法做到「点得穿的浮层」，提醒改为面板内卡片 |
| 音频片段裁剪导入 | ❌ | 未移植可视化裁剪器，仅内置两套音效 |

> 移除了原插件的**隐藏菜单入口之外的浏览器依赖**，其余交互尽量一一对应。
> 未移植项都是与原插件宿主环境（网页 DOM / 会话事件）强绑定的能力。

## 数据与配置

```
~/.whale-widget-mac/
├── config.json     # 外观 / 开关 / 位置 / 预警阈值
├── ledger.json     # 观测账本 + 逐轮明细
├── bubbles.json    # 点击序列 + 模块库
└── images/         # 导入的泡泡图片
```

删除整个目录即可恢复出厂状态。

## 自检

不启动界面即可验证核心链路：

```bash
# 全量验证：构建 + 自检 + 离屏渲染 + 打包
./Scripts/verify.sh
```

分开跑也可以：

```bash
swift run WhaleWidget --selftest          # 凭据 / 计价 / 峰谷 / 记账 / 窗口定位 / 资源 / 真实拉取余额
swift run WhaleWidget --hitcheck          # 命中遮罩（逐像素贴合图案）+ 点击序列 + 点击/拖动判定
swift run WhaleWidget --e2e               # 端到端：起真实窗口，用合成鼠标事件走完整链路
swift run WhaleWidget --render /tmp/out   # 离屏渲染 + 像素断言（气泡形状、描边、文字、布局方位）
swift run WhaleWidget --stress 120        # 稳定性压测：放大状态变化频率，复现运行期崩溃
```

> 这些入口都在**隔离的临时状态目录**里跑，不会动你的真实配置。

真实 `.app` 的验收脚本：

```bash
./Scripts/package_app.sh release          # 打包
./Scripts/final_check.sh 130              # 启动并观察是否存活 / 有无崩溃报告
./Scripts/window_check.sh                 # 确认窗口完整落在可见区域内
./Scripts/clean_launch_check.sh 45        # 干净环境启动，校验默认缩放与位置
```

### 本机开发提示

若只装了 Command Line Tools，SwiftUI 的宏插件会找不到
（`external macro implementation type 'SwiftUIMacros.StateMacro' could not be found`）。
`Package.swift` 会在检测到完整 Xcode 时自动把它的宏插件目录传给编译器，
因此无需切换 `xcode-select` 也能直接 `swift build`。

## 项目结构

```
Sources/WhaleWidget/
├── main.swift                  # 入口 / 菜单栏 / 设置窗口
├── PanelController.swift       # 悬浮窗口、拖拽、吸附、镜像
├── WidgetContainerView.swift   # 原生指针事件（点击 / 拖动 / 悬停 / 右键）+ 命中判定
├── HitMask.swift               # 可交互区域遮罩（按图案 alpha 逐像素烘焙）
├── PointerIntent.swift         # 点击 vs 拖动的纯逻辑判定（可单测）
├── PanelInteraction.swift      # 交互状态（Q 弹形变 / 悬停）
├── FloatingPanel.swift         # 挂件视图（小鲸鱼 + 气泡布局，纯显示）
├── Positioning.swift           # 窗口尺寸 / 夹取 / 吸附 / 命中矩形计算（可测）
├── BubbleShape.swift           # SVG 路径解析 + 气泡造型（沿用参考实现几何）
├── BubbleModel.swift           # 泡泡数据模型 / 图片库
├── BubbleRuntime.swift         # 点击序列、加权抽取、图片缓存
├── BubbleEditorView.swift      # 自定义泡泡窗口
├── MenuView.swift              # 主菜单
├── UsageView.swift             # 用量记录窗口
├── ReconcileView.swift         # 余额校正窗口
├── WhaleStore.swift            # 中央状态（轮询 / 记账 / 提醒）
├── Ledger.swift                # 定点金额 + 观测账本
├── Pricing.swift               # 峰谷判定（含法定节假日）+ 单价表
├── DeepSeekAPI.swift           # 余额接口客户端
├── Credentials.swift           # 凭据解析 + SHA-256
├── SoundPlayer.swift           # 音效
├── Assets.swift                # 资源定位
├── SelfTest.swift              # 自检
├── RenderCheck.swift           # 离屏渲染 + 像素断言
├── HitCheck.swift              # 交互路由 / 点击拖动判定 / 命中遮罩校验
├── EndToEndCheck.swift         # 端到端（真实窗口 + 合成鼠标事件）
└── StressTest.swift            # 稳定性压测

Scripts/
├── package_app.sh              # 编译 + 组装 .app（含图标与资源）
├── verify.sh                   # 构建 + 自检 + 渲染 + 打包
├── stress.sh                   # 压测并对比崩溃报告
├── final_check.sh              # 启动真实 .app 后验收
├── clean_launch_check.sh       # 干净环境启动校验
├── window_check.sh             # 窗口是否完整在屏幕内
└── status.sh                   # 进程 / 崩溃报告 / 账本状态快照
```

## 实现说明

- **峰谷规则**：高峰 = 周一至周五 **且** 非法定节假日 **且** 9:00–12:00 / 14:00–18:00；
  其余全部为谷价（含周末、法定节假日全天、工作日其余钟点）。
  节假日名单直接取自国务院办公厅《关于 2026 年部分节假日安排的通知》（共 33 天），
  写在 `Pricing.legalHolidays`；调休上班的周末（如 2026-09-20）**不计高峰**，
  与「工作日 = 周一至周五」的规则一致。新增年份时补 `legalHolidays` 与 `knownHolidayYears` 即可；
  未收录的年份只按周一至周五判断，不会静默用错数据。
- **气泡造型**：直接沿用参考实现 `viewBox="0 0 1026 700"` 的 path / ellipse 数据，
  并写了一个最小 SVG 路径解析器（`M / L / A / Z`，含椭圆弧转贝塞尔），保证外观与宿主插件一致。
- **布局比例**：角色图宽高 59.45%、贴右下；气泡宽高比 1026/700、贴左上 —— 与参考实现 CSS 相同。
- **文字区**：泡泡本体是椭圆（cx≈454, cy≈248, rx≈373, ry≈232），描边 18。
  文字放在按椭圆内缩的区域（宽 56%、高 52%），配合 `ViewThatFits` 从 1.00/0.82/0.66/0.52/0.40
  逐档降字号，保证内容始终落在泡泡内部。余额行字号为其余行的 2 倍多（150u vs 56u）。
- **尺寸公式**：`clamp(122px, min(250px, min(vw, vh) * 0.28) * scale, 625px)`，与 `--dshw-base` 一致。
- **指针输入**：全部由 `WidgetContainerView` 的原生 `mouseDown/Dragged/Up` 处理，SwiftUI 只负责显示。
  不用 SwiftUI `DragGesture` 的原因：`translation` 相对手势起始视图坐标系，
  窗口一移动坐标系就跟着动，会自我反馈（拖动抽搐）；且窗口重建时手势会重置，
  `translation` 会跳一下，把本该算点击的操作判成拖动（点击序列推进不下去）。
- **命中区域**：由 `HitMask` 逐像素烘焙角色图的 alpha 通道 —— **只含小鲸鱼本体**。
  气泡（纯展示）与菜单按钮（交给 SwiftUI 响应）都不计入。
- **click-through**：只让 `hitTest` 返回 `nil` **不等于**穿透 —— 事件仍落在本窗口上，
  只是没人处理，下层窗口收不到。真正的穿透靠按光标位置切换
  `window.ignoresMouseEvents`：`EventRouting.zone(at:)` 把位置分成
  `character` / `menuButton` / `bubble` / `transparent` / `locked`，只有前两者接收事件。
  窗口忽略鼠标事件后收不到 `mouseMoved`，因此用 `NSEvent.addGlobalMonitorForEvents`
  跟踪光标；拖动 / 按压期间跳过切换，避免跟丢。
- **状态目录隔离**：`--selftest` / `--hitcheck` / `--e2e` / `--render` / `--stress`
  这些非交互入口会自动把状态目录切到临时目录（`AppConfig.directory`），
  结束后清理。它们会驱动真实的 store 与 controller，进而调用 `save()`；
  若写到真实目录，跑一次自检就会覆盖用户的缩放 / 位置 / 开关。
  需要固定位置时用 `WHALE_STATE_DIR` 显式指定。
- **踩过的坑**（原生 AppKit / SwiftUI 侧，都已在代码里注释）：
  - `NSApplication.delegate` 是弱引用，必须自持强引用；
  - `NSTrackingArea` 的 owner 必须实现 `mouseEntered/mouseExited`，且增删要幂等（重入会过度释放）；
  - `NSWindow.isReleasedWhenClosed` 默认 `true`，自持强引用时必须关掉，否则关闭后过度释放；
  - `Timer.scheduledTimer` 之后不要再 `RunLoop.add` 同一个 timer；
  - SwiftUI `.position(...)` 之后的 `.onTapGesture` / `.contentShape` 会落在撑满父容器的外层上（手势区被放大）；
  - `ViewModifier.body(content:)` 是 `@ViewBuilder`，里面不能写 `return`；
  - 列表渲染顺序只由数据源数组决定，**绝不能按字典 key / UUID 排序**（会打乱排版）；
  - `NSBitmapImageRep(bitmapDataPlanes: nil, …)` 是**未初始化**的缓冲区，
    用 `.sourceOver` 画图前必须先填透明色，否则透明区域会残留垃圾 alpha，
    烘焙出零星假像素。
- **状态更新**：驱动 UI 的推导值，其**依赖也必须可观察**。
  `BubbleRuntime.queueIndex` 曾是普通属性，`currentPage` 由它推导 →
  第 2 次点击时 `isOpen` 没变、`queueIndex` 又发不出通知，SwiftUI 收不到变更，
  界面停在旧页；第 3 次点击 `isOpen` 翻 false 才重绘并顺势收起（看起来像「消失」）。
- **锁定**：新增 `EventRouting.Zone.locked`，整块面板一律 `ignoresMouseEvents`。
  两个容易踩的点：
  1. **「不接收事件」与「命中测试放行」是两件事。** 锁定后不仅要穿透，
     还必须让 `hitTest` 返回 `nil` —— 否则光标落在角色本体上时事件仍会交给容器，
     容器照常推进气泡序列，锁定形同虚设。因此把它拆成
     `EventRouting.Behavior { acceptsEvents, hitTestable, draggable, advancesBubble }`，
     而不是继续用一个 `acceptsEvents` 布尔（那样表达不了这种差异）。
  2. **判断顺序**：`updateEventAcceptance` 里锁定必须写在「快路径」**之前** ——
     那条快路径只在光标离开窗口时才置 `ignoresMouseEvents`，光标停在角色本体上时
     它什么都不做，锁定会失效。
  另外：锁定期间会临时把 `snapEnabled` 置 false（解锁时还原），
  否则窗口可能被吸附推走，与「锁定 = 纹丝不动」矛盾；
  解锁入口必须在菜单栏（挂件自身已不可交互），并带锁定角标作为可见反馈。
- **不透明度**：挂在 `WhalePanelView` 的 `.opacity(store.config.panelOpacity)` 上，
  即**视图层**。不要改用 `NSWindow.alphaValue`：与视图层叠加会相乘
  （滑到 0.5 变成 0.25），而且 `--render` 离屏渲染读不到 `NSWindow` 属性，
  等于失去测试覆盖。选择这条路径后，不透明度就能用「渲染像素的最大 alpha」来断言。
- **配置向后兼容**：`locked` / `opacity` 写成 **Optional（默认 nil）**，不是笔误 ——
  Swift 合成的 `init(from:)` **不会**用属性默认值兜住缺失的键，
  写成非 Optional 的话，旧版本写出的 `config.json`（没有这两个键）会抛
  `keyNotFound` → `load()` 返回 `nil` → 用户的缩放 / 位置 / 开关被静默重置。
  `--hitcheck` 里有回归断言，并且额外钉了一条**对照断言**
  （同键的非 Optional 版本必须解码失败），免得日后被「顺手简化」掉。

## 已知限制

- 「每轮对话消耗」需要本地会话记录；桌面版读不到 DSH 的会话事件，因此该功能默认不自动触发
  （`WhaleStore.recordTurn` 已就绪，可由本地会话统计接入）。
- macOS 13+（Sonoma / Sequoia / Tahoe 均可）。

## 许可证

代码部分 MIT。`Resources/assets/` 下的美术与音频素材来自参考项目，
不在 MIT 覆盖范围内，随包分发、仅供运行本挂件使用。
