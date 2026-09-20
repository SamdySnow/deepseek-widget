# 进度检查点（Checkpoint）

> 生成时间：2026-09-19 16:34
> 最后更新：2026-09-20（第三轮：菜单新增「锁定」+「不透明度」滑块）
> 用途：记录当前进度与下一步，方便下次直接接着做。
> 相关文档：`README.md`（使用说明 / 功能对照 / 实现说明）。

---

## 一、当前状态速览

| 项目 | 状态 |
|---|---|
| 编译 | ✅ `swift build -c release` 干净通过，**0 warning**（仅剩 ld 的 search-path 提示，可忽略） |
| 自动化验证 | ✅ `./Scripts/verify.sh` — **220 项全通过，0 失败** |
| 打包产物 | ✅ `dist/WhaleWidget.app`（8.4 MB） |
| 运行状态 | ▶️ 正在运行（`pgrep` 有 1 个进程），余额在实时轮询更新 |
| 用户配置 | ✅ `~/.whale-widget-mac/config.json`（scale 1.8 / 右下角吸附），未被测试污染 |

### 单项测试数量（合计 220）

| 入口 | 项数 |
|---|---|
| `--selftest` | 71 |
| `--hitcheck` | 96 |
| `--render` | 31 |
| `--e2e` | 22 |
| `--stress` | 不计项（只判存活 / 崩溃） |

### 常用命令

```bash
cd /Users/samdy/Coding/deepseek-widget

./Scripts/verify.sh                 # 一键：构建 + 自检 + 交互 + 端到端 + 渲染 + 打包（180 项）
./Scripts/package_app.sh release    # 只打包
open dist/WhaleWidget.app           # 启动
pkill -f WhaleWidget                # 停止

./Scripts/status.sh                 # 进程 / 最新崩溃报告 / 账本
./Scripts/dump_state.sh             # 导出配置 / 气泡队列 / 账本，并推演点击序列
./Scripts/check_clickthrough.sh     # click-through 人工核对清单
./Scripts/window_check.sh           # 窗口是否完整在屏幕内
./Scripts/clean_launch_check.sh 45  # 干净启动，校验默认缩放与位置
./Scripts/watch_config.sh 25        # 逐秒观察 config.json 变化（排查看谁在写配置）
./Scripts/stress.sh 120             # 编译 + 压测，并对比崩溃报告
```

---

## 二、这一轮完成的工作

### 1. 峰谷判定重写（含中国法定节假日）✅

按新规则重写 `Pricing.swift`，不再用日期阈值，改为**取当前时间直接比较**：

```
高峰 = 周一至周五 且 非法定节假日 且 (9:00–12:00 或 14:00–18:00)
谷价 = 其余全部（周末、法定节假日全天、工作日其他钟点）
```

- `Pricing.legalHolidays`：2026 年国务院放假日期，共 **33 天**
  （元旦 1/1–3、春节 2/15–23、清明 4/4–6、劳动 5/1–5、端午 6/19–21、中秋 9/25–27、国庆 10/1–7）
- `Pricing.knownHolidayYears = [2026]`：未收录年份只按周一至周五判断，**不会静默用错数据**
- ⚠️ **待你确认的一个决定**：调休上班的周末（如 2026-09-20、10-10）我按**谷价**处理，
  因为规则写的是「周一至周五」。若希望调休日按高峰，把 `Pricing.makeupWorkdays`
  接进 `isPeak` 即可（该常量已存在，当前仅作记录）。
- 谷价文案会区分「周末·谷价」「法定节假日·谷价」「空闲时段」，便于核对。

### 2. 点击/拖动判定重构（修「点两下气泡消失」）✅

**根因**：原来用 SwiftUI `DragGesture` 的 `translation` 判定。
它是相对**手势起始视图坐标系**的 —— 窗口一移动坐标系跟着动（自我反馈 → 拖动抽搐）；
且窗口重建时手势会重置，`translation` 跳变，把本该算点击的操作判成拖动（→ 点击序列不推进）。

**改法**：指针输入整体移出 SwiftUI，交给自写的 `NSView`：

- `WidgetContainerView`：原生 `mouseDown/Dragged/Up` + `NSEvent` 事件坐标（**不再用 `NSEvent.mouseLocation`**，
  它是「读取那一刻」的位置，且无法在合成事件测试里驱动）
