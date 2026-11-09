# private-data-backup

Sauvegarde et restauration de données privées vers un stockage dédié (NAS,
disque externe), par profils déclarés dans un fichier de configuration.

- archives `tar.gz` **atomiques** (`.part` → vérification → renommage) et
  horodatées dans le nom ;
- vérification d'intégrité avant toute restauration (repli sur la version
  précédente si la plus récente est corrompue) ;
- **instantané** de l'état courant avant écrasement + fichiers remplacés
  conservés en `*.pre-restore-<date>` ;
- chiffrement optionnel (gpg / age) ;
- rétention configurable, purge des profils retirés de la configuration ;
- journaux horodatés détaillés (option : liste des fichiers) ;
- interface texte (TUI) à base de [`gum`](https://github.com/charmbracelet/gum).

## Installation

```sh
make check      # syntaxe + shellcheck + validation de la configuration
make install    # scripts dans ~/.local/bin, configuration dans ~/.config/private-data_backup/config,
                # page de manuel dans ~/.local/share/man/man1
```

Variables utiles : `PREFIX`, `BINDIR`, `XDG_CONFIG_HOME`, `CONFDIR`,
`DESTDIR` (empaquetage), `FORCE=1` (remplacer la configuration),
`PURGE=1` (retirer aussi la configuration à la désinstallation).

```sh
make install PREFIX=/usr/local
make uninstall
```

La configuration existante n'est **jamais** écrasée par `make install` :
utiliser `make reinstall` pour la remplacer explicitement.

## Documentation

```sh
man private-data-backup
private-data_backup.sh -h
```

## Utilisation

```sh
private-data_backup.sh backup  [PROFIL...] [--dry-run] [--no-verify]
private-data_backup.sh restore [PROFIL]    [--yes] [--dry-run] [--snapshot|--no-snapshot]
private-data_backup.sh rollback [PROFIL]   [--yes] [--dry-run]
private-data_backup.sh delete_old [--keep N] [--orphans|--purge-orphans] [--dry-run] [--yes]
private-data_backup.sh show | list [PROFIL]
private-data_backup.sh verify FICHIER
private-data_backup.sh delete-archive FICHIER [--yes] [--dry-run]
private-data_backup.sh profile-add NOM DOSSIER [BINAIRE] [EXCLUSIONS]
private-data_backup.sh profile-remove NOM
private-data_backup.sh config-set CLE=VALEUR...
private-data_backup.sh config-path | config-check
private-data_backup.sh help | --version
```

Interface texte :

```sh
private-data_backup-tui.sh      # Sauvegarder / Restaurer / Archives / Profils / Configuration
```

Codes de sortie : `0` succès, `1` échec, `2` usage ou configuration invalide.

## Configuration

Fichier bash, chargé dans cet ordre :

1. `--config FICHIER`
2. `$PRIVATE_BACKUP_CONFIG`
3. `private_data_backup.conf` à côté du script (liens résolus)
4. `${XDG_CONFIG_HOME:-$HOME/.config}/private-data_backup/config`

Le fichier livré (`private-data_backup.conf.example`) sert de modèle : profils
(`SOURCES`), binaires surveillés (`COMMANDS`), services (`SERVICES`),
exclusions (`EXCLUDES`), stockage, rétention, instantanés, journalisation,
chiffrement. Les blocs `# >>> NOM` / `# <<< NOM` sont réécrits par
`profile-add`/`profile-remove` et par la TUI ; les commentaires doivent rester
en dehors.

## Prérequis

**Obligatoires** — vérifiés au démarrage, tous les manquants sont signalés
d'un coup (code retour 1) : `bash`, `tar`, `find`, `sort`, `awk`, `stat`,
`findmnt`, `flock` (util-linux), `date`, `timeout`, `du`, `df`, `readlink`
(coreutils), `pgrep` (procps-ng).

**Conditionnels** :

| Outil | Requis quand |
|---|---|
| `systemctl` | un profil déclare un service (`SERVICES`) |
| `gpg` / `age` | le chiffrement est activé (`ENCRYPT`) |
| `gum` | lancement de l'interface texte |
| `awk` | interface texte (mise en forme des tailles) |
