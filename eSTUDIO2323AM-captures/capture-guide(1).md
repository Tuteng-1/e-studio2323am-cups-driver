# e-STUDIO2323AM 打印流：实测结论与后续步骤

> **本文原为「抓包方案」，2026-10-29 已在 x64 Windows 上完成抓包并实机验证。**
> 原方案假设的「cmd 3 / cmd 8 / cmd 4 / cmd 35 私有命令流」实测不存在，整篇已按实测结果重写。
> 细节数据见 `C:\eSTUDIO-capture\FINDINGS.md`。

---

## 0. 一句话结论

驱动发出的是 **PJL 文本信封 + 一个 JBIG 压缩的页面块**。

```
ESC%-12345X@PJL \r\n
@PJL SET COMPRESS=JBIG
@PJL SET PAPER=A4 / PAPERWIDTH=4961 / PAPERLENGTH=7016 / RESOLUTION=600 ...
@PJL SET IMAGELEN=130\r\n
<20 字节头 + JBIG 流>
@PJL SET DOTCOUNT=0
@PJL SET PAGESTATUS=END
@PJL EOJ
ESC%-12345X\r\n
```

- 设备**只认 JBIG**（`COMPRESS=NONE` 实测被拒）；
- 信封部分极简单，26 条 PJL 语句全部拿到了；
- 因此 CUPS filter 的工作量集中在 **JBIG-1 编码**这一件事上。

---

## 1. 页面块结构

| 偏移 | 长度 | 含义 | 实测值 |
|---|---|---|---|
| 0 | 4 | 固定标识 | `00 00 01 00` |
| 4 | 4 | XD 页宽（像素，大端） | A4 = 4961 |
| 8 | 4 | YD 页高（像素，大端） | A4 = 7016 |
| 12 | 4 | 分带高度 | `00 00 00 80` = 128 行 |
| 16 | 4 | 固定 | `00 00 03 48`（840，所有纸型恒定） |
| 20 | n | JBIG 数据流 | 每条带以 `FF 02`（SDNORM）结束 |

**尺寸换算**：`px = round(mm / 25.4 * 600)`，引擎固定 600dpi。

实测：A4 = 4961×7016，A3 = 7016×9921，A5 = 3496×4961，Letter = 5100×6600，100×150mm = 2362×3543。

**分块规则**：首块 `IMAGELEN = 20 + 65536`（= 65556），之后每块 65536，末块为余数。切点可以在 JBIG 流中间任意位置。

---

## 2. 判定为 JBIG 的依据

1. `@PJL SET COMPRESS=JBIG` 是 `eSSh6OCM.dll` 偏移 95424 处的**硬编码字符串**，驱动没有第二种压缩模式。
2. 每页 `FF 02`（JBIG 分带结束标记）出现次数**恰好等于 `ceil(YD / 128)`**：A4 55、A3 78、A5 39、Letter 52、100×150 28 —— 五组全中。
3. 1px 棋盘格（熵最大）压到 3132 字节，只有算术编码能到这个量级，RLE 不可能。
4. 空白页整页只有 55 个 `FF 02`、无任何编码数据 —— 标准 JBIG 在概率极度倾斜时确实可以零输出。

---

## 3. 完整 PJL 词汇表

从 `eSSh6OCM.dll` 提取，共 26 条，filter 直接按需拼字符串即可，**不需要 DEVMODE 模板**：

```
@PJL SET COMPRESS=JBIG                  ← 唯一值
@PJL SET DUPLEX=ON | OFF
@PJL SET BINDING=LONGEDGE | SHORTEDGE   ← 双面装订方向
@PJL SET TONERSAVE=ON | OFF
@PJL SET SMOOTHING=ON | OFF
@PJL SET ROTATESORT=ON | OFF
@PJL SET ORIENTATION=PORTRAIT | LANDSCAPE
@PJL SET MEDIASOURCE=TRAY1..TRAY5 | MANUALFEED | AUTO
@PJL SET MEDIATYPE=%s
@PJL SET PAPER=A4|A3|A5|LETTER|JPOST|... | CUSTOM
@PJL SET PAPERWIDTH=%d
@PJL SET PAPERLENGTH=%d
@PJL SET RESOLUTION=600                 ← 硬编码，引擎只有 600
@PJL SET COPIES=%d
@PJL SET COVER=OFF | %s
@PJL SET HOLD=%s
@PJL SET DEPTCODENUM="%s"
@PJL SET USERNAME=%s
@PJL SET TIMESTAMP=%04d/%02d/%02d %02d:%02d:%02d
@PJL SET PAGESTATUS=START | END
@PJL SET IMAGELEN=%d
@PJL SET DOTCOUNT=%d                    ← 本页黑点总数，必须算对
@PJL SET MANUALDUPLEX=FLIPSIDE
@PJL SET PURPOSE=MANUALDUPLEXEMPTYPAPER
@PJL COPYEND
@PJL EOJ
```

