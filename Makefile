EMACS ?= emacs
BATCH = $(EMACS) -Q --batch

LOAD_PATH = -L . -L test
SRC = soft-narrow.el
TEST_SRC = test/soft-narrow-test.el

PACKAGE_INIT = --eval "(progn (require 'package) (push '(\"melpa\" . \"https://melpa.org/packages/\") package-archives) (package-initialize) (unless (package-installed-p 'package-lint) (package-refresh-contents) (package-install 'package-lint)))"

.PHONY: all compile test lint package-lint autoloads clean

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
	  $(PACKAGE_INIT) \
	  -l package-lint \
	  -f package-lint-batch-and-exit $(SRC)

clean:
	rm -f *.elc test/*.elc soft-narrow-autoloads.el
