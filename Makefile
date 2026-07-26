EMACS ?= emacs
BATCH = $(EMACS) -Q --batch

LOAD_PATH = -L . -L test
SRC = soft-narrow.el
TEST_SRC = test/soft-narrow-test.el
FANCY_NARROW_COMMIT = c9b3363752c09045b8ce7a2635afae42d2ae63c7
BENCHMARK_CACHE ?= $(HOME)/.cache/soft-narrow
FANCY_NARROW_DIR = $(BENCHMARK_CACHE)/fancy-narrow-$(FANCY_NARROW_COMMIT)

.PHONY: all compile test lint package-lint autoloads benchmark-fetch benchmark clean

all: compile

autoloads:
	$(BATCH) $(LOAD_PATH) \
	  --eval "(loaddefs-generate \".\" \"soft-narrow-autoloads.el\")"

compile:
	$(BATCH) $(LOAD_PATH) \
	  --eval "(setq byte-compile-error-on-warn t)" \
	  $(foreach f,$(SRC),--eval "(byte-compile-file \"$(f)\")")

test:
	$(BATCH) $(LOAD_PATH) \
	  -l $(TEST_SRC) \
	  -f ert-run-tests-batch-and-exit

lint:
	$(BATCH) $(LOAD_PATH) \
	  $(foreach f,$(SRC),--eval "(checkdoc-file \"$(f)\")")

package-lint:
	$(BATCH) $(LOAD_PATH) \
	  --eval "(require 'package-lint)" \
	  -f package-lint-batch-and-exit $(SRC)

benchmark-fetch:
	@if [ ! -d "$(FANCY_NARROW_DIR)/.git" ]; then \
	  mkdir -p "$(BENCHMARK_CACHE)"; \
	  git init -q "$(FANCY_NARROW_DIR)"; \
	  git -C "$(FANCY_NARROW_DIR)" fetch --quiet --depth=1 \
	    https://github.com/Malabarba/fancy-narrow.git "$(FANCY_NARROW_COMMIT)"; \
	  git -C "$(FANCY_NARROW_DIR)" checkout --quiet --detach FETCH_HEAD; \
	fi
	@test "$$(git -C "$(FANCY_NARROW_DIR)" rev-parse HEAD)" = \
	  "$(FANCY_NARROW_COMMIT)" || \
	  { echo "fancy-narrow cache is not at the pinned commit" >&2; exit 1; }

benchmark: benchmark-fetch
	$(BATCH) -L . -L "$(FANCY_NARROW_DIR)" -l benchmark/compare.el

clean:
	rm -f *.elc test/*.elc soft-narrow-autoloads.el