- `PointerIntent`：点击 vs 拖动的纯逻辑判定（可单测）
- 判定规则：按压期间**曾经**超过阈值即算拖动（拖出去再拖回原点仍是拖动，不是点击）

### 3. 菜单按钮默认隐藏 ✅

- 鼠标进入可交互区域才淡入，离开即隐去；`menuButtonOpacity` 驱动
- 悬停判定复用命中遮罩，所以移到透明处不会让它冒出来
- 右键始终可唤出菜单（备用入口）

### 4. 可交互区域严格贴合图案（不是矩形）✅

新增 `HitMask.swift` —— 逐像素烘焙：

- **角色图**：按 alpha 通道烘焙（阈值 alpha > 24/255，过滤抗锯齿边缘）
- **气泡**：用泡泡的**真实几何**（椭圆 + 两个尾巴圆），不是外接矩形
- **菜单按钮**：仅在可见时计入（否则鼠标移上去按钮就消失）

结果：覆盖率 **23.3%**（外接矩形是 35.3%），ASCII 轮廓能看出鲸鱼剪影。

### 5. 点击 Q 弹 ✅

原来只靠「按下」状态驱动变形 —— 一次点击只有几十毫秒，动画会被立刻取消，所以看不到。
改为在 `mouseUp` 主动触发一次「压扁 → 回弹」。

### 6. 余额字号调大 ✅

150u（其余行 56u），测试断言「余额字号必须大于其它各行」。

### 7. 顺带修掉的真 bug

| bug | 现象 | 修复 |
|---|---|---|
| 点菜单按钮顺带切换气泡 | 点 ☰ 时气泡也跳一格 | 容器 `mouseDown` 排除按钮区域 |
| 命中遮罩有零星空洞 | 遮罩出现 4 处假像素 | `NSBitmapImageRep(bitmapDataPlanes: nil)` 是**未初始化**缓冲区，`.sourceOver` 前必须先填透明色 |
| 排版顺序随机 | 行序每次运行都不一样 | 原来按 UUID 字典序渲染；改为严格按配置的 `page.rows` |
| SVG 解析器越界 | 大写 `A` 指令参数不足会崩溃 | `case "A", "a" where …` 的 `where` **只作用于最后一个模式**，长度校验必须写进分支 |
| 测试污染用户配置 | 跑自检后缩放被改成随机值 | 测试入口自动隔离到临时状态目录 |
| `--render` 默认写当前目录 | 仓库根目录堆积 png + 构建报 unhandled 警告 | 默认改到临时目录；补 `.gitignore` |
| Package.swift 的 exclude 用相对路径 | IDE 从别处启动 SwiftPM 时漏判，构建报 unhandled 警告 | 改用 `#filePath` 推出的**绝对路径**判断存在性 |

### 8. ⚠️ 我自己造成并修复的问题（重要）

**测试会写用户的真实配置**。`--selftest/--hitcheck/--e2e/--render/--stress`
都会驱动真实的 store/controller，进而调用 `save()` —— 跑一次自检就会覆盖用户的
缩放、位置、开关（压测里那个「随机改缩放」的循环是直接元凶）。

已修复：`AppConfig.directory` 检测到测试参数时切到临时目录，退出时清理
（可用 `WHALE_STATE_DIR` 显式指定）。**已验证**：放一个带 `sentinel` 字段的真实配置，
跑完全套测试后文件逐字节未变，且无临时目录残留。

---

## 二·补、第二轮工作（17:46）

### 9. 点击序列 bug 的真正根因 ✅（关键）

用户反馈「点一次展开、第二次不跳转、第三次消失」。

`handleTap` 的状态机本身是**对的**（单测全过），问题在**视图没重渲染**：

```swift
@Published private(set) var isOpen: Bool = false
private var queueIndex: Int = 0        // ← 不是 @Published！
```

`currentPage` 由 `queueIndex` 推导，但视图只观察 `BubbleRuntime`。
第 2 次点击时 `isOpen` 已经是 `true`、值没变，`queueIndex` 的变化又发不出通知
→ SwiftUI 收不到任何变更 → 界面停在「首次点击泡」。
用户看到的「没反应」其实是「重绘了但内容一样」；第 3 次点击 `isOpen` 翻成 false，
这才重绘 → 顺势收起，于是「消失」。

**修复**：把 `queueIndex` 改为 `@Published`。

