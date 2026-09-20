# 进度检查点（Checkpoint）

> 生成时间：2026-09-19 16:34
> 最后更新：2026-09-20（第五轮：修「贴左后文字是反的」—— 补上内容反翻）
> 用途：记录当前进度与下一步，方便下次直接接着做。
> 相关文档：`README.md`（使用说明 / 功能对照 / 实现说明）。

---

## 一、当前状态速览

| 项目 | 状态 |
|---|---|
| 编译 | ✅ `swift build -c release` 干净通过，**0 warning**（仅剩 ld 的 search-path 提示，可忽略） |
| 自动化验证 | ✅ `./Scripts/verify.sh` — **258 项全通过，0 失败** |
| 打包产物 | ✅ `dist/WhaleWidget.app`（8.4 MB） |
| 运行状态 | ▶️ 正在运行（`pgrep` 有 1 个进程），余额在实时轮询更新 |
| 用户配置 | ✅ `~/.whale-widget-mac/config.json`（scale 1.8 / 右下角吸附），未被测试污染 |

### 单项测试数量（合计 258）

| 入口 | 项数 |
|---|---|
| `--selftest` | 76 |
| `--hitcheck` | 95 |
| `--render` | 36 |
| `--e2e` | 50 |
| `--stress` | 不计项（只判存活 / 崩溃） |

### 常用命令

