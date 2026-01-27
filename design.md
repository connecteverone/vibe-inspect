                |
| 核心 | 写测试 | 验证结果                 |
| 工具 | IDE | API / Terminal / VNC |
| 单位 | 测试  | 一次验证动作               |

---

## 四、整体产品架构图（逻辑）

```
┌────────────────────────────┐
│        Mobile App           │
│                            │
│  ┌──────── Timeline ─────┐ │
│  │  API Call              │ │
│  │  Terminal Run          │ │
│  │  AI Suggest            │ │
│  │  VNC View              │ │
│  └──────────────────────┘ │
│            ▲               │
│            │               │
│      Command Bar            │
│            │               │
│  ┌──────── Action Layer ─┐ │
│  │ API Explorer           │ │
│  │ Terminal Manager       │ │
│  │ VNC Viewer             │ │
│  └──────────────────────┘ │
└─────────────▲──────────────┘
              │
┌─────────────┴──────────────┐
│        Cloud Runtime        │
│  VM / K8s / Desktop / API  │
└────────────────────────────┘
```

---

## 五、核心模块一：Timeline（时间线 = 产品灵魂）

### 5.1 为什么是时间线

* 手机不适合多窗口
* 人的思维是“事情发生顺序”

> 时间线 = **用户的验证思维外化**

### 5.2 Timeline 事件类型

| 类型       | 示例                |
| -------- | ----------------- |
| API      | POST /login → 500 |
| Terminal | npm test          |
| AI       | Schema missing    |
| VNC      | Login UI          |

### 5.3 时间线交互示意

```
09:12  API  POST /login → 500
09:12  AI   字段 password 缺失
09:13  API  Retry → 200 OK
09:14  Terminal  run server
09:15  VNC  Check login page
```

点击任意一行 → 回到对应上下文

---

## 六、核心模块二：Command Bar（唯一入口）

### 6.1 定位

> Command Bar = **手机上的“开发中枢”**

不是聊天框，而是 **Intent Parser**。

### 6.2 示例

```
> P# 移动端 AI IDE + 验证驱动开发（VDD）产品完整方案

> **一句话定义**：一个以“验证”为核心、为手机而生的 AI IDE。
> 不追求在手机上完整写代码，而是 **随时随地完成：验证 / 调试 / 确认 / 回滚**。

---

## 一、产品背景与机会判断

### 1.1 行业现状

* AI IDE（Claude Code / Codex / Cursor）严重依赖 **本地电脑环境**
* 移动端产品要么是：

  * 远程桌面（VNC / RDP）→ 交互灾难
  * 纯 Chat → 无法验证

### 1.2 用户真实痛点（你的场景就是典型）

* 在路上 / 非办公场景
* 有云上完整环境（K8s / VM / 桌面）
* **卡在“验证一步”必须回到电脑**

> 结论：
> **不是“手机写代码”需求，而是“手机完成一次开发闭环”需求**。

---

## 二、产品定位

### 2.1 核心定位

> **Mobile-first Verification-driven Development IDE**

关键词：

* Mobile-first
* Verification
* AI-assisted
* Cloud-backed

### 2.2 明确不做什么

❌ 不做完整 IDE（VS Code 替代）
❌ 不追求长时间 VNC 操作
❌ 不在手机上承载大规模代码编辑

---

## 三、核心产品理念：VDD（验证驱动开发）

### 3.1 与 TDD 的区别

| 维度 | TDD | VDD                  |
| -- | --- | -------------------- |
| 场景 | 桌面  | 移动优先 OST /login
> Run backend server
> Explain last error
> Open login page
```

AI 负责：

* 动作识别
* 参数补全
* 路由到 API / Terminal / VNC

---

## 七、核心模块三：API Explorer（简易 Postman）

### 7.1 设计原则

* 为“验证”而生
* 结构化 > 文本

### 7.2 界面结构

```
[ Method ]  POST
[ URL ]     /api/login
[ Params ]  (fold)
[ Headers ] (fold)
[ Body ]    JSON Schema
-----------------------
Status 200 | 42ms
-----------------------
Response Tree View
-----------------------
AI Analysis
```