> 教训：状态机单测通过 ≠ 界面会更新。凡是驱动 UI 的推导值，其**依赖**也必须可观察。
**回归测试（已验证能抓到）**：`--hitcheck` 里新增「视觉更新通知」一节，
用 `objectWillChange` 计数断言「每次点击都必须发出变更通知」。
我把 `queueIndex` 临时改回普通属性验证过 —— 第 2 次点击的计数为 **0，测试确实变红**；
恢复 `@Published` 后为 1。这样这个 bug 不会静默回归。
### 10. 可交互区域收窄到「只有角色本体」✅

按要求调整 `HitMask.bake`：气泡与菜单按钮都**不再**计入遮罩。

- 气泡：纯展示，点它不推进序列 → 排除；
- 菜单按钮：由 SwiftUI 自行响应 → 排除（若纳入，按钮周围一圈空白会变成
  「可点但无反应」的死区）。

顺带删掉了不再需要的 `stampShapes` / `bubbleEllipse` / `bubbleTails` / `buttonRect` 等
几何叠加代码。遮罩因此**不随气泡开合变化**，只在尺寸 / 镜像变化时重建。

### 11. 透明像素真正 click-through ✅

**关键认识**：只让 `hitTest` 返回 `nil` **不等于**穿透 —— 事件仍然落在本窗口上，
只是没人处理，下层窗口收不到。真正的穿透必须切换 `window.ignoresMouseEvents`。

实现：

- `EventRouting.zone(at:)` 判定光标所处区域：`character` / `menuButton` /
  `bubble` / `transparent`（优先级：按钮 > 角色 > 气泡 > 透明）
- `EventRouting.acceptsEvents(zone)`：只有 `character` 与 `menuButton` 需要接收事件
- `PanelController` 用 `NSEvent.addGlobalMonitorForEvents`（`.listenOnly`，不拦截事件）
  跟踪光标；窗口在忽略鼠标事件时收不到 `mouseMoved`，必须用全局监听才能知道
  光标何时移回来
- 快路径：先做屏幕坐标粗判，光标远离窗口时直接跳过坐标换算与遮罩查表

实测：**接收事件的面积占比 24.0%**（character 840 / menuButton 25 /
bubble 2153 / transparent 582，共 3600 采样点）。

### 12. 测试资产

- 新增 `Scripts/dump_state.sh`：导出配置 / 气泡队列 / 账本，并**推演点击序列**。
  排查这类「与用户实际状态有关」的问题时先跑它 —— 它也是我这次确认
  「队列只有 1 项」的工具（所以第 3 次点击收起是配置如此，不是 bug）。
- 新增 `Scripts/check_clickthrough.sh`：click-through 的人工核对清单
  （真实光标行为无法在无头环境合成）。
- `--e2e` 增加两组断言：**同一点连点 6 次的状态轨迹**、鲸鱼本体上逐点可点击。
- `--hitcheck` 增加 click-through 路由断言（zone 划分 + 面积占比）。

### 13. 本轮还修掉的

| 问题 | 修复 |
|---|---|
| `--hitcheck` 的 `bubbleOpen:`/`buttonRect:` 参数随 API 收窄而失效 | 同步更新测试与语义 |
| 全局监听回调的线程假设（`assumeIsolated`） | 改为统一 `DispatchQueue.main.async`，不赌线程 |
| 按压中若丢失 `mouseUp`，`isPressing` 会永久卡住 | 全局监听里用 `NSEvent.pressedMouseButtons` 兜底解锁 |

---

## 二·补二、第三轮工作：锁定 + 不透明度

### 14. 菜单新增「锁定」✅

锁定后**整个窗口 click-through** —— 角色本体、气泡、菜单按钮、右键全部让出鼠标，
点击直达下层应用；拖动与吸附一并停用。

实现要点（两处容易踩空的地方，已在代码注释 + README 里写明）：

1. **「不接收事件」≠「命中测试放行」**。锁定后不仅要穿透，还必须让 `hitTest`
   返回 `nil`；否则光标落在角色本体上时事件仍会交给容器，容器照常推进气泡序列
   → 锁定形同虚设。因此把原来的 `acceptsEvents(_:) -> Bool` 升级为
   `EventRouting.Behavior { acceptsEvents, hitTestable, draggable, advancesBubble }`
   —— 单一布尔表达不了这种差异。
2. **判断顺序**：`updateEventAcceptance` 里锁定必须写在「快路径」**之前**。
   那条快路径只在光标离开窗口时才置 `ignoresMouseEvents`，光标停在角色本体上时
   它什么都不做 → 锁定失效。

