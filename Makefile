# =============================================================================
# private-data_backup — installation
#
#   make check        vérifie la syntaxe, shellcheck, la configuration, le manuel et les tests
#   make test         exécute les tests non interactifs (TUI)
#   make install      installe les scripts et la configuration
#   make reinstall    idem mais remplace la configuration existante
#   make uninstall    retire les scripts (PURGE=1 pour aussi la configuration)
#   make help         cette aide
#
# Variables (surchargables en ligne de commande) :
#   PREFIX           préfixe d'installation        (défaut : $(HOME)/.local)
#   BINDIR           dossier des exécutables       (défaut : $(PREFIX)/bin)
#   XDG_CONFIG_HOME  racine de configuration XDG   (défaut : $(HOME)/.config)
#   CONFDIR          dossier de configuration      (défaut : $(XDG_CONFIG_HOME)/private-data_backup)
#   DESTDIR          racine de staging (empaquetage)
#   FORCE=1          remplace la configuration existante
#   PURGE=1          uninstall retire aussi la configuration
#
# Exemples :
#   make install
#   make install PREFIX=/usr/local        # scripts dans /usr/local/bin
#   make install DESTDIR=/tmp/pkg         # empaquetage
#   make reinstall                        # remplace la configuration
# =============================================================================

PREFIX          ?= $(HOME)/.local
BINDIR          ?= $(PREFIX)/bin
XDG_CONFIG_HOME ?= $(HOME)/.config
CONFDIR         ?= $(XDG_CONFIG_HOME)/private-data_backup
MANDIR          ?= $(PREFIX)/share/man
DESTDIR         ?=
INSTALL         ?= install
FORCE           ?= 0
PURGE           ?= 0

SCRIPTS   := private-data_backup.sh private-data_backup-tui.sh
CONF      := private-data_backup.conf.example
MANPAGE   := private-data_backup.1
CONF_DEST := $(CONFDIR)/config

.PHONY: all help check test install install-scripts install-config install-man reinstall uninstall

all: check

help:
	@printf '\n'
	@printf 'private-data_backup — cibles disponibles\n\n'
	@printf '  make check       syntaxe + shellcheck + configuration + manuel + tests\n'
	@printf '  make test        exécute les tests non interactifs (TUI)\n'
	@printf '  make install     scripts dans %s, configuration dans %s, manuel dans %s\n' \
		'$(DESTDIR)$(BINDIR)' '$(DESTDIR)$(CONFDIR)' '$(DESTDIR)$(MANDIR)/man1'
	@printf '  make reinstall   comme install, en remplaçant la configuration\n'
	@printf '  make uninstall   retire les scripts (PURGE=1 : aussi la configuration)\n'
	@printf '\n'
	@printf 'Variables : PREFIX=%s BINDIR=%s CONFDIR=%s DESTDIR=%s\n\n' \
		'$(PREFIX)' '$(BINDIR)' '$(CONFDIR)' '$(DESTDIR)'

check:
	@for f in $(SCRIPTS); do \
		printf '  bash -n     %s\n' "$$f"; \
		bash -n "$$f" || exit 1; \
		printf '  shellcheck  %s\n' "$$f"; \
		shellcheck --enable=all "$$f" || exit 1; \
	done
	@printf '  config      %s\n' "$(CONF)"
	@./private-data_backup.sh --config "$(CONF)" config-check >/dev/null
	@printf '  manuel      %s\n' "$(MANPAGE)"
	@out="$$(groff -Kutf8 -man -z -ww "$(MANPAGE)" 2>&1)" || exit 1; \
	 if [ -n "$$out" ]; then printf '%s\n' "$$out"; exit 1; fi
	@$(MAKE) --no-print-directory test
	@printf '  OK\n'

test:
	@printf '  tests       tests/run.sh\n'
	@TERM=xterm-256color ./tests/run.sh

install: install-scripts install-config install-man

install-scripts:
	@$(INSTALL) -d "$(DESTDIR)$(BINDIR)"
	@$(INSTALL) -m 755 $(SCRIPTS) "$(DESTDIR)$(BINDIR)/"
	@printf '  scripts   -> %s\n' "$(DESTDIR)$(BINDIR)"

install-config:
	@$(INSTALL) -d -m 700 "$(DESTDIR)$(CONFDIR)"
	@if [ -f "$(DESTDIR)$(CONF_DEST)" ] && [ "$(FORCE)" != "1" ]; then \
		printf '  config    %s conservée (FORCE=1 pour remplacer)\n' "$(DESTDIR)$(CONF_DEST)"; \
	else \
		$(INSTALL) -m 600 "$(CONF)" "$(DESTDIR)$(CONF_DEST)"; \
		printf '  config    -> %s\n' "$(DESTDIR)$(CONF_DEST)"; \
	fi

install-man:
	@$(INSTALL) -d "$(DESTDIR)$(MANDIR)/man1"
	@$(INSTALL) -m 644 $(MANPAGE) "$(DESTDIR)$(MANDIR)/man1/"
	@printf '  manuel    -> %s\n' "$(DESTDIR)$(MANDIR)/man1/$(MANPAGE)"

reinstall: FORCE := 1
reinstall: install

uninstall:
	@rm -f "$(DESTDIR)$(BINDIR)/private-data_backup.sh" \
	       "$(DESTDIR)$(BINDIR)/private-data_backup-tui.sh" \
	       "$(DESTDIR)$(MANDIR)/man1/$(MANPAGE)"
	@printf '  scripts   retirés de %s\n' "$(DESTDIR)$(BINDIR)"
	@if [ "$(PURGE)" = "1" ]; then \
		rm -f "$(DESTDIR)$(CONF_DEST)"; \
		printf '  config    %s retirée\n' "$(DESTDIR)$(CONF_DEST)"; \
	else \
		printf '  config    %s conservée (PURGE=1 pour retirer)\n' "$(DESTDIR)$(CONF_DEST)"; \
	fi