### 7.3 强化点（相对 Postman）

* JSON Tree 折叠
* Diff 上一次响应
* 错误字段高亮
* Path 一键复制

---

## 八、核心模块四：Multi-session Terminal

### 8.1 为什么必须多会话

* 一个服务启动
* 一个测试
* 一个 log tail

### 8.2 结构示意

```
[ Session A ] [ Session B ] [ + ]
--------------------------------
> npm run dev
[stdout]
[stderr]
[ai suggest]
```

### 8.3 手机优化点

* 结构化输出
* 快捷键按钮（Ctrl+C / ↑）
* AI 命令映射

---

## 九、VNC 的正确使用方式（兜底但高级）

### 9.1 定位

> **验证 UI，而不是写代码**

VNC 是“最后一步确认工具”，必须：

* 极短进入
* 极快操作
* 极易退出

### 9.2 核心交互模式（为手机重新发明 VNC）

#### 🎯 双手协同模型（Two‑hand Model）

* **右手：触控板（Trackpad Mode）**

  * 单指移动 → 鼠标移动
  * 单指点击 → 左键
  * 双指点击 → 右键
  * 双指滑动 → 滚轮

* **左手：缩放控制条（Zoom Bar）**

  * 左滑 → 缩小视图（Zoom Out）
  * 右滑 → 放大视图（Zoom In）
  * 始终以「鼠标指针为中心」进行缩放

> 设计目标：
> **右手永远不用离开“控制”，左手永远不用点按钮**。

---

### 9.3 放大镜 + 鼠标中心聚焦机制（关键创新点）

#### 放大逻辑

* VNC 画面并非整体放大
* 而是：

```
鼠标位置 = 缩放中心
放大 = 局部区域放大
```

效果类似：

* IDE 中的 minimap + zoom
* 精准点小按钮（checkbox / icon / close）

#### 放大镜 Bar 视觉示意

```
[  ◀───────●───────▶  ]
   小            大
```

* 中点：1x
* 左滑：0.5x / 0.75x
* 右滑：1.5x / 2x / 3x

---

### 9.4 鼠标指针强化设计

为避免“丢指针”：

* 鼠标指针始终高对比（白 + 黑边）
* 缩放时指针有 **轻微吸附动画**
* 快速双击 Zoom Bar → 回到 1x 并居中

---

### 9.5 快捷操作区（右下角浮层）

```
[ Esc ] [ Cmd ] [ Tab ] [ ⌨ ]
```

* Esc：关闭弹窗 / 退出全屏
* Cmd：修饰键
* Tab：切焦点
* ⌨：调出虚拟键盘（少量输入）

---

### 9.6 进入 / 退出 VNC 的心理成本控制

#### 进入方式

* Timeline 点击事件 → 半屏 Overlay
* Command Bar：`open login ui`

#### 退出方式

* 向下滑 → 立即退出
* 不弹确认框

> 原则：
> **VNC 不应该让用户有“我是不是要认真坐下来操作”的心理负担**。

---

## 十、完整用户流程示例

### 场景：修一个 API Bug

```
Command Bar → POST /login
↓
API 500
↓
AI 提示字段缺失
↓
修改 Body
↓
200 OK
↓
Terminal Run Server
↓
VNC Check UI
```

> **全流程在手机完成**

---

## 十一、商业与市场判断

### 11.1 目标用户

* 云原生工程师
* 后端 / SRE / DevOps
* 创业者 / 独立开发者

### 11.2 付费意愿点

* 私有环境接入
* 多 Workspace
* 团队协作 Timeline

---

## 十二、MVP 版本拆解

### MVP v1（4–6 周）

* Timeline
* Command Bar
* API Explorer
* Terminal（2 session）
* AI Suggest 基础

### MVP v2

* VNC 模块
* API 模板
* Terminal Preset

---

## 十三、产品成功指标

* 单次 Session 完成验证 ≥ 1 次
* API → Terminal 跳转率
* VNC 使用频率 < 20%（说明设计成功）

---

## 十四、总结一句话