```bash
cd /Users/samdy/Coding/deepseek-widget

./Scripts/verify.sh                 # 一键：构建 + 自检 + 交互 + 端到端 + 渲染 + 打包（253 项）
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

## 二·补三、第四轮工作：吸附 / 翻转 / 重置位置

用户报了三件事：**重置位置没接入 UI**、**吸附屏幕边缘不生效**、**位于屏幕左侧不翻转**。
逐个查证后：第一条属实（代码有 `resetPosition()`，菜单里找不到入口）；
后两条都**不是「没实现」，而是实现里有真 bug**。

### 17. 重置位置接入 UI ✅

菜单 → 「重置位置」按钮。实现上**无条件**回右下角并显式写 `lastSide = "right"`，
不能复用 `applySnap` 去推断：用户在屏幕中间时 `applySnap` 算出「不吸附」，
那「重置」就变成「原地不动」了。

### 18. 「吸附不生效」的两个真原因 ✅

**原因 A：吸附区太窄（手感问题）**

参考实现用**比例**：`ratio: { L: 10, T: 0, R: 10, B: 15 }`（视口百分比），
1728px 屏上左右各约 **173px**。本版原先用固定的 `snapMargin = 24`，
只有参考实现的 ~14% —— 必须几乎把鲸鱼顶到屏幕边缘才吸附，手感上就是「不生效」。
现在 `Positioning.Zones.reference(for:)` 按比例换算，并保留 48px 绝对下限。
**注意上边不吸附**（T=0），所以四边宽度各自独立（`Zones` 结构体），
不能再用一个 `margin` 打天下。

**原因 B：窗口根本没动（真 bug，关键）**

```swift
NSAnimationContext.runAnimationGroup { ctx in
    ctx.duration = 0.16
    window.animator().setFrameOrigin(origin)   // ← 在本项目里是 no-op
}
```

实测：调用后立即读、以及等 0.6 秒后再读，窗口都停在原位。
于是吸附**目标算对了、坐标也写进配置了，唯独窗口没动** ——
用户看到的就是「拖到边上松手，什么也没发生」。
改用自驱动的定时器逐帧 `setFrameOrigin` 插值（20 帧 / 0.16s，ease-out）。
`--e2e` 里留了一条断言专门盯这个机制，防止改回 `animator()`。

顺带修掉两个**顺序**问题（都会让「吸附看起来很怪」）：

- `persistPosition()` 在动画前用旧 frame 覆盖了 `lastX/lastY`
  → 「吸附生效了，重启又回到旧位置」。现在动画期间拒绝写入。
- 朝向按**吸附目标位置**判定，不是当前位置（贴左时当前位置可能还在右半边）。

### 19. 「贴左不翻转」的两个真原因 ✅

**原因 A：判定逻辑本身不可靠。** 原来只在 `rebuildHitMask` 里设一次
`container.isMirrored`，而 `applySnap` 改了 `lastSide` 之后不会重建遮罩
（尺寸没变）→ 视觉翻转了、点击却仍按未镜像算。
现在 `refreshMirror()` 由控制器显式调用，并把「贴边 / 自由摆放」两套判定统一进
`desiredSide()`（对应参考实现的 `refreshFlip()`）。

**原因 B：关闭吸附时永不翻转。** 原代码直接置 `lastSide = "none"`，
而镜像判定是 `lastSide == "left" && mirrorOnLeftSnap` → 关掉吸附就永远不翻。
现在关闭吸附时仍按几何判朝向（贴边用 2px 容差识别）。

自由摆放的判定点取**图案中心**而非窗口盒中心 —— 挂件是右下角一只鲸鱼、
左上大片留白，用盒中心会把视觉上明明在左边的挂件判成右半边
（参考实现 `artCenterAt()` 同一口径）。翻转阈值用屏幕竖直中线（横屏下与参考的
`F = 50%` 一致）。

### 20. 本轮引入又修掉的回归（重要，都是我自己造的）

| 回归 | 现象 | 根因与修法 |
|---|---|---|
| 镜像污染全部点击 | `--e2e` 前段点击断言全红 | `createWindow()` 建窗时原点 `(0,0)` 恰是屏幕左下角 → 被判「贴左」→ 容器进入镜像态；`restorePosition()` 改了位置却没刷新镜像，容器就带着错误标记跑。修：`restorePosition()` 末尾调 `refreshMirror()` |
| 首次点击被吞 | 「第 1 次点击」间歇性失效 | `restorePosition → applySnap` 启动的 0.16s 动画还没跑完，测试改坐标后动画继续移动窗口 → 「按下→松开」两次事件里窗口坐标不同 → 同一屏幕点被换算成不同视图坐标 → 位移判成拖动。修：`handlePress` 先 `cancelSnapAnimation()`（也符合直觉：手抓住挂件后不该再自己滑） |
| 离屏时误判朝向 | 容器被离屏坐标判成「贴左」 | 离屏没有「朝屏幕内」可言。修：`desiredSide()` 在窗口与屏幕不相交时保持现状 |

**测试卫生（本轮学到的）**：
- 拖动相关断言会真的把窗口拖到边缘并触发翻转，**后续各节必须先把窗口复位到
  已知状态**（`parkNeutral()`），否则后面用的取样坐标全按未镜像算 → 大面积假红。
- 别把「真实网络/账本状态」牵进点击断言：余额提醒会在断言进行中异步插入
  临时泡泡，而 `handleTap` 遇临时泡泡只关闭不推进 → 断言时红时绿。
  现在自检下不接 `onAlert`（行为改由 `--hitcheck` 的确定性断言覆盖）。
- **确认自己跑的是新二进制**：本轮在跑旧产物上白排查了很久。
  `--hitcheck` 现在会打印二进制路径与构建时间。

---

## 二·补四、第五轮工作：贴左后文字是反的（补上内容反翻）

用户反馈「左侧翻转生效了，但连文字都是反的」。
**这次是我的错**：我当初只做了「整机镜像」这一步，漏掉了参考实现紧随其后的
「内容反翻」，还在注释 / README / 核对清单里把「文字同步反向」当成**特性**写了下来。

### 21. 参考实现到底怎么翻的 ✅

```css
.dshwv-root.dshwv-left    { transform: scaleX(-1) }   /* ① 整机翻 */
.dshwv-left .dshwv-text   { transform: scaleX(-1) }   /* ② 文字反翻回来 */
.dshwv-left .dshwv-gif    { transform: scaleX(-1) }   /* ② 图片反翻回来 */
```

也就是说：**小鲸鱼翻过去朝向屏幕内侧，但文字与图片保持正向可读**。
（另外 `.dshwv-root` 带 `transition: transform .3s ease`，所以翻转是有动画的。）

### 22. 修法 ✅

- `WhalePanelView` 继续负责**整机**镜像（翻转朝向）；
- `BubbleLayer` 新增 `mirrored` 参数，把气泡内容（文字 + 图片）**反翻一次**抵消掉；
- 翻转动画时长改为 0.3s，与参考实现的 `transition: transform .3s ease` 对齐；
- 反翻挂在 `.position` **之后**（只翻内容自身，不改变摆放位置）；
- 同步改掉当初写错的注释与文档（`Config.swift` / `README.md` / `check_clickthrough.sh`）。

### 23. 怎么把这个 bug 钉住（花了最久的一步）

这类「看起来没问题、像素上却是反的」最需要自动化，但**测起来很难**：
小鲸鱼本身既是深蓝又有大片白色，任何「在全图里找文字像素」的判据都会被它污染。
本轮先后试了四种，前三种都被鲸鱼带偏：

| 试过的判据 | 结果 |
|---|---|
| 白色包围盒内圈找文字 | ❌ 白色包围盒一直被鲸鱼拉到右下角，量到的其实是鲸鱼 |
| 全图找深蓝像素 | ❌ 同上（鲸鱼也是深蓝） |
| 「出泡 − 收泡」差值法 | ❌ 能消掉鲸鱼，但仍被泡泡描边的对称性稀释；两种朝向还拍错了配对 |
| **单独渲染 `BubbleLayer` + 位置无关字形掩码** | ✅ 干净、信号强 |

最终两条判据：

1. **整机是否翻转** → 角色图区域内像素的**重心 x**（鲸鱼左右不对称，镜像后换侧：0.758 → 0.448）；
2. **内容是否可读** → 单独渲染 `BubbleLayer`（不含鲸鱼），把文字像素**归一化到自身包围盒**
   后采样成 24×24 布尔网格，比较「同向差异」与「翻反差异」：
   **同向 3.6% vs 翻反 15.1%**（差约 4 倍）。
   归一化是关键 —— 镜像会把气泡整体挪到另一侧，用绝对坐标比对会全是差异。

另外补了两条对照断言：
- 「镜像 / 未镜像的气泡层**必须不同**」—— 若哪天有人删掉反翻，这条会先变红；
- 「关掉『贴左镜像翻转』开关后鲸鱼重心不动」。

---

## 三、源码结构
```
Sources/WhaleWidget/              （约 6900 行）
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

