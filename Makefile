##
# Plowshare Makefile
##

# Tools

INSTALL = install
LN_S    = ln -sf
RM      = rm -f

# Files

SRCS = src/download.sh src/upload.sh src/delete.sh src/list.sh \
       src/lib.sh src/strip_single_color.pl src/strip_threshold.pl

SETUP_FILES     = Makefile setup.sh
TEST_FILES      = test/lib.sh test/test_lib.sh test/test_modules.sh test/test_setup.sh \
                  $(wildcard test/pics/*)
MODULE_FILES    = $(wildcard src/modules/*.sh)
TESSERACT_FILES = $(addprefix src/tesseract/, alnum digit digit_ops plowshare_nobatch upper)

MANPAGES0= plowdown.1 plowup.1 plowdel.1 plowlist.1
MANPAGES = $(addprefix docs/,$(MANPAGES0))
DOCS     = CHANGELOG COPYING INSTALL README

CONTRIB_FILES = $(addprefix contrib/,caturl.sh plowdown_add_remote_loop.sh plowdown_loop.sh \
                plowdown_parallel.sh)

# Target path
# DESTDIR is for package creation only

PREFIX ?= /usr/local
BINDIR  = $(PREFIX)/bin
DATADIR = ${PREFIX}/share/plowshare
DOCDIR  = ${PREFIX}/share/doc/plowshare
MANDIR  = ${PREFIX}/share/man/man1

# Packaging
USE_GIT := $(shell test -d .git && echo "git")
SVN_LOG := $(shell LANG=C $(USE_GIT) svn info | grep ^Revision | cut -d' ' -f2)

VERSION = $(SVN_LOG)
DISTDIR = plowshare-SVN-r$(VERSION)-snapshot


install:
	$(INSTALL) -d $(DESTDIR)$(BINDIR)
	$(INSTALL) -d $(DESTDIR)$(DATADIR)
	$(INSTALL) -d $(DESTDIR)$(DATADIR)/modules
	$(INSTALL) -d $(DESTDIR)$(DATADIR)/tesseract
	$(INSTALL) -d $(DESTDIR)$(DOCDIR)
	$(INSTALL) -d $(DESTDIR)$(MANDIR)
	$(INSTALL) -m 644 $(MODULE_FILES) $(DESTDIR)$(DATADIR)/modules
	$(INSTALL) -m 644 $(TESSERACT_FILES) $(DESTDIR)$(DATADIR)/tesseract
	$(INSTALL) -m 755 $(SRCS) $(DESTDIR)$(DATADIR)
	$(INSTALL) -m 644 $(MANPAGES) $(DESTDIR)$(MANDIR)
	$(INSTALL) -m 644 $(DOCS) $(DESTDIR)$(DOCDIR)
	$(LN_S) $(DATADIR)/download.sh $(DESTDIR)$(BINDIR)/plowdown
	$(LN_S) $(DATADIR)/upload.sh   $(DESTDIR)$(BINDIR)/plowup
	$(LN_S) $(DATADIR)/delete.sh   $(DESTDIR)$(BINDIR)/plowdel
	$(LN_S) $(DATADIR)/list.sh     $(DESTDIR)$(BINDIR)/plowlist

uninstall:
	@$(RM) $(DESTDIR)$(BINDIR)/plowdown
	@$(RM) $(DESTDIR)$(BINDIR)/plowup
	@$(RM) $(DESTDIR)$(BINDIR)/plowdel
	@$(RM) $(DESTDIR)$(BINDIR)/plowlist
	@rm -rf $(DESTDIR)$(DATADIR) $(DESTDIR)$(DOCDIR)
	@$(RM) $(addprefix $(DESTDIR)$(MANDIR)/, $(MANPAGES0))

test:
	@echo "Not yet!"

dist: distdir
	@tar -cf - $(DISTDIR)/* | gzip -9 >$(DISTDIR).tar.gz
	@rm -rf $(DISTDIR)

distdir:
	@test -d $(DISTDIR) || mkdir $(DISTDIR)
	@mkdir -p $(DISTDIR)/test/pics $(DISTDIR)/docs $(DISTDIR)/contrib
	@mkdir -p $(DISTDIR)/src/modules $(DISTDIR)/src/tesseract
	@for file in $(SRCS) $(SETUP_FILES) $(MODULE_FILES) $(TESSERACT_FILES) \
			$(TEST_FILES) $(MANPAGES) $(DOCS) $(CONTRIB_FILES); do \
		cp -pf $$file $(DISTDIR)/$$file; \
	done
	@for file in $(SRCS); do \
		sed -i 's/^VERSION=.*/VERSION=SVN-r$(VERSION)/' $(DISTDIR)/$$file; \
	done
	@for file in $(DOCS); do \
		sed -i '1s/\(.*\)SVN-snapshot\(.*\)/\1SVN-r$(VERSION)\2/' $(DISTDIR)/$$file; \
	done

distclean:
	@rm -rf plowshare-SVN-r???*

.PHONY: dist distclean install uninstall test