> **这不是一个“手机 IDE”，而是一个“把开发最后一步：验证，彻底重构为移动体验”的产品。**

---

# 附录 A：VNC 触控板 + 放大镜模式设计文档（可直接交付设计 / 工程）

## A1. 设计目标（Design Goals）

1. 在 6–7 英寸屏幕上完成 **像素级点击**
2. 单次 VNC 使用时长 < 60 秒
3. 不占用认知资源（无需思考“怎么操作”）

---

## A2. 交互模型总览

### A2.1 双手模型（Two-hand Interaction Model）

```
┌───────────────────────────┐
│        VNC View            │
│                           │
│   ┌───────────────┐       │
│   │               │       │
│   │   Remote UI   │       │
│   │               │       │
│   └───────────────┘       │
│                           │
│  [Trackpad Area]  [Zoom]  │
│   (Right Hand)   (Left)   │
└───────────────────────────┘
```

* 右手区域：虚拟触控板（不可滚动页面）
* 左侧竖向或横向：缩放 Bar

---

## A3. 触控板（Trackpad Mode）设计细节

### A3.1 手势映射

| 手势   | 行为   |
| ---- | ---- |
| 单指移动 | 鼠标移动 |
| 单指点击 | 左键   |
| 双指点击 | 右键   |
| 双指滑动 | 滚轮   |
| 长按   | 拖拽   |

### A3.2 加速曲线

* 默认：macOS trackpad 加速曲线
* 快速滑动 → 指针加速
* 慢速移动 → 像素级精度

> 关键：**慢即准，快即远**

---

## A4. 缩放 Bar（Magnifier Bar）设计

### A4.1 位置

* 默认：左侧垂直
* 可配置：底部水平（iPad / Android 大屏）

### A4.2 行为定义

```
缩放中心 = 当前鼠标坐标
```

* 左滑：Zoom Out（0.5x / 0.75x）
* 中点：1x
* 右滑：Zoom In（1.5x / 2x / 3x）

### A4.3 动画

* 缩放时 UI 有轻微惯性
* 鼠标指针有吸附 + 高亮圈

---

## A5. 放大镜渲染策略（工程向）

### A5.1 不是全屏缩放

而是：

```
Render = Crop(remote, mouse_center, scale)
```

优点：

* 不破坏整体布局
* 性能稳定
* 操作直觉强

---

## A6. 快捷键浮层

### A6.1 默认按钮

```
[ Esc ] [ Cmd ] [ Tab ] [ Ctrl ] [ ⌨ ]
```

* 固定在右下角
* 半透明
* 单手可点

---

## A7. 进入 / 退出流程

### A7.1 进入

* Timeline → 点击 VNC 事件
* Command Bar：`open ui`

### A7.2 退出

* 下滑手势
* 无确认
* 自动记录到 Timeline

---

# 附录 B：API Explorer 设计规范

## B1. 页面结构

```
┌──────── API Request ───────┐
│ Method | URL               │
│ Params (fold)              │
│ Headers (fold)             │
│ Body (JSON Tree)           │
└───────────────────────────┘
┌──────── Response ──────────┐
│ Status | Time | Size       │
│ Headers (fold)             │
│ Body (Tree / Raw)          │
└───────────────────────────┘
┌──────── AI Analysis ───────┐
│ Error / Suggestion         │
└───────────────────────────┘
```

---

# 附录 C：Multi-session Terminal 设计规范

## C1. Session 管理

* 每个 Session 独立 stdout / stderr
* 状态标记：Running / Done / Error

## C2. 输出结构化

```
[STDOUT]
[STDERR]
[AI]
```

---

# 附录 D：工程拆解建议（MVP）

## D1. Client

* iOS / Android Native
* Gesture Engine
* AI Context Manager

## D2. Server

* Session Gateway
* Terminal Proxy
* API Runner

---

> **到这里，这已经不是“想法”，而是一份可以直接开工的产品与交互设计文档。**

如果你下一步需要，我可以继续帮你：

* 拆 Jira / Linear 级别的任务
* 出 iOS / Android 事件处理伪代码
* 写一份「为什么这个产品一定要用 Native」的技术宣言

