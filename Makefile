LUA ?= lua
STABLE_TL ?= $(LUA) ./tl
NEW_TL ?= $(LUA) ./tl
TLGENFLAGS = --check --gen-target=5.1
BUSTED_CMD ?= busted
BUSTED = $(BUSTED_CMD) --suppress-pending
STRIPDIR = _temp/strip
STRICT_NIL_PRAGMA = --\#pragma strict_nil off
PACKAGE_PATH := $(shell $(LUA) -e 'print(package.path)')
STRICT_NIL_SUPPORTED := $(shell printf '%s\n' '$(STRICT_NIL_PRAGMA)' 'local x: integer = nil' | $(STABLE_TL) check - >/dev/null 2>&1 && echo yes)
STRIP_STRICT_NIL := $(if $(STRICT_NIL_SUPPORTED),0,1)
STRIP_TL_PATH = $(STRIPDIR)/?.tl;$(STRIPDIR)/?/init.tl;$(STRIPDIR)/?.d.tl;./?.tl;./?/init.tl;./?.d.tl;$(PACKAGE_PATH)
STRIPPED_SOURCES = $(addprefix $(STRIPDIR)/,$(SOURCES))

PRECOMPILED = teal/precompiled/default_env.lua
SOURCES = teal/debug.tl teal/attributes.tl teal/errors.tl teal/lexer.tl \
	teal/reader.tl teal/block.tl \
	teal/util.tl teal/types.tl teal/facts.tl teal/ast.tl teal/parser.tl teal/traversal.tl \
	teal/variables.tl teal/type_reporter.tl \
	teal/macroexps.tl teal/macro_eval.tl teal/metamethods.tl \
	teal/type_errors.tl teal/environment.tl \
	teal/check/context.tl teal/check/visitors.tl teal/check/check.tl \
	teal/check/relations.tl teal/check/special_functions.tl \
	teal/check/type_checker.tl teal/check/node_checker.tl \
	teal/input.tl \
	teal/check/require_file.tl \
	teal/gen/targets.tl teal/gen/lua_generator.tl teal/gen/lua_compat.tl \
	teal/package_loader.tl teal/loader.tl \
	teal/api/v2.tl teal/api/v1.tl \
	teal/init.tl \
	tl.tl \
	tlcli/configuration.tl \
	tlcli/report.tl \
	tlcli/driver.tl \
	tlcli/perf.tl \
	tlcli/main.tl \
	tlcli/commands/lsp.tl \
	tlcli/commands/run.tl \
	tlcli/commands/warnings.tl \
	tlcli/commands/dump_blocks.tl \
	tlcli/commands/types.tl \
	tlcli/commands/check.tl \
	tlcli/commands/gen.tl \
	tlcli/common.tl

all: selfbuild suite

########################################
# Multi-stage bootstrap process:
########################################

$(STRIPDIR)/%.tl: %.tl FORCE
	@mkdir -p `dirname $@`
	@if [ "$(STRIP_STRICT_NIL)" = "1" ]; then \
		sed '/^[[:space:]]*$(STRICT_NIL_PRAGMA)[[:space:]]*$$/d' $< > $@; \
	else \
		cp $< $@; \
	fi

FORCE:

strip_sources: $(STRIPPED_SOURCES) $(STRIPDIR)/precompiler.tl

precompiler.lua: strip_sources $(STRIPDIR)/precompiler.tl
	TL_PATH="$(STRIP_TL_PATH)" $(STABLE_TL) gen $(STRIPDIR)/precompiler.tl -o $@ || { rm $@; exit 1; }

teal/precompiled/default_env.lua: precompiler.lua teal/default/prelude.d.tl teal/default/stdlib.d.tl tl.tl
	$(LUA) precompiler.lua > teal/precompiled/default_env.lua || { rm $@; exit 1; }

_temp/%.lua.1: %.tl $(PRECOMPILED) $(STRIPDIR)/%.tl
	@mkdir -p `dirname $@`
	@echo $(STRIPDIR)/$< >> _temp/list1
	@echo $@ >> _temp/list1.1
	@touch $@

_temp/%.lua.2: replace1 %.tl _temp/%.lua.1 $(PRECOMPILED) FORCE
	@mkdir -p `dirname $@`
	@echo $*.tl >> _temp/list2
	@touch $@

build1: newlist $(addprefix _temp/,$(addsuffix .lua.1,$(basename $(SOURCES))))
	if [ -e _temp/list1 ]; \
	then TL_PATH="$(STRIP_TL_PATH)" $(STABLE_TL) gen $(TLGENFLAGS) --root $(STRIPDIR) --custom-ext .lua.1 --output-dir _temp `cat _temp/list1` || { rm `cat _temp/list1.1`; exit 1; };\
	fi

replace1: build1
	extras/make.sh move_1_to_lua
	@rm -f _temp/list2

build2: $(addprefix _temp/,$(addsuffix .lua.2,$(basename $(SOURCES))))
	if [ -e _temp/list2 ]; \
	then $(NEW_TL) gen $(TLGENFLAGS) --root . --custom-ext .lua.2 --output-dir _temp `cat _temp/list2` || extras/make.sh revert; \
	fi

newlist:
	@mkdir -p _temp/
	@rm -f _temp/list1
	@rm -f _temp/list1.1
	@rm -f _temp/list1.2

selfbuild: combine
	extras/make.sh diff_1_and_2 || extras/make.sh revert

########################################
# Test suite:
########################################

suite:
	@if command -v $(BUSTED_CMD) >/dev/null 2>&1; then \
		$(MAKE) --no-print-directory suite-strict; \
	else \
		echo "Busted not found; self-build succeeded, skipping tests (use 'make suite-strict' to require them)."; \
	fi

suite-strict:
	${BUSTED} -v $(TESTFLAGS) spec/lang
	${BUSTED} -v $(TESTFLAGS) spec/api
	${BUSTED} -v $(TESTFLAGS) spec/cli

########################################
# Utility targets:
########################################

bin:
	$(MAKE) STABLE_TL=_binary/build/tl

binary:
	extras/binary.sh --clean

combine: build2
	$(STABLE_TL) run extras/combine.tl

revert:
	git checkout $(PRECOMPILED) $(addsuffix .lua,$(basename $(SOURCES)))

cov:
	rm -f luacov.stats.out luacov.report.out
	${BUSTED} -c
	luacov tl.lua
	cat luacov.report.out

cleantemp:
	rm -rf _temp

clean: cleantemp
# force a recompile of the environment
	rm precompiler.lua

########################################
# Makefile administrivia
########################################

.PHONY: all build1 replace1 build2 selfbuild suite suite-strict \
	suite bin binary cov revert cov cleantemp clean strip_sources FORCE
