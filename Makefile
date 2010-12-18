##
# Plowshare Makefile
##

# Tools

INSTALL = install

# Files

SRCS = Makefile setup.sh \
       src/download.sh src/upload.sh src/delete.sh src/list.sh \
       src/lib.sh src/strip_single_color.pl src/strip_threshold.pl

MODULE_FILES    = $(wildcard src/modules/*.sh)
TESSERACT_FILES = $(addprefix src/tesseract/, alnum digit digit_ops plowshare_nobatch upper)
TEST_FILES      = run_tests.sh test/lib.sh test/test_lib.sh test/test_modules.sh \
                  test/test_setup.sh $(wildcard test/pics/*)

DOCS = CHANGELOG COPYING INSTALL README \
       docs/plowdown.1 docs/plowup.1 docs/plowdel.1 docs/plowlist.1

CONTRIB_FILES = $(addprefix examples/,caturl.sh plowdown_add_remote_loop.sh plowdown_loop.sh \
                plowdown_parallel.sh)

# Packaging

GIT_LOG := $(shell git svn info | grep ^Revision | cut -d' ' -f2)
VERSION = $(GIT_LOG)
DISTDIR = plowshare-SVN-r$(VERSION)-snapshot


install:
	@echo "Not yet!"
uninstall:
	@echo "Not yet!"

dist: distdir
	@tar -cf - $(DISTDIR)/* | gzip -9 >$(DISTDIR).tar.gz

distdir:
	@test -d $(DISTDIR) || mkdir $(DISTDIR)
	@mkdir -p $(DISTDIR)/test/pics $(DISTDIR)/docs $(DISTDIR)/examples
	@mkdir -p $(DISTDIR)/src/modules $(DISTDIR)/src/tesseract
	@for file in $(SRCS) $(MODULE_FILES) $(TESSERACT_FILES) $(TEST_FILES) $(DOCS) \
      $(CONTRIB_FILES); do \
        cp -pf $$file $(DISTDIR)/$$file; \
    done
	@for file in $(SRCS); do \
        sed -i 's/^VERSION=.*/VERSION=SVN-r$(VERSION)/' $(DISTDIR)/$$file; \
	done
	@for file in $(DOCS); do \
        sed -i '1s/\(.*\)SVN-snapshot\(.*\)/\1SVN-r$(VERSION)\2/' $(DISTDIR)/$$file; \
	done

distclean:
	@rm -rf $(DISTDIR)

.PHONY: dist distclean install uninstall

