# Flickdown 功能展示

这是一份用来检验渲染效果的示例文档，包含 **GFM** 的常用语法、代码高亮、数学公式和 Mermaid 图表。点击左侧大纲可以跳转，[跳到表格](#表格) 也可以。

> [!NOTE]
> 文件保存后，查看器会自动刷新并保持当前滚动位置。

## 文本样式

普通段落中可以有 *斜体*、**粗体**、~~删除线~~、==高亮==、`行内代码` 和 <kbd>⌘</kbd> + <kbd>F</kbd> 快捷键。自动链接： https://github.com/mity/md4c 。脚注也支持[^1]。

- 无序列表第一项
- 第二项
  - 嵌套项
  - 另一个嵌套项
- [x] 已完成的任务
- [ ] 未完成的任务

1. 有序列表
2. 第二步
3. 第三步

## 表格

| 方案 | 冷启动 | 解析 1 MB | 备注 |
|:-----|------:|---------:|:----:|
| 原生 + md4c | 快 | ~3 ms | 本项目 |
| Electron | 慢 | ~30 ms | 体积大 |
| 纯 JS 解析 | 中 | ~15 ms | — |

## 代码高亮

```swift
func render(_ url: URL) throws -> String {
    let data = try Data(contentsOf: url)
    return renderHTML(data) // md4c, single pass
}
```

```python
def fib(n: int) -> int:
    a, b = 0, 1
    for _ in range(n):
        a, b = b, a + b
    return a
```

```json
{ "name": "flickdown", "fast": true, "deps": 0 }
```

## 数学公式

行内公式 $E = mc^2$，以及欧拉恒等式 $e^{i\pi} + 1 = 0$。

$$
\int_{-\infty}^{\infty} e^{-x^2}\,dx = \sqrt{\pi}
$$

```math
\sum_{k=1}^{n} k = \frac{n(n+1)}{2}
```

## Mermaid 图表

```mermaid
flowchart LR
    A[打开文件] --> B{模板已预热?}
    B -- 是 --> C[md4c 解析]
    B -- 否 --> D[等待 WebKit]
    D --> C
    C --> E[注入 HTML]
    E --> F[首帧绘制]
```

## 提示框

> [!TIP]
> 用 ⌃⌘S 显示或隐藏大纲。

> [!WARNING]
> 文档里的脚本不会执行。

> 普通引用块：简洁就是速度。

## 图片

![本地 SVG 图片](images/logo.svg)

---

[^1]: 这是脚注内容。
