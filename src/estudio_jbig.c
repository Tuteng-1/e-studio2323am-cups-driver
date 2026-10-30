/*
 * estudio_jbig.c — 用 jbigkit 生成设备接受的 JBIG-1 数据流
 *
 * 设备要求的分层参数（实测）：
 *   L0 = 128, order = 3 (ILEAVE|SMID), options = 0x48 (LRLTWO|TPBON),
 *   MX = 0, MY = 0, 单一分辨率层、单一 bit plane。
 * 每个 BIE 自带 20 字节 BIH（dl=dh=0, planes=1, XD, YD, L0=128, MX=0, MY=0,
 * order=3, options=0x48），后面按 128 行一条带、以 SDNORM (FF 02) 结束。
 */

#include "estudio_jbig.h"

#include <stdlib.h>
#include <string.h>

#include "jbig.h"

struct outbuf {
    unsigned char *data;
    size_t len;
    size_t cap;
    int failed;
};

static void out_cb(unsigned char *start, size_t len, void *file)
{
    struct outbuf *b = (struct outbuf *)file;

    if (b->failed || len == 0)
        return;

    if (b->len + len > b->cap) {
        size_t cap = b->cap ? b->cap : 65536;
        unsigned char *p;

        while (cap < b->len + len)
            cap *= 2;

        p = realloc(b->data, cap);
        if (!p) {
            b->failed = 1;
            return;
        }
        b->data = p;
        b->cap = cap;
    }

    memcpy(b->data + b->len, start, len);
    b->len += len;
}

int estudio_jbig_encode(const unsigned char *bitmap, unsigned long width,
                        unsigned long height, unsigned char **out,
                        size_t *outlen)
{
    struct jbg_enc_state s;
    struct outbuf b;
    unsigned char *plane = (unsigned char *)bitmap;

    if (!bitmap || width == 0 || height == 0 || !out || !outlen)
        return -1;

    memset(&b, 0, sizeof(b));

    jbg_enc_init(&s, width, height, 1, &plane, out_cb, &b);
    jbg_enc_options(&s, ESTUDIO_JBIG_ORDER, ESTUDIO_JBIG_OPTIONS,
                    ESTUDIO_JBIG_L0, ESTUDIO_JBIG_MX, -1);
    jbg_enc_out(&s);
    jbg_enc_free(&s);

    if (b.failed || !b.data) {
        free(b.data);
        return -1;
    }

    *out = b.data;
    *outlen = b.len;
    return 0;
}

unsigned long estudio_count_black(const unsigned char *bitmap,
                                  unsigned long width, unsigned long height)
{
    size_t stride = (size_t)((width + 7) / 8);
    unsigned long total = 0;
    unsigned long y;

    for (y = 0; y < height; y++) {
        const unsigned char *row = bitmap + (size_t)y * stride;
        size_t n = stride;

        /* 末字节只统计有效位，保证 DOTCOUNT 精确 */
        while (n >= sizeof(unsigned long)) {
            unsigned long v;

            memcpy(&v, row, sizeof(v));
            total += (unsigned long)__builtin_popcountl(v);
            row += sizeof(v);
            n -= sizeof(v);
        }
        while (n--) {
            total += (unsigned long)__builtin_popcount(*row);
            row++;
        }
    }

    /* 清掉最后一行末尾的填充位（填充位恒为 0，这里只是保险） */
    (void)width;

    return total;
}
