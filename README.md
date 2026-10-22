# Flickdown

极速的 macOS 原生 Markdown 查看器（也能编辑）。核心目标：**打开快、渲染快**。

名字由 Flick（轻弹）和 Markdown 组合而来：轻轻一弹，文档就已打开。

- Swift + AppKit 原生外壳，二进制约 420 KB，App 总体积约 4.6 MB（其中 3.5 MB 是按需加载的 Mermaid）
- [md4c](https://github.com/mity/md4c)（C）解析，约 **300 MB/s**：1 MB 文档 4 ms，20 MB 文档 70 ms
- 支持 GFM（表格、任务列表、删除线、自动链接）、脚注、`> [!NOTE]` 提示框、`==高亮==`
- 代码高亮（highlight.js）、数学公式（KaTeX，`$…$` / `$$…$$` / ```` ```math ````）、Mermaid 图表，**仅在文档用到且滚动到附近时才加载**
- 预览 / 源码 / 编辑三种模式（⌘1 / ⌘2 / ⌘3 或标题栏右侧按钮），切换时停留在同一位置
- 源码模式就是编辑器：原生文本编辑（行号、语法着色、撤销、查找、中文输入法）加左侧大纲，可直接修改
- 编辑模式：编辑器 + 右侧实时预览，两侧按源码行精确联动滚动
- ⌘S 保存，关闭或退出前提醒未存储的更改，文件被其他程序修改时询问保留哪个版本
- 目录大纲侧栏（滚动时自动高亮当前章节）、文件在外部保存后自动刷新并保持滚动位置
- 预览中查找（⌘F）：高亮全部匹配并显示「第几个 / 共几个」，可跨粗体、链接等格式匹配；源码和编辑模式用编辑器自带的查找
- 深色模式、缩放、打印、GBK/GB18030 编码自动识别

## 性能

在本机（Apple Silicon，macOS 27）用 `scripts/bench.sh` 测得，计时从执行 `open` 命令起，到文档首帧绘制完成：

| 场景 | 示例文档 (2 KB) | 1 MB 文档 | 5 MB 文档 | 20 MB 文档 |
|---|---|---|---|---|
| 冷启动（App 未运行） | ~390 ms | ~390 ms | — | — |
| 热打开（App 在后台） | ~120 ms | ~135 ms | ~170 ms | ~290 ms |

热打开的 120 ms 里约 75 ms 是 `open` 命令和 LaunchServices 本身的开销，App 内部从收到打开请求到首帧约 45 ms。

以源码模式打开时不用等 WebKit：同一时刻、同样的系统负载下，冷启动 322 ms，预览模式为 440 ms。大文件直接进编辑器，从收到打开请求到显示：1 MB 约 85 ms，5 MB 约 150 ms，20 MB 约 370 ms。用 `MODE=source scripts/bench.sh` 可测源码模式。

## 构建与使用

需要 Xcode（Swift 6）。

```bash
./scripts/build.sh
```

产物在 `build/Flickdown.app`，可拖到「应用程序」文件夹。在 Finder 里对任意 `.md` 文件「显示简介 → 打开方式 → 全部更改」即可设为默认查看器。

命令行打开：

```bash
scripts/flick README.md docs/*.md
```

| 快捷键 | 功能 |
|---|---|
| ⌘O | 打开 |
| ⌘S | 存储 |
| ⌘R | 重新载入 |
| ⌘1 / ⌘2 / ⌘3 | 预览 / 源码 / 编辑 |
| ⌘/ | 在预览和源码间切换 |
| ⌥⌘P | 编辑时显示 / 隐藏预览 |
| ⌃⌘S | 显示 / 隐藏大纲 |
| ⌘F | 查找（在预览中显示查找栏） |
| ⌘G / ⇧⌘G | 下一个 / 上一个匹配（查找栏里回车 / ⇧回车 同效） |
| ⌘E | 用所选文字查找 |
| ⌘= / ⌘- / ⌘0 | 放大 / 缩小 / 实际大小 |
| ⌥⌘R | 在访达中显示 |

## 为什么快

1. **WebView 预热**：WebKit 进程启动比解析 Markdown 慢两个数量级。App 启动第一件事就是创建 WKWebView 并加载模板页；之后始终保留一个预热好的页面，下一个文档直接用。默认源码模式时则相反：启动不碰 WebKit，窗口出来后再在后台预热，切到预览时直接可用。
2. **常驻后台**：关闭最后一个窗口后 App 不退出，下次打开省掉进程启动和 WebKit 启动。
3. **C 解析器**：md4c 单遍解析直接输出 HTML；超过 512 KB 的文件放到后台线程解析。
4. **首屏优先**：md4c 解析时记录每个顶层块的结束位置，大文档切成多段 HTML，第一段（约 48 KB）先渲染上屏，其余在首帧之后每帧追加一段，滚动不卡顿。切分点会避开 `<details>` 等跨块的原始 HTML 容器。
5. **源码模式用原生文本**：编辑器直接显示文字，不经过网页渲染；语法着色和行号只处理屏幕上可见的行。预览不可见时不渲染，切回预览时才更新。
6. **惰性增强**：代码高亮、KaTeX、Mermaid 都在首帧之后、且元素接近视口时才加载和执行；没有用到的库完全不加载。
7. **窗口先显示**：窗口创建后立即显示（背景色与页面一致，无闪烁），WebKit 首次可见时的初始化与模板加载并行进行。
8. **无 nib / storyboard**，菜单用代码构建；最近使用列表的更新推迟到打开完成之后。

## 源码 / 编辑模式的实现

- **编辑器**：原生 NSTextView（TextKit 1 + 非连续布局），第一次用到源码或编辑模式时才创建，只在预览里看文档不付出任何代价。打字延迟（含着色和行号刷新）中位数：1 MB 约 6 ms，5 MB 约 10 ms，20 MB 约 29 ms。
- **语法着色与行号**：只处理屏幕上可见的行（着色用临时属性，不触发重新排版），开销与文件大小无关；自动换行的长行只编一个行号。
- **大纲**：源码模式左侧列出标题，点击跳转，滚动时高亮当前章节；标题扫描只看以 `#`、`=`、`-` 开头的行，20 MB 文档约 200 ms。
- **实时预览**：停止输入后重新渲染（小文档 30 ms 后，大文档按大小延长），渲染在 WebKit 进程里进行，不阻塞打字。只替换 HTML 有变化的顶层块，其余块连同已渲染的代码高亮、公式和 Mermaid 图原样保留，不闪烁也不重算；外部修改触发的刷新同样如此。
- **滚动联动**：用过编辑器之后，md4c 给每个顶层块标注源码行号（`data-l`），预览与编辑器按行号插值对齐，而不是按百分比估算；只在预览里看文档时不生成这些标记。
- **保存**：先写临时文件再整体替换，写入失败不会留下半截文件；保留原文件的编码（UTF-8 / GB18030）、权限和元数据。有未存储的更改时禁止系统静默退出 App。

## 安全

文档中的原始 HTML 会被渲染，但页面有严格的 CSP：只允许 App 自带的脚本执行，内联事件处理器、iframe、表单、网络请求都被禁止。点击文档内的链接时，`.md` 在本 App 打开，网页交给浏览器，图片/PDF/文本用默认程序打开，脚本和可执行文件只会在访达中定位、不会运行。

## 目录结构

```
Package.swift
Sources/
  CMd4c/                 md4c v0.6.0（未修改）+ flick.c 包装层（输出 HTML、切分点与源码行号）
  Flickdown/
    main.swift           入口：最先预热 WebView
    AppDelegate.swift    打开文件、窗口管理、最近使用
    DocumentWindowController.swift  单个文档窗口：渲染、分段推送、视图模式、链接策略、菜单动作
    DocumentWindowController+Editing.swift  源码 / 编辑模式：布局切换、实时预览、滚动联动、保存与提醒
    MarkdownEditor.swift 原生源码编辑器：可见区域语法着色、行号、标题扫描
    SourceOutline.swift  源码模式的大纲侧栏
    FindBar.swift        预览的查找栏（第一次按 ⌘F 时才创建）
    RenderPage.swift     预热的 WKWebView 页面与页面池
    MarkdownRenderer.swift  调用 md4c，按切分点生成 HTML 分段，编码识别
    FileWatcher.swift    文件监听（兼容编辑器的原子保存）
    MainMenu.swift       菜单栏（中英文）
    Support.swift        本地化、偏好设置、计时
    DebugHooks.swift     基准测试 / 截图用的环境变量开关
  md-bench/              解析器吞吐量基准
Resources/
  Info.plist
  AppIcon.icns           应用图标（由 scripts/make-icon.swift 生成）
  web/index.html         页面骨架与样式（CSP 在这里）
  web/app.js             渲染、大纲、查找、与编辑器的行号联动、懒加载
  web/vendor/            highlight.js 11.12、KaTeX 0.19、Mermaid 11.17
scripts/
  build.sh               构建 .app
  bench.sh               端到端打开速度（冷 / 热）
  gen-sample.py          生成大体积测试文档
  make-icon.swift        用代码绘制应用图标并生成 AppIcon.icns：swift scripts/make-icon.swift
  flick                  命令行打开
samples/showcase.md      功能展示文档
```

## 基准测试与调试

```bash
scripts/bench.sh samples/showcase.md 7      # 冷/热打开耗时
python3 scripts/gen-sample.py 5 > /tmp/big.md
swift run -c release md-bench /tmp/big.md   # md4c 吞吐量
```

设置 `FLICK_BENCH=1` 运行时会在 stderr 打印启动各阶段耗时。其余开关（截图、强制深色、窗口尺寸等）见 `DebugHooks.swift`。

## 第三方组件

md4c（MIT）、highlight.js（BSD-3-Clause）、KaTeX（MIT）、Mermaid（MIT），许可证文件随源码一起放在各自目录中。