## 四、验证体系（258 项）

| 入口 | 覆盖内容 | 项数 |
|---|---|---|
| `--selftest` | 凭据解析 / 峰谷判定（含节假日边界、跨周末与跨长假倒计时）/ 计价 / 记账语义 / 定点精度 / DSH 历史导入 / 窗口定位 / 拖动跟随 / **吸附区宽度与四边独立** / 资源 / **真实联网拉余额** | 76 |
| `--hitcheck` | 命中遮罩逐像素准确性（只含角色本体）/ **click-through 路由** / **锁定语义** / **不透明度夹取** / **旧配置向后兼容** / **临时提醒与点击的关系** / 点击拖动判定 / 点击序列两种模式 / 菜单按钮独立性 | 95 |
| `--render` | 离屏渲染 + 像素断言（气泡填充/描边/文字、布局方位、文字不溢出气泡、逐页可渲染、**锁定角标**、**不透明度像素效果**、**镜像是「只翻朝向不翻内容」**） | 36 |
| `--e2e` | **起真实窗口 + 合成鼠标事件**走完整链路（点击序列、**同点连点状态轨迹**、拖动、菜单按钮冲突、透明区不响应、**锁定穿透 + 拖不动**、**不透明度像素效果**、**吸附到四边**、**窗口帧动画机制**、**朝向翻转**、**镜像后坐标映射**、**重置位置**） | 50 |
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

- [ ] **吸附手感**：现在吸附区是屏宽的 10%（1728px 屏约 173px），
      按参考实现的默认值。若觉得太「粘」，改 `Positioning.SnapDefaults` 里的比例即可
      （`--selftest` 与 `--e2e` 会自动跟着新值校验）。
      另外**上边刻意不吸附**（跟随参考实现 `T: 0`）—— 若你希望上边也吸，把
      `topPercent` 从 0 改成正数。
- [ ] **翻转阈值**：自由摆放时以**屏幕竖直中线**为界（对应参考实现的 `F = 50%`）。
      参考实现还允许把翻转线拖到任意位置（`F` 可配）。要不要也做成可配置？
- [ ] **锁定手感**：按 `./Scripts/check_clickthrough.sh` 的第 6–9 项核对 ——
      重点确认「点小鲸鱼所在位置是否真的落到了下层应用」，
      以及解锁入口（菜单栏 🐋 → 解锁挂件）是否好找。
- [ ] **不透明度下限 20% 合不合适？** 现在是刻意不为 0（免得挂件「消失」无从找回）。
      若你希望更淡（例如 10%），改 `AppConfig.opacityRange` 一处即可，测试会跟着走。
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

**AppKit 窗口几何（第四轮新增，全是实测踩出来的）**

