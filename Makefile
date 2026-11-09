# =============================================================================
# private-data-backup — installation
#
#   make check        vérifie la syntaxe, shellcheck et la configuration
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
DESTDIR         ?=
INSTALL         ?= install
FORCE           ?= 0
PURGE           ?= 0

SCRIPTS   := private-data_backup.sh private-data_backup-tui.sh
CONF      := private_data_backup.conf
CONF_DEST := $(CONFDIR)/config

.PHONY: all help check install install-scripts install-config reinstall uninstall

all: check

help:
	@printf '\n'
	@printf 'private-data-backup — cibles disponibles\n\n'
	@printf '  make check       syntaxe + shellcheck + validation de la configuration\n'
	@printf '  make install     scripts dans %s, configuration dans %s\n' '$(DESTDIR)$(BINDIR)' '$(DESTDIR)$(CONFDIR)'
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
	@printf '  OK\n'

install: install-scripts install-config

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

reinstall: FORCE := 1
reinstall: install

uninstall:
	@rm -f "$(DESTDIR)$(BINDIR)/private-data_backup.sh" \
	       "$(DESTDIR)$(BINDIR)/private-data_backup-tui.sh"
	@printf '  scripts   retirés de %s\n' "$(DESTDIR)$(BINDIR)"
	@if [ "$(PURGE)" = "1" ]; then \
		rm -f "$(DESTDIR)$(CONF_DEST)"; \
		printf '  config    %s retirée\n' "$(DESTDIR)$(CONF_DEST)"; \
	else \
		printf '  config    %s conservée (PURGE=1 pour retirer)\n' "$(DESTDIR)$(CONF_DEST)"; \
	fi
