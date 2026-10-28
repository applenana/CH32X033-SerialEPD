# 四色电子纸开源算法调研与实现计划

> 2026-10-29 更新：下文为历史调研记录。其中向中点收缩的压缩实现已废弃；当前算法、实际借鉴范围、图像复核和验证结果以 [压缩副作用修正](compression-review-2026-10-29.md) 为准。

更新时间：2026-10-28。本文固定本轮对约十个开源项目的调研结论，并记录 Ink Studio 后续实现的边界。目标屏幕是华为拆机四色屏，原生传输仍然只有 2bpp 黑、白、黄、红四种墨色。灰阶和彩色过渡来自空间网点混合，不能把软件算法误认为增加了硬件色阶。

## 结论先行

最值得移植的方向不是继续堆叠传统误差扩散，而是把“屏幕真实颜色”和“协议色号”分开：先用实测色板描述四种墨色在当前面板、光源和拍摄条件下的 RGB 结果，再在线性光中把输入颜色映射到这四个实测点的凸包，最后按覆盖率生成网点。输入超出色域时进行动态范围压缩，优先保留明暗关系，避免把蓝青区域硬推成刺眼红黄。AUTO 应该在真实四色结果上继续评价彩点、颗粒、近白污染和边缘损失。

## 项目逐一分析

