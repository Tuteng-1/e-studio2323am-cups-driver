# e-STUDIO2323AM / 2823AM GDI 打印流：实测结论

抓包机器：一台 x64 Win11 22000 机器（主机名已隐去）
驱动：`TOSHIBA e-STUDIO2823AMSeries GDI`（`essh6.inf_amd64_d7e5f2af3ec4e476`）
打印处理器：`eSSh6PPR`　实体机：`TOSHIBA e-STUDIO2323AM`（序列号与内网地址已隐去）
抓包方式：独立队列 `eSTUDIO-CAPTURE` → Local Port → 落盘（全程未触达实体机）
验证方式：TopAccess 页计数器（`http://<打印机IP>/H10_Counter.htm`）

---

## 1. 协议就是 PJL + JBIG，不是私有命令流

清单原来假设的「cmd 3 / cmd 8 / cmd 4 / cmd 35」并不存在。这个驱动发出的是：

```
ESC%-12345X@PJL \r\n
@PJL SET TIMESTAMP=2026/10/29 14:33:25
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
@PJL SET IMAGELEN=130\r\n
<二进制块>
@PJL SET DOTCOUNT=0
@PJL SET PAGESTATUS=END
@PJL EOJ
ESC%-12345X\r\n
```

### 二进制块

20 字节头就是标准 JBIG-1 的 BIH（整个二进制块是一个完整 BIE）：

| 偏移 | 长度 | BIH 字段 | 实测值 |
|---|---|---|---|
| 0 | 1 | DL | 0 |
| 1 | 1 | DH | 0（单一分辨率层） |
| 2 | 1 | planes | 1 |
| 3 | 1 | 保留 | 0 |
| 4 | 4 | XD 页宽（像素，大端） | A4: 4961 |
| 8 | 4 | YD 页高（像素，大端） | A4: 7016 |
| 12 | 4 | L0 分带行数 | 128 |
| 16 | 1 | MX | 0（不做自适应模板） |
| 17 | 1 | MY | 0 |
| 18 | 1 | order | 3（ILEAVE \| SMID） |
| 19 | 1 | options | 0x48（LRLTWO \| TPBON） |
| 20 | n | SDE 数据流 | 每条带以 `FF 02`（SDNORM）结束 |

宽度换算：`px = round(mm / 25.4 * 600)`。实测 A4=4961、A3=7016、A5=3496、Letter=5100、100×150mm=2362×3543。

**分块规则**：首块 `IMAGELEN = 20 + 65536`（65556），之后每块 65536，最后一块为余数。分块可以切在流中间任意位置。

### 判定 JBIG 的依据

1. `@PJL SET COMPRESS=JBIG` 是 `eSSh6OCM.dll` 偏移 95424 处的**硬编码字符串**，驱动没有第二种压缩模式。
2. 每页 `FF 02` 出现次数**恰好 = ceil(YD / 128)**：A4 55、A3 78、A5 39、Letter 52、100×150 28（五组全中）。
3. 1px 棋盘格（熵最大）压到 3132 字节 —— 只有算术编码能到这个量级。
4. 空白页整个页面只有 55 个 `FF 02`，没有任何编码数据 —— 标准 JBIG 在极偏概率下确实可以零输出。
5. 用 jbigkit 直接解码 `01`/`06`/`07` 能还原出全白 / 1px 棋盘格 / 文字页，黑点数与 `DOTCOUNT` 完全吻合。
6. 把解码出的位图用 `pbmtojbg -q -o 3 -p 72 -s 128 -m 0` 重新编码，输出与抓包**逐字节相同**
   （唯一例外见下文「SDE 尾部零字节」）。

---

## 2. 完整的 PJL 词汇表（从 eSSh6OCM.dll 提取，共 26 条）

