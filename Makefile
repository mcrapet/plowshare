##
# Plowshare Makefile
##

# Tools

INSTALL = install
LN_S    = ln -sf
RM      = rm -f

# Files

SRCS = src/download.sh src/upload.sh src/delete.sh src/list.sh \
       src/core.sh src/strip_single_color.pl src/strip_threshold.pl

SETUP_FILES     = Makefile setup.sh
TEST_FILES      = tests/modules.sh $(wildcard tests/*.t)
MODULE_FILES    = $(wildcard src/modules/*.sh) src/modules/config
TESSERACT_FILES = $(addprefix src/tesseract/, alnum digit digit_ops plowshare_nobatch upper)

MANPAGES1 = plowdown.1 plowup.1 plowdel.1 plowlist.1
MANPAGES5 = plowshare.conf.5
MANPAGES  = $(addprefix docs/,$(MANPAGES1)) $(addprefix docs/,$(MANPAGES5))
DOCS      = AUTHORS CHANGELOG COPYING INSTALL README

CONTRIB_FILES = $(addprefix contrib/,caturl.sh plowdown_add_remote_loop.sh plowdown_loop.sh \
                plowdown_parallel.sh)
ETC_FILES = $(addprefix etc/,plowshare.completion)

# Target path
# DESTDIR is for package creation only

PREFIX ?= /usr/local
ETCDIR  = /etc
BINDIR  = $(PREFIX)/bin
DATADIR = ${PREFIX}/share/plowshare
DOCDIR  = ${PREFIX}/share/doc/plowshare
MANDIR  = ${PREFIX}/share/man/man

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
	$(INSTALL) -d $(DESTDIR)$(MANDIR)1
	$(INSTALL) -d $(DESTDIR)$(MANDIR)5
	$(INSTALL) -m 644 $(MODULE_FILES) $(DESTDIR)$(DATADIR)/modules
	$(INSTALL) -m 644 $(TESSERACT_FILES) $(DESTDIR)$(DATADIR)/tesseract
	$(INSTALL) -m 755 $(SRCS) $(DESTDIR)$(DATADIR)
	$(INSTALL) -m 644 $(addprefix docs/,$(MANPAGES1)) $(DESTDIR)$(MANDIR)1
	$(INSTALL) -m 644 $(addprefix docs/,$(MANPAGES5)) $(DESTDIR)$(MANDIR)5
	$(INSTALL) -m 644 README $(DESTDIR)$(DOCDIR)
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
	@$(RM) $(addprefix $(DESTDIR)$(MANDIR)1/, $(MANPAGES1))
	@$(RM) $(addprefix $(DESTDIR)$(MANDIR)5/, $(MANPAGES5))

test:
	@cd tests && ./modules.sh -l

install_bash_completion:
	@sed -e "s,CDIR=/usr/local/share/plowshare,CDIR=$(DATADIR)," etc/plowshare.completion > $(DESTDIR)$(ETCDIR)/bash_completion.d/plowshare

dist: distdir
	@tar -cf - $(DISTDIR)/* | gzip -9 >$(DISTDIR).tar.gz
	@rm -rf $(DISTDIR)

distdir:
	@test -d $(DISTDIR) || mkdir $(DISTDIR)
	@mkdir -p $(DISTDIR)/etc $(DISTDIR)/tests $(DISTDIR)/docs $(DISTDIR)/contrib
	@mkdir -p $(DISTDIR)/src/modules $(DISTDIR)/src/tesseract
	@for file in $(SRCS) $(SETUP_FILES) $(MODULE_FILES) $(TESSERACT_FILES) \
			$(TEST_FILES) $(MANPAGES) $(DOCS) $(ETC_FILES) $(CONTRIB_FILES); do \
		cp -pf $$file $(DISTDIR)/$$file; \
	done
	@for file in $(SRCS); do \
		sed -i 's/^VERSION=.*/VERSION=SVN-r$(VERSION)/' $(DISTDIR)/$$file; \
	done
	@for file in $(DOCS) $(MANPAGES); do \
		sed -i '/[Pp]lowshare/s/\(.*\)SVN-snapshot\(.*\)/\1SVN-r$(VERSION)\2/' $(DISTDIR)/$$file; \
	done

distclean:
	@rm -rf plowshare-SVN-r???*

.PHONY: dist distclean install uninstall test
