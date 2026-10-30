# e-STUDIO2323AM / 2823AM native CUPS driver
#
#   make                构建 filter
#   make test           合成 raster 端到端自测（2 页，含尺寸/DOTCOUNT/往返编码校验）
#   make test-capture   用 25 个实体机抓包做逐字节回归（最强验证）
#   make test-pdf       真实 PDF → cgpdftoraster → filter 自测
#   sudo make install   安装 filter + PPD

PREFIX      ?= /usr/local
FILTER_DIR  ?= /usr/libexec/cups/filter
PPD_DIR     ?= /Library/Printers/PPDs/Contents/Resources
CFG_DIR     ?= /etc/cups

CC      ?= cc
CFLAGS  ?= -O2 -Wall -Wextra -Wno-unused-parameter
LDFLAGS ?=

CUPS_CFLAGS := $(shell cups-config --cflags 2>/dev/null)
CUPS_LIBS   := $(shell cups-config --libs 2>/dev/null)

JBIG_DIR  := third_party/jbigkit
JBIG_SRC  := $(JBIG_DIR)/jbig.c $(JBIG_DIR)/jbig_ar.c
JBIG_INC  := -I$(JBIG_DIR) -Isrc -DESTUDIO_KEEP_SDE_ZEROS

FILTER    := rastertoestudio
FILTER_SRC:= src/rastertoestudio.c src/estudio_jbig.c
PRNCHECK  := tools/prncheck
MKRASTER  := tools/mkraster
PPD       := ppd/eSTUDIO2823AM.ppd

TESTDIR   ?= /tmp/estudio-test
CAPTURES  ?= eSTUDIO2323AM-captures

all: $(FILTER)

$(FILTER): $(FILTER_SRC) src/estudio_jbig.h $(JBIG_SRC)
	$(CC) $(CFLAGS) $(JBIG_INC) $(CUPS_CFLAGS) -o $@ $(FILTER_SRC) $(JBIG_SRC) \
		$(LDFLAGS) $(CUPS_LIBS)

$(PRNCHECK): tools/prncheck.c src/estudio_jbig.c src/estudio_jbig.h $(JBIG_SRC)
	$(CC) $(CFLAGS) $(JBIG_INC) -o $@ tools/prncheck.c src/estudio_jbig.c $(JBIG_SRC)

$(MKRASTER): tools/mkraster.c
	$(CC) $(CFLAGS) $(CUPS_CFLAGS) -o $@ tools/mkraster.c $(CUPS_LIBS)

install: $(FILTER)
	install -d "$(DESTDIR)$(FILTER_DIR)"
	install -m 755 $(FILTER) "$(DESTDIR)$(FILTER_DIR)/$(FILTER)"
	install -d "$(DESTDIR)$(PPD_DIR)"
	install -m 644 $(PPD) "$(DESTDIR)$(PPD_DIR)/eSTUDIO2823AM.ppd"
	@echo
	@echo "已安装。添加队列："
	@echo "  sudo lpadmin -p eSTUDIO2823AM -E -v socket://<打印机IP>:9100 \\"
	@echo "       -P $(PPD_DIR)/eSTUDIO2823AM.ppd"

uninstall:
	rm -f "$(DESTDIR)$(FILTER_DIR)/$(FILTER)"
	rm -f "$(DESTDIR)$(PPD_DIR)/eSTUDIO2823AM.ppd"

check: $(FILTER)
	@tmp=$$(mktemp "$${TMPDIR:-/tmp}/estudio-ppd.XXXXXX"); \
	sed 's#^\*cupsFilter: .*#*cupsFilter: "application/vnd.cups-raster 0 /usr/libexec/cups/filter/commandtops"#' \
		$(PPD) > $$tmp; \
	cupstestppd $$tmp; rc=$$?; rm -f $$tmp; \
	echo "(filter 路径用系统 commandtops 占位，只校验 PPD 结构；安装后再跑 cupstestppd $(PPD_DIR)/eSTUDIO2823AM.ppd)"; \
	exit $$rc
	@echo "filter: $$(file -b $(FILTER))"

# 合成 raster 自测：8bpp 输入 → filter → 校验（解码、DOTCOUNT、重编码逐字节一致）
test: $(FILTER) $(PRNCHECK) $(MKRASTER)
	rm -rf $(TESTDIR) && mkdir -p $(TESTDIR)/pbm
	./$(MKRASTER) $(TESTDIR)/test.raster 800 600 2
	./$(FILTER) 1 test title 1 "Resolution=600dpi PageSize=A4" \
		$(TESTDIR)/test.raster > $(TESTDIR)/out.prn
	./$(PRNCHECK) $(TESTDIR)/out.prn --pbm $(TESTDIR)/pbm

# 抓包回归：每个 .prn 解开、重编码，要求与原文件逐字节一致
test-capture: $(PRNCHECK)
	@test -d "$(CAPTURES)" || { echo "缺少抓包目录 $(CAPTURES)"; exit 1; }
	@fail=0; for f in "$(CAPTURES)"/*.prn; do \
		./$(PRNCHECK) "$$f" || fail=1; \
	done; \
	if [ $$fail -ne 0 ]; then echo "抓包回归失败"; exit 1; fi; \
	echo "抓包回归：全部通过"

# 选项映射自测：纸张/纸盒/介质/双面(恒OFF)/省墨/方向/多份
test-options: $(FILTER) $(MKRASTER)
	./tools/checkopts.sh ./$(FILTER) ./$(MKRASTER)

# 抓包重放：解码每份 .prn -> 裁回可印区 -> 重建 CUPS raster -> filter -> 逐字节比对
test-replay: $(FILTER) $(PRNCHECK)
	rm -rf $(TESTDIR) && mkdir -p $(TESTDIR)
	python3 tools/mkpdf.py $(TESTDIR)/t1.pdf 1
	sed 's#^\*cupsFilter: .*#*cupsFilter: "application/vnd.cups-raster 0 /usr/libexec/cups/filter/commandtops"#' \
		$(PPD) > $(TESTDIR)/local.ppd
	cupsfilter -p $(TESTDIR)/local.ppd -i application/pdf \
		-m application/vnd.cups-raster $(TESTDIR)/t1.pdf > $(TESTDIR)/tpl.raster
	python3 tools/replay.py $(CAPTURES) ./$(FILTER) $(TESTDIR)/tpl.raster

# 真实链路自测：PDF -> cgpdftoraster -> filter

# 真实链路自测：PDF -> cgpdftoraster -> filter
test-pdf: $(FILTER) $(PRNCHECK)
	rm -rf $(TESTDIR) && mkdir -p $(TESTDIR)
	python3 tools/mkpdf.py $(TESTDIR)/t2.pdf 2
	sed 's#^\*cupsFilter: .*#*cupsFilter: "application/vnd.cups-raster 0 $(CURDIR)/$(FILTER)"#' \
		$(PPD) > $(TESTDIR)/local.ppd
	cupsfilter -p $(TESTDIR)/local.ppd -i application/pdf \
		-m application/vnd.cups-raster $(TESTDIR)/t2.pdf > $(TESTDIR)/t2.raster
	./$(FILTER) 2 test "pdf test" 1 "PageSize=A4" $(TESTDIR)/t2.raster > $(TESTDIR)/t2.prn
	./$(PRNCHECK) $(TESTDIR)/t2.prn

clean:
	rm -f $(FILTER) $(PRNCHECK) $(MKRASTER)

.PHONY: all install uninstall check test test-capture test-pdf test-options test-replay clean
