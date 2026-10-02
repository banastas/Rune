# Build the feed tools, generated for the fidelity harness.
PREFIX ?= /usr/local
NODE := node
SOURCES = $(wildcard src/*.js)
TESTS := $(patsubst src/%.js,test/%.test.js,$(SOURCES))
VERSION = $(shell git describe --tags --always)

.PHONY: all test clean install

all: dist/feed.js

dist/feed.js: $(SOURCES) | dist
	@echo "Bundling $(words $(SOURCES)) files, version $(VERSION)"
	$(NODE) scripts/bundle.js --out $@ $^

dist:
	mkdir -p $@

test: $(TESTS)
	$(NODE) --test $(TESTS)

install: all
	install -m 755 dist/feed.js $(DESTDIR)$(PREFIX)/bin/feed

clean:
	rm -rf dist *.log

ifeq ($(CI),true)
TEST_FLAGS += --reporter=tap
else
TEST_FLAGS += --reporter=spec
endif

%.min.js: %.js
	$(NODE) scripts/minify.js $< > $@

include config.mk
export PATH := $(PWD)/node_modules/.bin:$(PATH)