```
@PJL SET COMPRESS=JBIG                 ← 唯一值
@PJL SET DUPLEX=ON | OFF
@PJL SET BINDING=LONGEDGE | SHORTEDGE  ← 双面装订方向
@PJL SET TONERSAVE=ON | OFF
@PJL SET SMOOTHING=ON | OFF
@PJL SET ROTATESORT=ON | OFF
@PJL SET ORIENTATION=PORTRAIT | LANDSCAPE
@PJL SET MEDIASOURCE=TRAY1..TRAY5 | MANUALFEED | AUTO
@PJL SET MEDIATYPE=%s
@PJL SET PAPER=A4|A3|A5|LETTER|JPOST|... | CUSTOM
@PJL SET PAPERWIDTH=%d
@PJL SET PAPERLENGTH=%d
@PJL SET RESOLUTION=600                ← 硬编码，引擎只有 600
@PJL SET COPIES=%d
@PJL SET COVER=OFF | %s
@PJL SET HOLD=%s
@PJL SET DEPTCODENUM="%s"
@PJL SET USERNAME=%s
@PJL SET TIMESTAMP=%04d/%02d/%02d %02d:%02d:%02d
@PJL SET PAGESTATUS=START | END
@PJL SET IMAGELEN=%d
@PJL SET DOTCOUNT=%d
@PJL SET MANUALDUPLEX=FLIPSIDE
@PJL SET PURPOSE=MANUALDUPLEXEMPTYPAPER
@PJL COPYEND
@PJL EOJ
```

没有 N-up、没有水印、没有图像质量 —— 这些是驱动在**生成位图时**就合成好的，跟设备协议无关。

---

## 3. 实测验证过的行为

| 结论 | 证据 |
|---|---|
| 抓包文件可以被实体机正确接收 | 把 `07_text_a4_600.prn` 原样 RAW 发到队列，页计数 37317 → 37318 |
| **本项目 filter 生成的数据流被实体机接受** | `rastertoestudio` 输出的一页 A4（"TEST PAGE 1"）直发 9100，打印计数 45002 → 45003 |
| **空白页会被设备跳过** | `01_blank`（`DOTCOUNT=0`）发两次都不计数；同时说明 `DOTCOUNT` 被设备用于判空 |
| `DOTCOUNT` = 本页黑像素总数 | 03 单点 = 1；11 三点+100px 线 = 109；02 全黑 = 32474134 |
| 驱动只认 JBIG | 手工构造 `COMPRESS=NONE` + 原始 1bpp 行（带/不带 20 字节头两种），设备都不计数 |
| 引擎固定 600dpi | 选 300dpi 时驱动仍发 `RESOLUTION=600`，位图被 2× 放大（黑点计数 ×4） |
| 页面原点 = 纸面左上角 | 1×1 黑点画在驱动 DC 的 (0,0)，解码后在整页位图的 (99,99) |
| 驱动 DC 可印区 = 4763×6818（A4） | 整宽横线 y=0 是 4763 个黑点、横跨 x=99..4861；整高竖线 x=0 是 6818 个黑点、横跨 y=99..6916 |
| **可打印区边距恒定 99 px** | A4/A3/A5/Letter/100×150 五种纸的 (0,0) 点全部落在 (99,99)；即 99 px = 4.19 mm 物理边距 |
| **本机没有自动双面单元** | 25 份抓包（含 `20_duplex_2p`）全部是 `@PJL SET DUPLEX=OFF`，从未出现 `BINDING`；DLL 里虽有 `DUPLEX`/`BINDING` 词汇，但硬件不配备，驱动也不会发出 `ON` |

> 这几条说明 Windows 驱动的 DC 原点并不在纸面 (0,0)，而是在 (99,99)，可印区因此是
> 4763×6818（A4）。换算成 PPD 就是 `*ImageableArea` 四边留 99 px（600dpi 下 11.88 pt），
> 这样 CUPS 交给 filter 的 raster 尺寸和偏移与 Windows 驱动完全一致。
> 早期清单把这条当成「测试工具裁剪假象」是错的：五个纸型都精确复现 99 px，不可能是巧合。

---

## 4. filter 需要做的事（macOS 侧）

1. 从 CUPS 拿到 raster（一般是 1bpp，也可能 8bpp/彩色），必要时放大到 600dpi。
2. 用 **JBIG-1 编码器**压缩，参数全部来自抓包实测：
   `L0 = 128`、`order = 3`（ILEAVE|SMID）、`options = 0x48`（LRLTWO|TPBON）、
   `MX = MY = 0`、DL = DH = 0、planes = 1。