- `NSWindow.animator().setFrameOrigin(...)` 在本项目里是 **no-op**：
  调用后立即读、与等 0.6 秒后再读，窗口都在原位。
  **不要用它做吸附动画** —— 否则「目标算对了、配置写了、窗口没动」。
  改用 `Timer` 逐帧 `setFrameOrigin` 插值（见 `PanelController.moveWindow`）。
  直接 `setFrameOrigin` 是可靠的，插值只是为顺滑。
- **窗口正在做位移动画时，不要用手势/点击去打断它**：
  动画期间窗口在移动，「按下 → 松开」两次事件的窗口坐标不同，
  同一个屏幕点会被换算成不同的视图坐标 → 位移判成拖动 → **点击被吞掉**。
  必须在 `mouseDown` 就取消动画。
- 动画期间**不要持久化位置**：此时 `window.frame` 是中间值，会把目标坐标覆盖掉
  （表现为「吸附生效了，重启又回到旧位置」）。
- 判定「贴左/贴右/朝向」要用**吸附后的目标位置**，不是当前位置。
- 建窗时原点默认 `(0,0)`，而 `(0,0)` 正是可见区域左下角 → 会被判成「贴左」。
  位置一旦改变（`restorePosition` / 拖动 / 吸附）**必须同步重算朝向与镜像**，
  否则容器会带着错误的镜像标记运行，合成点击的 x 全被镜像 → 一律落在透明区。
- 离屏（`x < -1000` 之类）没有「朝屏幕内」可言 → 朝向判定要保持现状，
  否则自检的离屏坐标会被误判成贴左并污染后续断言。

**构建 / 工程**

- `Package.swift` 的 `exclude` 里判断文件是否存在要用**绝对路径**
  （`URL(fileURLWithPath: #filePath).deletingLastPathComponent()`）：
  manifest 求值时的 CWD 不保证是仓库根目录，用相对路径会漏判 → 构建报
  `found N file(s) which are unhandled`
- 同理，只 exclude **确实存在**的路径，否则 SwiftPM 报 `Invalid Exclude … File not found`
- 临时输出目录（如 `--render` 的默认值）不要落在仓库里，否则会污染构建与 git 状态
- `Scripts/*.sh` 的可执行位易丢（只有 `package_app.sh` 带 x）——
  README 写的是 `./Scripts/xxx.sh`，缺 x 会直接 exit 126。改动脚本后顺手 `chmod +x`
- **长时间交互式任务会丢 stdout**：`--e2e` 在崩溃/被 kill 时缓冲输出会一起消失，
  看起来「一行都没打印」。排查时加 `NSUnbufferedIO=YES`。

**测试卫生**

- 非交互入口必须隔离状态目录（见「工作 8」）
- 像素断言要单独渲染目标层：整块面板里角色图也有白色与深蓝像素，
  会污染「文字包围盒」与「气泡包围盒」的判断
- 泡泡描边内侧的抗锯齿像素也是深蓝，统计文字包围盒必须内缩跳过描边带
- 构造「旧版本数据」样本要**从真实结构出发再删字段**：手写一个只含几个键的 JSON
  会把「早就有」的必填键也漏掉，于是失败原因与本次改动无关（第三轮又踩了一次）
- **状态泄漏**：拖动相关断言会真的把窗口拖到边缘并触发翻转（这是正确行为），
  后续各节用的取样坐标却是按未镜像算的 → 大面积假红。
  每节开始前先把窗口复位到已知状态（`--e2e` 里的 `parkNeutral()`）。
- **别把真实外部状态牵进断言**：余额提醒来自真实轮询，会在断言进行中异步插入
  临时泡泡，而 `handleTap` 遇临时泡泡只关闭、不推进 → 同一段断言时红时绿。
  自检下应关掉这类回调，另用确定性构造来覆盖其语义。
- **先确认跑的是新二进制**：本轮在旧构建产物上白排查很久。
  `--hitcheck` 现在会打印二进制路径与构建时间。

---

## 七、环境备注

- 本机只选了 Command Line Tools，但装了完整 Xcode（**未同意 license，`xcodebuild` 不可用**）。
  `Package.swift` 检测到 Xcode 存在时会把它的 SwiftUI 宏插件目录传给编译器，
  因此无需 `xcode-select` 切换即可 `swift build`。
- 长命令（`sleep` / 压测）会把同步终端卡住并吞掉后续输出 ——
  这类命令请走 `Scripts/*.sh` + VS Code task，或把输出重定向到文件再读。
