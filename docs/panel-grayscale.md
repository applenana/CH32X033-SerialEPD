# 华为 768×552 四色屏：灰度能力核查

核查日期：2026-10-28。结论：**当前 A0 / A1 驱动明确只支持黑、白、黄、红四个像素状态；未找到适用于这块拆机屏且经过验证的多级灰度 / 每色多级浓度驱动。** 这不等于证明玻璃在任何实验波形下都不可能出现中间色；只是目前没有依据把它作为可用功能开放。

## 查到的直接证据

| 项目 | 检查位置与结果 |
| --- | --- |
| [MoInk 驱动](https://github.com/atunverse/moink/blob/main/src/epd_drv.c)及 [README](https://github.com/atunverse/moink/blob/main/README.md) | 用户指定的同尺寸华为拆机屏参考。A0 / A1 均写 2bpp 数据，公开色码为 0 黑、1 白、2 黄、3 红；没有针对该屏的灰阶 LUT 或多级彩色像素入口。 |
| [InkSight 华为适配](https://github.com/krstc/InkSight_adapt_HUAWEI_eink/blob/main/firmware/src/epd_driver.cpp) | `EPD_PANEL_38_JD79665_BWRY` 路径，`epdWriteMapped2bpp()` 将每个像素 `& 0x03` 后写入 0x10，再执行四色刷新。代码里的其他面板快刷 / LUT 路径不代表华为面板支持灰阶。 |
| [Pimoroni Inky JD79668](https://github.com/pimoroni/inky/blob/main/inky/inky_jd79668.py) | 同类控制器公开驱动只有 BLACK、WHITE、YELLOW、RED；图像量化为四项调色板。它不是本块玻璃的灰阶验收证据。 |
| [FMSC NFC 项目](https://github.com/solar2ain/ink-nfc-fmsc-by-pn532) | 将华为 A0 / A1 / A1.1 列为 `JD79665AA-552x768-BWRY`；`GRAY4` 是独立颜色类型。NFC 项目的供电、布局与本项目 SPI 路径不同，不引入其实验驱动。 |
| [Waveshare epd4in2.py](https://github.com/waveshareteam/e-Paper/blob/master/RaspberryPi_JetsonNano/python/lib/waveshare_epd/epd4in2.py) | 真正四灰阶例子：明确声明 GRAY1…GRAY4，提供 `EPD_4IN2_4Gray_lut_*` 和 `Gray_SetLut()`。这是另一种面板的专用波形，不能移植名字后直接驱动华为四色屏。 |

社区对控制器有 JDY79668、JD79665 等不同命名，因此不能只凭芯片名或分辨率判断波形兼容。尤其不能把某款黑白屏的灰度 LUT 当作通用参数。

## 三种“灰度”不是一回事

- **原生四灰阶**：单个物理像素稳定显示白、浅灰、深灰、黑，需要匹配面板的波形。它不是黑白黄红四色。
- **每色多级浓度 / 多级彩色**：需要额外的像素状态及经过验证的驱动流程。当前参考代码没有这种支持。
- **视觉灰阶与混色**：用不同位置、不同数量的四色像素，让人眼在观看距离上融合出明暗和近似颜色。本软件的蓝噪声和 DBS 属于此类；导出的 PNG 放大后仍只有四种颜色。

**2bpp 本身不能证明是否有灰阶**，因为它也能编码四种灰。决定意义的是驱动规定的四个状态。当前 SEP/1 格式 1 明确将两个比特用作 BWYR 色号；若直接把黄红改称浅灰深灰，实体屏仍会显示黄红。

## 本次软件处理

保持 SEP/1 和固件四色波形不变，不增加未经支持的“硬件灰度”按钮。感知重建先做线性光覆盖率分解，再优化网点分布，能够表现视觉灰阶；中性灰只使用黑白，保留纯四色和纸白保护。黑白照片可将饱和度设为 0，再使用感知重建。

传统抖动只保留 Floyd–Steinberg、Burkes、Stucki，另有两种新重建和直接量化，共 6 项。筛选依据和限制见 [重建研究](image-reconstruction.md)。

将来若取得**准确面板标识、匹配的灰度波形 / 驱动、色码与实测样张**，应先独立验收，再为 SEP/1 分配新像素格式和能力标识，让 Flutter 依据设备能力开放灰阶映射；不能悄悄重定义现有 format=1。