没有 N-up、没有水印、没有图像质量 —— 这些是驱动在**生成位图时**就合成好的，与设备协议无关。

---

## 4. 实机验证过的行为

验证手段：TopAccess 页计数器 `http://192.0.2.10/H10_Counter.htm`（无须登录）。

| 结论 | 证据 |
|---|---|
| 抓包文件可被实机正确接收 | `07_text_a4_600.prn` 原样 RAW 发送，页计数 37317 → 37318 |
| **空白页会被设备跳过** | `01_blank`（`DOTCOUNT=0`）连发两次都不计数 |
| `DOTCOUNT` = 本页黑像素总数 | 03 单点 = 1；11 三点+100px 线 = 109；02 全黑 = 32474134 |
| `COMPRESS=NONE` 不被接受 | 带/不带 20 字节头两种封装都试过，设备无反应 |
| 引擎固定 600dpi | 选 300dpi 时驱动仍发 `RESOLUTION=600`，位图被 2× 放大（黑点数 ×4） |
| 页面原点 = 纸面左上角 | 1×1 黑点画在 (0,0) 后 `DOTCOUNT=1`，未被裁掉 |
| 双面 = `DUPLEX=ON` + `BINDING=LONGEDGE` | 从驱动字符串提取，尚未用实机取样复核 |

> 注意最后一项：双面的 PJL 取值是从驱动里读出来的字面量，但没有真实抓包样本。首次上机验证时请顺带打印一份双面作业确认。

---

## 5. 抓包矩阵完成情况

| 编号 | 状态 | 说明 |
|---|---|---|
| 01–10 内容矩阵 | ✅ 已完成 | 全白/全黑/单点/横线/竖线/棋盘格/文字/16级灰阶/50%灰/色块 |
| 11 600dpi | ✅ | 基线 |
| 12 300dpi | ✅ | 驱动确实有 300 档，但输出仍标记 600（位图被放大） |
| 13 2400dpi | ⛔ 跳过 | 驱动只提供 300/600，无 2400 |
| 14–19 纸张/方向 | ✅ 已完成 | A4纵/A4横/Letter/A3/A5/自定义100×150（被映射成 `JPOST`） |
| 20 双面 | ⚠️ 部分 | 驱动私有区控制，公开 DEVMODE 改不动；PJL 取值已从驱动提取，待实机复核 |
| 21 单面 2 页 | ✅ | 页边界的对照样本 |
| 22 份数 3 | ✅ | 驱动把整页数据重复发 3 次，PJL 里 `COPIES=1` |
| 23–25 纸盒 | ✅ | `MEDIASOURCE=TRAY1/TRAY2/MANUALFEED` |
| 26 省墨 / 27 质量 | ❌ 不需要 | 只影响驱动端位图生成，filter 自己决定 |
| 28 缩放 50% | ⚠️ 未生效 | 驱动私有区控制；但缩放本就该由 filter 在光栅化阶段做 |
| 29 N-up / 30 水印 | ❌ 不需要 | 驱动端图像合成，不涉及设备协议 |
| 31 状态通道 | ❌ 不需要 | 状态走 TopAccess(HTTP)/SNMP，与打印数据无关 |

**结论：抓包阶段已经结束，没有必须补抓的项。**

---

## 6. 环境记录（换机复现用）

实测机器：capture-host，x64 Windows 11 build 22000（**不是** ARM64 的 Parallels 虚拟机）。
实体机：`TOSHIBA e-STUDIO2323AM`，序列号 CPGM00000，`192.0.2.10`，装有自动双面单元。

若要在另一台机器复现，用隔离队列抓包（永不触达实体机）：

```powershell
New-Item -ItemType Directory -Force C:\eSTUDIO-capture
Add-PrinterPort -Name "C:\eSTUDIO-capture\_raw.prn"
Add-Printer -Name "eSTUDIO-CAPTURE" -DriverName "TOSHIBA e-STUDIO2823AMSeries GDI" `
           -PortName "C:\eSTUDIO-capture\_raw.prn"