| 项目 | 主要方法 | 可借鉴点 | 本项目取舍 |
| --- | --- | --- | --- |
| [OpenDisplay/epaper-dithering](https://github.com/OpenDisplay/epaper-dithering) | 多色电子纸调色、感知距离、DBS | 实测色板、加权 OKLab、色调和色域压缩 | 借鉴思路；DBS 已移植为 Dart 的保色邻点交换 |
| [Frans-Willem/epd-dither](https://github.com/Frans-Willem/epd-dither) | 颜色空间几何、重心坐标、多色覆盖率 | 把颜色拆成多个墨色的覆盖比例，再分配空间网点 | 使用独立实现的四点仿射覆盖率求解，避免最近色造成色阶跳变 |
| [paperlesspaper/epdoptimize](https://github.com/paperlesspaper/epdoptimize) | 校准色板、线性光、蓝噪声、动态范围和纸白保护 | “测得的屏幕颜色”必须和“设备原始色码”分离；蓝噪声减少低频团块 | 当前最重要的实现参考；加入可持久化实测色板和动态范围压缩 |
| [aitjcize/esp32-photoframe](https://github.com/aitjcize/esp32-photoframe) | 实测墨色与理论输出分离、S 曲线、色域处理 | 实际反射色决定最终观感，理论 RGB 调色板只能作为默认值 | 采用校准色板，但不把其他屏幕的数值冒充华为屏数据 |
| [TjarcoKerssens/spectra-6-paintings](https://github.com/TjarcoKerssens/spectra-6-paintings) | 按色相处理、局部色域压缩、Burkes | 肤色、天空、红黄等区域不应使用完全相同的饱和度策略 | 先提供通用动态范围压缩；按语义区域的增强留给后续 AUTO 研究 |
| [guysie/OpenDithering](https://github.com/guysie/opendithering) | Auto Expose、Color-tune、Hue-tune、DBS | 自动曝光、色调微调和视觉尺度目标函数 | AUTO 已有两轮候选搜索；将校准色板误差纳入后续评分 |
| [robertkist/libdither](https://github.com/robertkist/libdither) | LAB76/94/2000、线性 RGB、HSV、Tetrapal、DBS | 可离线比较不同距离函数和量化器 | 适合作为离线实验基线，不直接增加移动端算法菜单 |
| [robertkist/Ditherista](https://github.com/robertkist/Ditherista) | 可编辑调色板、线性色彩、多量化器和抖动 | 调色板应可查看和复现，算法比较要使用同一输入 | UI 先保留简洁；调色板以校准 JSON 保存 |
| [mattcarter11/eink-dithering-tester](https://github.com/mattcarter11/eink-dithering-tester) | RGB/CIELAB Floyd、选色方法和扩散核对比 | 没有一种抖动对所有图像都最好，必须统一样本比较 | 传统抖动只保留 Floyd、Burkes、Stucki；新算法用线性光覆盖和 DBS |
| [wiwiwei/ink-nfc-lab](https://github.com/wiwiwei/ink-nfc-lab) | 面向华为屏的 OKLab、蛇形 Floyd、低彩度/冷色保护 | 目标屏是黑白黄红四色；冷色保护应减少误映射到暖色 | 已实现自然映射；确认没有原生蓝色或第五色 |
| [kur0neko/huawei-epd-pn532](https://gitee.com/kur0neko/huawei-epd-pn532) | 华为四色屏、Atkinson、Floyd–Steinberg | 验证硬件色码和刷新流程，提供可用的传统抖动基线 | 算法参考保留，但 Atkinson 不进入当前菜单 |
| [jannickinspired/EPaper-Converter](https://github.com/jannickinspired/EPaper-Converter) | 六色调色板、饱和度、锐化、亮度/对比度、Floyd/Atkinson | 预处理链会显著影响量化结果 | 只借鉴预处理顺序；避免无校准的饱和度增强把蓝色推成红黄 |

## 算法取舍

### 实测色板

软件同时保存四个 3 通道浮点颜色，顺序固定为黑、白、黄、红。它们是屏幕在统一拍摄条件下显示纯色测试页后的光学 RGB 值；2bpp 协议色号仍然是 0、1、2、3，不随校准值变化。没有启用校准或校准数据不合法时，回退到理想色板 `K=(0,0,0) W=(1,1,1) Y=(1,1,0) R=(1,0,0)`。

建议采集流程：显示四个全屏纯色块，固定曝光、白平衡、距离和环境光；每块取中心区域中位数；保存为 0～255 RGB。黑白亮度差必须足够大，避免退化矩阵。校准值不能跨面板、跨光源直接复用。

### 四点凸包和覆盖率

输入 sRGB 先转换为线性光。四个实测颜色组成一个四面体，求解 `[K W Y R; 1 1 1 1] * weights = [r g b 1]`，得到四种墨色覆盖率。负覆盖率会被截断并归一化，实际输出仍是四种墨色。与“选一个最近色”相比，覆盖率能连续表达灰阶和低饱和过渡，后续蓝噪声/DBS 只负责把比例变成空间网点。

### 动态范围压缩

真实四色屏的可表示色域远小于 sRGB，特别是蓝、青和高饱和紫色。当前实现提供 0～1 的动态范围参数：在送入凸包前，将输入通道向中点收缩，强度越高越少产生极端覆盖率。默认值为 0；用户可以在理想色板或实测色板下直接调节。它不是“生成蓝色”，而是减少超色域颜色被强行拉向红/黄后的突兀感。后续可将简单中点压缩升级为 OKLCH 的色度压缩，并由 AUTO 依据蓝色区域和边缘误差选择强度。

### 局部色域压缩和自然映射

自然映射先识别低彩度/冷色区域，降低暖色墨点泄漏；动态范围压缩负责全局输入色域，二者作用阶段不同。纯黑、纯白、纯红、纯黄和近中性灰不会被不必要地扰动。传统扩散模式使用实测色板进行 OKLab 选色，DBS/蓝噪声模式使用四点覆盖率。

### AUTO 的后续接入

AUTO 已有“原图分析 → 真实四色结果复评”的两轮结构。下一步应把实测色板下的：覆盖率异常、蓝青区域色差、暖色泄漏、实测白点偏灰和黑点偏亮，加入 `AutoMetrics`，再比较动态范围、色域压缩和抖动模式。候选数量必须受限，保证 Windows 和 Android 不会因全分辨率搜索而失去响应。

## 当前实现边界

- 固件协议和设备传输不变，仍传输 2bpp 原生四色帧。
- 真实硬件色板尚未由本项目自动采集；需要用户用统一条件拍摄或输入测量值。
- 软件指标是代理指标，不能替代实体屏幕在不同光线、观看距离和面板批次下的视觉验收。
- 普通四色屏不能通过抖动真实生成蓝色；蓝色区域只能保留亮度、灰阶和边缘层次。