3. **保留 SDE 尾部零字节**：设备端编码器在每条带算术编码 flush 之后、`FF 02`
   之前会留下 6~9 个 `0x00`，上游 jbigkit 的 `jbg_buf_remove_zeros()` 会删掉它们。
   删掉后仍能解码，但无法与抓包逐字节一致（`10_color` 少 401 字节）。本项目的
   `third_party/jbigkit/jbig.c` 用 `ESTUDIO_KEEP_SDE_ZEROS` 开关保留这些字节，
   仅当末字节是 `0xFF` 时补一个 `0x00`。
4. 20 字节 BIH 直接由编码器写出，不用手工拼；按 65536 分块，每块前插
   `@PJL SET IMAGELEN=n\r\n`（首块 20 + 65536 = 65556）。
5. 前后包 PJL 信封；`DOTCOUNT` 必须是真实黑点数（`DOTCOUNT=0` 的页设备会跳过）。
6. 纸张/方向/纸盒/省墨直接用上表的 PJL 行表达，不需要 DEVMODE 模板；
   双面固定发 `DUPLEX=OFF`（本机无自动双面单元，见第 3 节）。

**CUPS 侧的坑**：cgpdftoraster 交出的 raster 只覆盖 `*ImageableArea`
（A4 为 4763×6818），不是整页 4961×7016。filter 必须把它**居中贴回整页位图**
（偏移 99 px），纸面绝对位置才与 Windows 驱动一致；偏移错了会整体平移，
内容还可能压到物理边距里被裁掉。

**许可**：jbigkit 是 Markus Kuhn 的 2.1 版，**GPL-2 或更新版本**，不是公共领域。
本项目 `third_party/jbigkit/` 随附 `COPYING`，并保留上述一个本地编译开关。

---

## 5. 抓包矩阵与文件清单

### 矩阵完成情况

| 编号 | 状态 | 说明 |
|---|---|---|
| 01–10 内容矩阵 | ✅ 已完成 | 全白/全黑/单点/横线/竖线/棋盘格/文字/16级灰阶/50%灰/色块 |
| 11 600dpi | ✅ | 基线 |
| 12 300dpi | ✅ | 驱动确实有 300 档，但输出仍标记 600（位图被放大） |
| 13 2400dpi | ⛔ 跳过 | 驱动只提供 300/600，无 2400 |
| 14–19 纸张/方向 | ✅ 已完成 | A4纵/A4横/Letter/A3/A5/自定义100×150（被映射成 `JPOST`） |
| 20 双面 | ⛔ 不适用 | 本机无自动双面单元；PJL 取值已从驱动提取，本项目固定发 `DUPLEX=OFF` |
| 21 单面 2 页 | ✅ | 页边界的对照样本 |
| 22 份数 3 | ✅ | 驱动把整页数据重复发 3 次，PJL 里 `COPIES=1` |
| 23–25 纸盒 | ✅ | `MEDIASOURCE=TRAY1/TRAY2/MANUALFEED` |
| 26 省墨 / 27 质量 | ❌ 不需要 | 只影响驱动端位图生成，filter 自己决定 |
| 28 缩放 50% | ⚠️ 未生效 | 驱动私有区控制；缩放由 filter 在光栅化阶段完成 |
| 29 N-up / 30 水印 | ❌ 不需要 | 驱动端图像合成，不涉及设备协议 |
| 31 状态通道 | ❌ 不需要 | 状态走 TopAccess(HTTP)/SNMP，与打印数据无关 |

### 文件清单

| 文件 | 内容 |
|---|---|
| `01..28_*.prn` | 25 个抓包（13 因驱动不提供 2400dpi 跳过；26/27/29/30 是驱动私有选项，现已确认**不需要**） |
| `manifest.txt` | 每个文件的编号/设置/字节数/时间 |
| `pjl-envelope.md` | 每个文件完整的 PJL 信封，逐条列出 |
| `structure.txt` | 每个文件的块结构、20 字节头字段、分带标记统计 |
| `caps.txt` | 驱动的 DeviceCapabilities：纸张表、纸盒表、分辨率表 |
| `FINDINGS.md` | 本文 |
| `CaptureTool.exe` + `.cs` | 抓包工具（`caps` / `list` / `run` / `dump` / `send` / `rawtest`）；Windows 专用，**未随仓库发布** |

> `C:\prn\` 是 Windows 保留设备名（PRN），清单里的这个路径不可用，已改成 `C:\eSTUDIO-capture\`。