配套处理：

- 锁定期间临时把 `snapEnabled` 置 false（解锁时还原原值），否则窗口可能被吸附
  推走，与「锁定 = 纹丝不动」矛盾；
- **解锁入口放在菜单栏 🐋 → 「解锁挂件」**（挂件自身已不可交互，这是唯一出路），
  未锁定时该项置灰；
- 挂件上显示**锁定角标**（右上角小锁）作为可见反馈 —— 否则用户会以为挂件坏了。

### 15. 菜单新增「不透明度」滑块 ✅

范围 **20%–100%**，实时生效。

- 下限刻意**不为 0**：完全透明会让挂件「消失」，而用户未必记得菜单里有这个滑块，
  那就变成了「挂件不见了」的求助场景。0.2 足够淡但仍可见 / 可拖回。
- 挂在 `WhalePanelView` 的 `.opacity(...)`（视图层），**不用** `NSWindow.alphaValue`：
  与视图层叠加会相乘（滑到 0.5 变成 0.25），而且 `--render` 离屏渲染读不到
  `NSWindow` 属性，等于失去测试覆盖。走视图层后就能用「渲染像素的最大 alpha」断言。
- 越界值夹回范围，NaN / ±inf 回退 1.0（手改配置不该让挂件消失）。
- 减淡**不影响**可点击性（命中判定与不透明度无关），有断言覆盖。

### 16. 顺带修掉的

| 问题 | 修复 |
|---|---|
| `AppConfig` 新增字段会**静默重置用户配置** | `locked` / `opacity` 写成 **Optional**：Swift 合成的解码器**不会**用属性默认值兜住缺失的键，非 Optional 时旧 config.json 会抛 `keyNotFound` → `load()` 返回 nil。已加回归断言 + 一条钉住「为什么必须 Optional」的对照断言 |
| 容器「空遮罩 = 整块可命中」的降级语义被重构弄丢 | 恢复为容器层的显式降级（锁定优先于降级），`--hitcheck` 的真实容器事件计数因此重新变绿 |
| `Scripts/*.sh` 缺可执行位（只有 `package_app.sh` 有） | `chmod +x`，README 里的 `./Scripts/verify.sh` 本来会 exit 126 |
| 测试样本构造不真实 | 旧的兼容性断言用了一个只含 2 个键的 JSON —— 那样连 `volume`、`updatedAt` 这些**早就有**的必填键都缺失，失败原因与改动无关。改为「完整配置删掉新键」 |

---

## 三、源码结构
```
Sources/WhaleWidget/              （约 6700 行）
├── main.swift                  入口 / 菜单栏 / 设置窗口 / 测试入口分发
├── PanelController.swift       悬浮窗口、拖拽、吸附、镜像、遮罩重建
├── WidgetContainerView.swift   原生指针事件 + 命中判定（输入的唯一入口）
├── HitMask.swift               可交互区域遮罩（只含角色本体，逐像素烘焙）
├── PointerIntent.swift         点击 vs 拖动的纯逻辑判定 + EventRouting（click-through）
├── PanelInteraction.swift      交互状态（Q 弹 / 悬停）
├── FloatingPanel.swift         挂件视图（纯显示，不含手势）
├── Positioning.swift           尺寸 / 夹取 / 吸附 / 命中矩形（可测）
├── BubbleShape.swift           SVG 路径解析 + 气泡造型
├── BubbleModel.swift           泡泡数据模型 / 图片库
├── BubbleRuntime.swift         点击序列 / 加权随机 / 图片缓存
├── BubbleEditorView.swift      自定义泡泡窗口
├── MenuPresenter.swift         菜单浮层 + 通用窗口呈现
├── MenuView.swift              主菜单
├── UsageView.swift             用量记录窗口
├── ReconcileView.swift         余额校正窗口
├── WhaleStore.swift            中央状态（轮询 / 记账 / 提醒）
├── Ledger.swift                定点金额 + 观测账本
├── Pricing.swift               峰谷判定（含法定节假日）+ 单价表
├── DeepSeekAPI.swift           余额接口客户端
├── Credentials.swift           凭据解析 + SHA-256
├── SoundPlayer.swift           音效
├── Assets.swift                资源定位
├── SelfTest.swift              --selftest
├── HitCheck.swift              --hitcheck
├── EndToEndCheck.swift         --e2e
├── RenderCheck.swift           --render
└── StressTest.swift            --stress

Scripts/                         见「常用命令」
Resources/assets/                小鲸鱼图 / 泡泡图 / 音效（来自参考项目，非 MIT）
```

