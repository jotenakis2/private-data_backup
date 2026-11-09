# private-data_backup

Sauvegarde et restauration de données privées vers un stockage dédié (NAS,
disque externe), par profils déclarés dans un fichier de configuration.

- archives `tar.gz` **atomiques** (`.part` → vérification → renommage) et
  horodatées dans le nom ;
- vérification d'intégrité avant toute restauration (repli sur la version
  précédente si la plus récente est corrompue) ;
- **instantané** de l'état courant avant écrasement + fichiers remplacés
  conservés en `*.pre-restore-<date>` ;
- chiffrement optionnel avec `age` (clé `age1…` ou clé SSH publique) ;
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
man private-data_backup
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
private-data_backup.sh delete-archive FICHIER... [--yes] [--dry-run]
private-data_backup.sh encrypt-archives [PROFIL...] [--dry-run] [--yes]
private-data_backup.sh adopt-orphans [PROFIL...] [--dry-run] [--yes]
private-data_backup.sh timer-add PROFIL quotidien HH:MM
private-data_backup.sh timer-add PROFIL hebdomadaire JOUR HH:MM
private-data_backup.sh timer-remove PROFIL
private-data_backup.sh timer-list [--porcelain]
private-data_backup.sh timer-run PROFIL
private-data_backup.sh timer-linger
private-data_backup.sh profile-add NOM DOSSIER [BINAIRE] [EXCLUSIONS]
private-data_backup.sh profile-remove NOM
private-data_backup.sh config-set CLE=VALEUR...
private-data_backup.sh config-path | config-check
private-data_backup.sh --delete-logs [--dry-run] [--yes]
private-data_backup.sh help | --version
```

Interface texte :

```sh
private-data_backup-tui.sh      # Description / Sauvegarder / Restaurer / Archives / Profils / Planification / Configuration
```

Codes de sortie : `0` succès, `1` échec, `2` usage ou configuration invalide, `3` opération annulée.

## Sauvegardes automatiques

Un timer systemd **utilisateur** par profil (aucun root) :

```sh
private-data_backup.sh timer-add DOCUMENTS quotidien 18:30
private-data_backup.sh timer-add IMAGES hebdomadaire dimanche 03:00
private-data_backup.sh timer-list
private-data_backup.sh timer-run DOCUMENTS     # lancer maintenant
private-data_backup.sh timer-remove DOCUMENTS  # retirer la planification
```

Les unités sont écrites dans `~/.config/systemd/user/`
(`private-data_backup@.service` et `private-data_backup@PROFIL.timer`), puis
activées avec `systemctl --user enable --now`. Le service utilise le chemin
absolu du script et le fichier de configuration chargé.

Sans session ouverte, les timers ne tournent pas. Pour les exécuter en
continu, activer le linger (une fois, en root) :

```sh
private-data_backup.sh timer-linger
```

`timer-list` affiche la fréquence, la prochaine exécution, l'état, le dernier
résultat et rappelle l'état du linger. La TUI expose les mêmes actions dans
l'écran **Planification**.

## Configuration

Fichier bash, chargé dans cet ordre :

1. `--config FICHIER`
2. `$PRIVATE_BACKUP_CONFIG`
3. `private-data_backup.conf` à côté du script (liens résolus)
4. `${XDG_CONFIG_HOME:-$HOME/.config}/private-data_backup/config`

Le fichier livré (`private-data_backup.conf.example`) sert de modèle : profils
(`SOURCES`), binaires surveillés (`COMMANDS`),
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
| `age` | le chiffrement est activé (`ENCRYPT=age`) |
| `gum` | lancement de l'interface texte |
| `systemctl` / `systemd` | utilisation des sauvegardes automatiques (`timer-*`) |
| `loginctl` | contrôle et activation du linger |
| `pkexec` | `timer-linger` (élévation pour `loginctl enable-linger`) |
| `awk` | interface texte (mise en forme des tailles) |