Set-Printer -Name "eSTUDIO-CAPTURE" -PrintProcessor "eSSh6PPR" -Datatype "RAW"
```

然后 `CaptureTool.exe run` 即可按任务表批量落盘，`run --only 03,06` 可只跑指定项。

> **`C:\prn\` 不要用**：`PRN` 是 Windows 保留设备名（对应打印机设备），建同名目录会出现「目录存在但 `Test-Path` 返回 False」这类怪事。

驱动信息：

| 项 | 值 |
|---|---|
| INF | `essh6.inf_amd64_d7e5f2af3ec4e476` |
| 打印处理器 | `eSSh6PPR`（Datatype = RAW） |
| 抓包队列 | `eSTUDIO-CAPTURE` → Local Port `C:\eSTUDIO-capture\_raw.prn` |

---

## 7. 剩余工作（macOS 侧）

### 7.1 先验证 JBIG（5 分钟）

用 jbigkit 解 `06_checker8_a4_600.prn` 的页面块，看能否还原出 1px 棋盘格：

```bash
jbgtopbm payload.jbg out.pbm
```

- 能还原 → 标准 JBIG-1，filter 直接用 `jbg_enc`；
- 不能 → 那 20 字节头替换了 BIH，需要按 BIH 语义重排后再试。

这是唯一还没确认的环节，其余都已闭合。

### 7.2 filter 实现步骤

1. 取 CUPS 光栅，缩放到目标纸型的 600dpi 尺寸（A4 = 4961×7016）；
2. JBIG-1 编码：`L0 = 128`、`order = 0`、`options = 0`、每带 SDNORM 结束；
3. 拼 20 字节头（大端）：`0x00000100 | XD | YD | 0x80 | 0x348`；
4. 按 65536 分块，每块前插 `@PJL SET IMAGELEN=n\r\n`；
5. 前后包 PJL 信封，`DOTCOUNT` 必须填真实黑点数（填 0 会被当空白页丢弃）；
6. 纸张/方向/纸盒/双面/省墨用第 3 节的 PJL 行表达。

---

## 8. 交付文件

全部在 `C:\eSTUDIO-capture\`：

| 文件 | 内容 |
|---|---|
| `eSTUDIO2323AM-captures.zip` | 打包好的 25 个 `.prn` + 报告，直接拷到 Mac |
| `01..28_*.prn` | 抓包原始字节（**不要做任何格式转换或十六进制编辑**） |
| `manifest.txt` | 编号 / 文件名 / 字节数 / 纸张 / dpi / 双面 / 份数 / 纸盒 / 缩放 / 页数 / 时间 / 说明 |
| `pjl-envelope.md` | 每个文件的完整 PJL 信封，逐条列出 |
| `structure.txt` | 每个文件的块结构、20 字节头字段、分带标记统计 |
| `caps.txt` | 驱动 DeviceCapabilities：纸张表 / 纸盒表 / 分辨率表 / 私有无 DEVMODE 快照 |
| `FINDINGS.md` | 技术结论全文（本文件的详细版） |
| `CaptureTool.exe` | 抓包工具：`caps` / `list` / `run` / `dump` / `send` / `rawtest` |
| `CaptureTool.cs` `Program.cs` `Dump.cs` `TestPage.cs` `SendRaw.cs` | 源码，可用 `csc /codepage:65001` 重编译 |

回传目标：`/path/to/e-STUDIO2323AM/captures/`

---

## 9. 已废弃的原方案内容

为免误用，原方案里以下几项已确认作废：

| 原内容 | 现状 |
|---|---|
| 「cmd 3 纸张头 / cmd 4 页头 / cmd 35 光栅带」 | 不存在，实际是 PJL + JBIG |
| 「cmd 3 里含 220 字节 DEVMODE 私有区」 | 220 是 DEVMODE 结构自身长度（`dmSize=220`），私有区另有 4892 字节，且不在打印流里 |
| `tools/prn_dump.py`、`tools/extract_cmd3.py` | 前提消失，改用 `CaptureTool.exe dump` 输出 `structure.txt` |
| `C:\prn\` 工作目录 | Windows 保留设备名，改用 `C:\eSTUDIO-capture\` |
| 在 Parallels ARM64 上做 | 本机就是 x64 物理机，已完成 |