---

## 四、验证体系（220 项）

| 入口 | 覆盖内容 | 项数 |
|---|---|---|
| `--selftest` | 凭据解析 / 峰谷判定（含节假日边界、跨周末与跨长假倒计时）/ 计价 / 记账语义 / 定点精度 / DSH 历史导入 / 窗口定位 / 拖动跟随 / 资源 / **真实联网拉余额** | 71 |
| `--hitcheck` | 命中遮罩逐像素准确性（只含角色本体）/ **click-through 路由** / **锁定语义** / **不透明度夹取** / **旧配置向后兼容** / 点击拖动判定 / 点击序列两种模式 / 菜单按钮独立性 | 96 |
| `--render` | 离屏渲染 + 像素断言（气泡填充/描边/文字、布局方位、文字不溢出气泡、逐页可渲染、**锁定角标**、**不透明度像素效果**） | 31 |
| `--e2e` | **起真实窗口 + 合成鼠标事件**走完整链路（点击序列、**同点连点状态轨迹**、拖动、菜单按钮冲突、透明区不响应、**锁定穿透 + 拖不动**、**不透明度像素效果**） | 22 |
| `--stress` | 稳定性压测（放大状态变化频率，对比崩溃报告） | — |

### 验证方法论（值得延续）

1. **真值要来自独立来源**。判「形状是否一致」时，真值取自图片 alpha 通道，
   而不是手写主观预期（我曾假设「四角都透明」，但鲸鱼身体本就填到右下角 —— 是断言错了）。
2. **端到端不可省**。单元测试直接调 `handleTap()` 覆盖不到「事件是否重复投递」
   「遮罩是否挡掉点击」这类**接线**问题 —— 而「点两下气泡消失」恰恰是这一类。
3. **容差要有依据**。遮罩栅格 450 格 vs 原图 610px，逐点比对留 ±2 源像素容差，
   是分辨率换算推出来的，不是为让测试变绿随手放的。
4. **自己写的断言也会错**。本轮至少 5 次是断言写错而非代码错（时间相关、长度算错、
   把闭包参数当输入…）。看到红灯先问「是这个测试错了吗」。
   第三轮又复现了一次：兼容性断言里的测试样本只放了 2 个键，
   于是连 `updatedAt` 这种**早就有**的必填键也没了 —— 失败与本次改动无关。
   **构造「旧版本数据」的样本时，必须从真实结构出发再删字段**，不能凭印象手写。

---

## 五、下一步 / 待办

### 需要你确认的

- [ ] **锁定手感**：按 `./Scripts/check_clickthrough.sh` 的第 6–9 项核对 ——
      重点确认「点小鲸鱼所在位置是否真的落到了下层应用」，
      以及解锁入口（菜单栏 🐋 → 解锁挂件）是否好找。
- [ ] **不透明度下限 20% 合不合适？** 现在是刻意不为 0（免得挂件「消失」无从找回）。
      若你希望更淡（例如 10%），改 `AppConfig.opacityRange` 一处即可，测试会跟着走。
- [ ] **点击序列是否正常了？** 第 2 次点击现在应该从「首次点击泡」跳到「撒娇」。
      根因是 `queueIndex` 不是 `@Published`（见「二·补 9」）。若仍不对，请先跑
      `./Scripts/dump_state.sh` 把实际队列贴给我。
- [ ] **click-through 手感**：点透明处 / 点气泡是否都穿透到桌面了？
      按 `./Scripts/check_clickthrough.sh` 的清单核对（真实光标行为无法自动化）。
- [ ] **调休上班的周末算不算高峰？** 当前按谷价（与「周一至周五」规则一致）。
      若要按高峰，把 `Pricing.makeupWorkdays` 接进 `isPeak`。

### 已知未移植（与网页宿主强绑定，见 README 功能对照表）

- 多厂商自定义 API（原项目 34 个厂商模板）
- 可穿透点击的气泡式提醒（桌面窗口做不到「点得穿的浮层」）
- 音频片段可视化裁剪
- 每轮对话消耗的自动触发（读不到 DSH 会话事件；`WhaleStore.recordTurn` 已就绪，接本地会话记录即可启用）

### 可选的后续改进

- [ ] 节假日名单每年 11 月由国务院公布 —— **2026 年底需补 2027 年数据**
      （更新 `Pricing.legalHolidays` 与 `knownHolidayYears`）
