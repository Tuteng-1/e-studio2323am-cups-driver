# jbigkit（第三方组件）

- **版本**：JBIG-KIT 2.1
- **作者**：Markus Kuhn <http://www.cl.cam.ac.uk/~mgk25/jbigkit/>
- **许可**：GNU GPL v2 或更新版本，全文见同目录 [`COPYING`](COPYING)
- **引入方式**：源码原样复制（`jbig.c` / `jbig.h` / `jbig_ar.c` / `jbig_ar.h`），
  **不是**子模块、也不在构建时下载。

## 本项目的本地改动

只有一处，且默认不改变上游行为以外的任何表现：

| 位置 | 改动 |
|---|---|
| `jbig.c`（`jbg_buf_remove_zeros()`、`jbg_enc_out()`） | 新增编译开关 `ESTUDIO_KEEP_SDE_ZEROS`：保留每条带算术编码 flush 之后、`FF 02` 之前的那几个 `0x00` 字节；仅当末字节是 `0xFF` 时补一个 `0x00`。 |

为什么要改：e-STUDIO 设备端收到的编码器输出里有这些零字节，上游
`jbg_buf_remove_zeros()` 会把它们删掉。删掉后仍能正常解码，但**无法与厂商
驱动的输出逐字节一致**（`eSTUDIO2323AM-captures/10_color_a4_600.prn` 会少
401 字节）。开关由 `Makefile` 的 `-DESTUDIO_KEEP_SDE_ZEROS` 打开。

开关未定义时，行为与上游 2.1 完全一致。

## 升级注意

若要换用更新的 jbigkit，需要先确认 `jbg_buf_remove_zeros()` 与
`jbg_enc_out()` 的实现没有变化，否则 `make test-capture`（逐字节回归）
会立刻失败。
