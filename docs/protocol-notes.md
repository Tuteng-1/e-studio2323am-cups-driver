# 协议笔记：e-STUDIO2323AM / 2823AM GDI 引擎

本文只记录**实测**结论。所有结论都来自 `eSTUDIO2323AM-captures/` 里的 25 份
实体 Windows 驱动抓包，并且已用 `make test-capture` 做逐字节回归。

## 1. 数据流

```
PDF → cgpdftoraster → CUPS raster → rastertoestudio → PJL + JBIG → socket://ip:9100
```

设备不认识 PostScript、PCL 或原始位图，只接受 **PJL 信封 + JBIG-1 (T.82)** 位图。
`@PJL SET COMPRESS=JBIG` 在 `eSSh6OCM.dll` 里是硬编码常量，没有第二种压缩方式
（`COMPRESS=NONE` + 裸 1bpp 实测被设备忽略、不计数）。

## 2. 作业信封

```
ESC%-12345X@PJL
@PJL SET TIMESTAMP=2026/10/29 14:33:39
@PJL SET COMPRESS=JBIG
@PJL SET USERNAME=00000
@PJL SET COVER=OFF
@PJL SET HOLD=OFF
@PJL SET ROTATESORT=OFF
@PJL SET SMOOTHING=OFF
@PJL SET TONERSAVE=OFF
@PJL SET DEPTCODENUM=""
@PJL SET MEDIASOURCE=AUTO
@PJL SET MEDIATYPE=PAPER
@PJL SET PAGESTATUS=START
@PJL SET COPIES=1
@PJL SET DUPLEX=OFF
@PJL SET PAPER=A4
@PJL SET PAPERWIDTH=4961
@PJL SET PAPERLENGTH=7016
@PJL SET RESOLUTION=600
@PJL SET ORIENTATION=PORTRAIT
@PJL SET IMAGELEN=130
<二进制块>
@PJL SET DOTCOUNT=0
@PJL SET PAGESTATUS=END
@PJL EOJ
ESC%-12345X
```

- 前 9 条（TIMESTAMP…DEPTCODENUM）每个作业只发一次；从 `MEDIASOURCE` 起每页发一次。
- 行尾一律 `CRLF`；`ESC%-12345X` 与 `@PJL` 之间不加换行。
- 多份打印时，Windows 驱动是**整份作业重复 N 次**，每次以 `@PJL COPYEND` 结束，
  只有最后一份发 `@PJL EOJ`；每份的 `COPIES` 都是 1（设备不认 COPIES）。
  filter 采用同样的做法。

## 3. 二进制块

每页一个完整 BIE（jbigkit 的 BIH + SDE），20 字节头就是标准 JBIG BIH：

| 偏移 | 字段 | 实测值 |
|---|---|---|
| 0 | DL / DH | 0 / 0（单一分辨率层） |
| 2 | planes | 1 |
| 3 | 保留 | 0 |
| 4 | XD 宽（大端） | A4 4961 |
| 8 | YD 高（大端） | A4 7016 |
| 12 | L0 | 128 |
| 16 | MX | 0（不做自适应模板） |
| 17 | MY | 0 |
| 18 | order | 3（ILEAVE \| SMID） |
| 19 | options | 0x48（LRLTWO \| TPBON） |

尺寸换算：`px = round(mm / 25.4 × 600)`。实测 A4 4961×7016、A3 7016×9921、
A5 3496×4961、Letter 5100×6600、100×150mm 2362×3543。

**分块**：首块 `IMAGELEN = 20 + 65536 = 65556`，之后每块 65536，最后一块为余数。
切点可以落在数据流任意位置。

**DOTCOUNT** = 本页黑像素总数（1bpp 里置位的 bit 数）。设备用它判空：
`DOTCOUNT=0` 的页会被跳过、不计数。

### 编码参数是从抓包逐字节复现出来的

对 `07_text` 解码出的位图重新编码，得到 1601 字节，与原抓包**完全一致**：

```
pbmtojbg -q -o 3 -p 72 -s 128 -m 0 in.pbm out.jbg
```

一个容易踩的坑：设备端的编码器**不删除**每条带算术编码器 flush 之后的
尾部 `0x00` 填充（每条带 6~9 字节），而上游 jbigkit 会调用
`jbg_buf_remove_zeros()` 把它们删干净。虽然两种流都能被解码，但只有保留这些
填充字节才能与设备抓包逐字节相同。为此 `third_party/jbigkit/jbig.c` 加了一个
`ESTUDIO_KEEP_SDE_ZEROS` 编译开关（`make` 默认打开）。

## 4. 抓包之外、由本驱动负责的部分

- **可打印区**：CUPS 交给 filter 的 raster 只有**可打印区**（PPD `*ImageableArea`），
  例如 A4 是 4763×6818 而不是 4961×7016。`*ImageableArea` 四边留 99 px
  （600dpi 下 11.88 pt ≈ 4.19 mm），这个数字来自抓包：五种纸型上驱动 DC 的
  (0,0) 都落在整页位图的 (99,99)。filter 把 raster 居中贴回整页位图，
  偏移 `(4961-4763)/2 = 99px`，纸面绝对位置与 Windows 驱动一致。
- **半色调**：Windows 驱动在 GDI 里就用 `TEXT.600x600.hft` / `PHOTO.600x600.hft`
  把灰度/彩色抖动成 1bpp。CUPS 侧一般直接给 1bpp（cgpdftoraster），
  若上游给 8bpp/彩色，filter 用 8×8 Bayer 抖动。
- **方向**：抓包里 `ORIENTATION=LANDSCAPE` 时，位图仍然是 4961×7016 的纵向
  页框，内容被驱动旋转过（原始左上角落到纸面左下角），即 90° 逆时针。
  正常 CUPS 队列里 pdftopdf 会先按 `orientation-requested=4` 把内容转进纵向
  页框，此时 filter 只置 `ORIENTATION=LANDSCAPE`，不再二次旋转；
  如果上游直接给横向 raster（宽 > 纸宽），filter 自己旋转 90° 逆时针。
  **2026-10-30 实机确认方向正确**，`rotate_mono()` 无需改动。

## 5. 尚未实测的部分

| 项目 | 现状 |
|---|---|
| 空白页 | `DOTCOUNT=0` 的页被设备跳过（与 Windows 驱动行为一致）。 |
| 双面 | 2323AM/2823AM 无自动双面单元：PPD 不提供 `Duplex`，filter 恒发 `DUPLEX=OFF`。 |
| 300dpi | 设备只有 600dpi 引擎，选 300 时 Windows 驱动会 2× 放大后仍发 `RESOLUTION=600`。PPD 只提供 600。 |

## 6. jbigkit 许可

`third_party/jbigkit/` 是 Markus Kuhn 的 jbigkit 2.1，**GPL-2 或更新版本**
（见 `third_party/jbigkit/COPYING`），随本项目一起分发。唯一的本地修改是上面
提到的 `ESTUDIO_KEEP_SDE_ZEROS` 开关，其余原样。