- [ ] 「每轮对话消耗」：接本地会话日志（如 Codex `~/.codex/sessions`；本机当前为 0 个文件）
- [ ] 菜单里加「重置位置」入口（`PanelController.resetPosition()` 已就绪，尚未接 UI）
- [ ] 首次启动引导（提示密钥来源、右键唤出菜单等）

---

## 六、踩过的坑（已在代码注释中标注）

**AppKit / 生命周期**

- `NSApplication.delegate` 是**弱引用**，必须自持强引用，否则启动即 SIGSEGV
- `NSTrackingArea` 的 owner 必须实现 `mouseEntered/mouseExited`，否则 `Unrecognized selector`
- `updateTrackingAreas()` 里 remove/add 会重入 → 必须加 `isUpdating` 守卫（否则过度释放）
- `NSWindow.isReleasedWhenClosed` 默认 `true`：自持强引用时**必须设 false**，否则关闭后过度释放
- 不要 `Timer.scheduledTimer` 之后再 `RunLoop.add` 同一个 timer
- `NSBitmapImageRep(bitmapDataPlanes: nil, …)` 是未初始化缓冲区，画之前必须先填透明色

**SwiftUI**

- `.position(...)` **之后**挂的 `.onTapGesture` / `.contentShape` 会落在撑满父容器的外层上
  （手势区被整个放大）→ 手势要挂在内层，最后才 `.position`
- `ViewModifier.body(content:)` 是 `@ViewBuilder`，里面不能写 `return`
- 列表渲染顺序只由数据源数组决定，**绝不能按字典 key / UUID 排序**
- 气泡文字要落在造型内部：按造型几何内缩出文字区 + `ViewThatFits` 逐档降字号
- 半透明效果挂在**视图层**（`.opacity`）而不是 `NSWindow.alphaValue`：
  两处都设会相乘，而且离屏渲染读不到 `NSWindow` 属性（等于没测试覆盖）

**Swift 语言**

- `case "A", "a" where 条件` 的 `where` **只作用于最后一个模式**，长度校验要写进分支
- **合成的 `init(from:)` 不会用属性默认值兜住缺失的键**：
  给 `Codable` 结构体新增字段时，若该字段非 Optional，旧 JSON 会抛 `keyNotFound`
  → `load()` 返回 nil → **静默丢掉用户全部配置**。
  新增配置项一律用 Optional（`decodeIfPresent`）承载默认值

**构建 / 工程**

- `Package.swift` 的 `exclude` 里判断文件是否存在要用**绝对路径**
  （`URL(fileURLWithPath: #filePath).deletingLastPathComponent()`）：
  manifest 求值时的 CWD 不保证是仓库根目录，用相对路径会漏判 → 构建报
  `found N file(s) which are unhandled`
- 同理，只 exclude **确实存在**的路径，否则 SwiftPM 报 `Invalid Exclude … File not found`
- 临时输出目录（如 `--render` 的默认值）不要落在仓库里，否则会污染构建与 git 状态
- `Scripts/*.sh` 的可执行位易丢（只有 `package_app.sh` 带 x）——
  README 写的是 `./Scripts/xxx.sh`，缺 x 会直接 exit 126。改动脚本后顺手 `chmod +x`

**测试卫生**

- 非交互入口必须隔离状态目录（见「工作 8」）
- 像素断言要单独渲染目标层：整块面板里角色图也有白色与深蓝像素，
  会污染「文字包围盒」与「气泡包围盒」的判断
- 泡泡描边内侧的抗锯齿像素也是深蓝，统计文字包围盒必须内缩跳过描边带
- 构造「旧版本数据」样本要**从真实结构出发再删字段**：手写一个只含几个键的 JSON
  会把「早就有」的必填键也漏掉，于是失败原因与本次改动无关（第三轮又踩了一次）

---

## 七、环境备注

- 本机只选了 Command Line Tools，但装了完整 Xcode（**未同意 license，`xcodebuild` 不可用**）。
  `Package.swift` 检测到 Xcode 存在时会把它的 SwiftUI 宏插件目录传给编译器，
  因此无需 `xcode-select` 切换即可 `swift build`。
- 长命令（`sleep` / 压测）会把同步终端卡住并吞掉后续输出 ——
  这类命令请走 `Scripts/*.sh` + VS Code task，或把输出重定向到文件再读。
