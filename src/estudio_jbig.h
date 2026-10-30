/*
 * estudio_jbig.h — JBIG-1 (T.82) encoder settings used by the e-STUDIO
 * 2323AM/2823AM GDI engine.
 *
 * 这些参数是从抓包逐字节复现出来的：把 07_text 抓包解出的位图用
 *   ESTUDIO_JBIG_ORDER / ESTUDIO_JBIG_OPTIONS / ESTUDIO_JBIG_L0 / ESTUDIO_JBIG_MX
 * 重新编码，得到的 1601 字节与设备收到的数据完全一致（含 20 字节 BIH）。
 */
#ifndef ESTUDIO_JBIG_H
#define ESTUDIO_JBIG_H

#include <stddef.h>

#define ESTUDIO_JBIG_ORDER   3      /* ILEAVE | SMID */
#define ESTUDIO_JBIG_OPTIONS 0x48   /* LRLTWO | TPBON */
#define ESTUDIO_JBIG_L0      128    /* 每条带 128 行 */
#define ESTUDIO_JBIG_MX      0      /* 不做自适应模板 */

/*
 * 把 1bpp 位图（MSB 优先，1 = 黑，行按 (width+7)/8 字节对齐、末字节零填充）
 * 编码成完整 BIE（20 字节 BIH + SDE 数据）。
 * 成功返回 0，*out 由调用者 free()。
 */
int estudio_jbig_encode(const unsigned char *bitmap, unsigned long width,
                        unsigned long height, unsigned char **out,
                        size_t *outlen);

/* 统计黑像素个数（stride 固定为 (width+7)/8），用于 PJL DOTCOUNT。 */
unsigned long estudio_count_black(const unsigned char *bitmap,
                                  unsigned long width, unsigned long height);

#endif
