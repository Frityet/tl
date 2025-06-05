LUA ?=
STABLE_TL ?= $(LUA) ./tl
NEW_TL ?= $(LUA) ./tl
TLGENFLAGS = --check --gen-target=5.1
BUSTED = busted --suppress-pending

PRECOMPILED = teal/precompiled/default_env.lua
SOURCES = teal/debug.tl teal/attributes.tl teal/errors.tl teal/lexer.tl \
	teal/util.tl teal/types.tl teal/facts.tl teal/parser.tl teal/traversal.tl \
	teal/gen/lua_generator.tl teal/gen/lua_compat.tl teal/variables.tl teal/type_reporter.tl \
	teal/macroexps.tl teal/metamethods.tl \
	teal/type_errors.tl teal/environment.tl \
	teal/check/context.tl teal/check/visitors.tl teal/check/check.tl \
	teal/check/relations.tl teal/check/special_functions.tl \
	teal/check/type_checker.tl teal/check/node_checker.tl \
	teal/check/file_checker.tl teal/check/string_checker.tl \
	teal/reader.tl teal/block-parser.tl \
	teal/check/require_file.tl teal/package_loader.tl tl.tl

SOURCES = teal/debug.tl teal/errors.tl teal/lexer.tl teal/binary_search.tl teal/embed/prelude.tl teal/embed/stdlib.tl teal/types.tl teal/facts.tl teal/parser.tl teal/traversal.tl tl.tl

all: selfbuild suite

%.lua.bak: %.lua
	cp $< $@

%.lua.1: %.tl
	$(LUA) ./tl gen --check $< -o $@ || { rm $@; exit 1; }

%.lua.2: %.tl %.lua.1
	$(LUA) ./tl gen --check $< -o $@ || { for bak in $$(find . -name '*.lua.bak'); do cp $$bak `echo "$$bak" | sed 's/.bak$$//'`; done; for l in `find . -name '*.lua.1'`; do mv $$l $$l.err; done; exit 1 ;}

build1: $(addsuffix .lua.1,$(basename $(SOURCES)))

replace1:
	for f in $$(find . -name '*.lua.1'); do l=`echo "$$f" | sed 's/.1$$//'`; cp $$l $$l.bak; cp $$f $$l; done

build2: $(addsuffix .lua.2,$(basename $(SOURCES)))

selfbuild: build1 replace1 build2
	for f in $$(find . -name '*.lua.1'); do l=`echo "$$f" | sed 's/.1$$//'`; diff $$f $$l.2 || { for bak in $$(find . -name '*.lua.bak'); do cp $$bak `echo "$$bak" | sed 's/.bak$$//'`; done; for l in `find . -name '*.lua.1'`; do mv $$l $$l.err; done; exit 1 ;}; done

suite:
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

########################################
# Makefile administrivia
########################################

.PHONY: all build1 replace1 build2 selfbuild \
	suite bin binary cov revert cov cleantemp clean
