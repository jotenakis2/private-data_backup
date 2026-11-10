#!/usr/bin/env bash
# shellcheck enable=all
# =============================================================================
# private-data_backup.sh — sauvegarde / restauration de données privées
#
# Usage :
#   private-data_backup.sh backup  [PROFIL...] [--dry-run] [--no-verify]
#   private-data_backup.sh restore [PROFIL]    [--yes] [--snapshot|--no-snapshot]
#   private-data_backup.sh delete_old [--keep N] [--orphans] [--dry-run] [--yes]
#   private-data_backup.sh show
#   private-data_backup.sh list [PROFIL]
#   private-data_backup.sh timer-add PROFIL quotidien HH:MM
#   private-data_backup.sh timer-add PROFIL hebdomadaire JOUR HH:MM
#   private-data_backup.sh timer-list | timer-remove PROFIL | timer-run PROFIL
#   private-data_backup.sh timer-shutdown-enable | timer-shutdown-disable
#   private-data_backup.sh backup-pending [--shutdown]
#   private-data_backup.sh timer-linger
#   private-data_backup.sh help | --version
#
# Politique d'erreur : PAS de `set -e`. Il rend le comportement des fonctions
# imprévisible (un test qui échoue, une commande dans un `if`, une substitution
# de processus… peuvent tuer le script). Chaque commande est donc testée
# explicitement, les erreurs sont accumulées et le code de sortie final vaut :
#   0 = succès, 1 = au moins un échec, 2 = usage / configuration invalide.
#
# Secrets : umask 077, archives et logs en 0600, dossiers en 0700.
# =============================================================================

set -uo pipefail
umask 077
export LC_COLLATE=C

# =============================================================================
# CONSTANTES ET CONFIGURATION
# =============================================================================
# La configuration (profils, stockage, exclusions, chiffrement…) ne vit plus
# dans ce script : elle est lue dans un fichier bash, chargé au niveau global
# juste avant `main` (voir « AMORÇAGE » en fin de fichier) pour que ses
# tableaux associatifs restent globaux.
#
# Emplacements recherchés, dans l'ordre :
#   1. --config FICHIER
#   2. $PRIVATE_BACKUP_CONFIG
#   3. private-data_backup.conf à côté du script (liens symboliques résolus)
#   4. ${XDG_CONFIG_HOME:-$HOME/.config}/private-data_backup/config
#
# Toute variable absente du fichier retombe sur `_config_defaults`.

readonly VER="1.4"
SCRIPTNAME="${0##*/}"
SCRIPTNAME="${SCRIPTNAME%.sh}"
readonly SCRIPTNAME

SELF_PATH="$(readlink -f -- "${BASH_SOURCE[0]:-$0}" 2>/dev/null)" || SELF_PATH="${BASH_SOURCE[0]:-$0}"
readonly SELF_PATH

readonly CONFIG_BASENAME="private-data_backup.conf"
readonly SNAPSHOT_SUBDIR="pre-restore"

# Valeurs de repli (surchargées par le fichier de configuration).
NAS=""
BACKUP_SUBDIR=""
KEEP_DEFAULT=1
VERIFY_DEFAULT=1
SNAPSHOT_DEFAULT="auto"
SNAPSHOT_MAX_MB=512
NAS_TIMEOUT=20
# Attente maximale du verrou (secondes). 0 = échec immédiat. Les services
# planifiés la portent à 2 h pour que des timers simultanés s'enchaînent au
# lieu d'échouer.
LOCK_WAIT="${PRIVATE_BACKUP_LOCK_WAIT:-0}"
# Mode strict : un profil ignoré (application ouverte, source absente) compte
# comme un échec. Activé par les services systemd planifiés, pour que
# systemd/journal/timer-list signalent une sauvegarde non effectuée.
STRICT_SKIP="${PRIVATE_BACKUP_STRICT_SKIP:-0}"
ENCRYPT=""
AGE_RECIPIENT=""
AGE_IDENTITY=""

# Tableaux remplis par le fichier de configuration. Déclarés ici (et non dans
# le fichier) pour qu'il puisse faire de simples affectations.
declare -A SOURCES=()
declare -A COMMANDS=()
declare -A EXCLUDES=()

# Fichier de configuration effectivement chargé.
CFG_FILE=""

# =============================================================================
# ÉTAT INTERNE
# =============================================================================

C_RED=''
C_GREEN=''
C_YELLOW=''
C_CYAN=''
C_BOLD=''
C_DIM=''
C_RESET=''

SPIN_FRAMES=('⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏')

LOG_FILE=""
CHILD_PID=0
PART_FILE=""
RUN_DATE=""
NAS_MOUNT=""
FAILURES=0
INTERRUPTED=0
LOG_RUN=0
needs_lock=0
DELETE_LOGS=0

DRY_RUN=0
ASSUME_YES=0
VERIFY=1
KEEP=1
ORPHANS=0
PURGE_ORPHANS=0
PORCELAIN=0
ARCHIVE_FILE=""
PLAN_FILE=""
APPLY_PLAN=""
SYSTEMCTL_BIN="${PRIVATE_BACKUP_SYSTEMCTL:-systemctl}"
# Sauvegardes reportées à l'extinction (par planification).
STATE_BASE="${XDG_STATE_HOME:-${HOME}/.local/state}"
[[ ${STATE_BASE} == /* ]] || STATE_BASE="${HOME}/.local/state"
PENDING_DIR="${STATE_BASE}/${SCRIPTNAME}/pending"
SYSTEM_UNIT_DIR="${PRIVATE_BACKUP_SYSTEM_UNIT_DIR:-/etc/systemd/system}"
SYSTEM_UNIT_NAME="${SCRIPTNAME}-shutdown.service"
SESSION_UNIT_NAME="${SCRIPTNAME}-session.service"
EXTINCTION_SET=0
EXTINCTION_VAL=0
SHUTDOWN_RUN=0
NOTIFY_ENABLED="${PRIVATE_BACKUP_NOTIFY:-1}"
SNAPSHOT_MODE="auto"

# Archives découvertes : triées par groupe puis date décroissante.
declare -a ARCH_GROUP=() ARCH_DT=() ARCH_PATH=() ARCH_SIZE=()

# Sorties de `_parse_archive`.
ARCH_PROFILE=""
ARCH_DATEKEY=""

# Sorties de `_latest_archive`.
LATEST_PATH=""
LATEST_DT=""
LATEST_SIZE=0

# =============================================================================
# OUTILLAGE GÉNÉRIQUE
# =============================================================================

_enable_colors() {
	[[ -t 1 ]] && [[ -t 2 ]] || return 0
	command -v tput >/dev/null 2>&1 || return 0
	[[ -z "${NO_COLOR:-}" ]] || return 0
	C_RED="$(tput setaf 1)"    || C_RED=''
	C_GREEN="$(tput setaf 2)"  || C_GREEN=''
	C_YELLOW="$(tput setaf 3)" || C_YELLOW=''
	C_CYAN="$(tput setaf 6)"   || C_CYAN=''
	C_BOLD="$(tput bold)"      || C_BOLD=''
	C_DIM="$(tput dim)"        || C_DIM=''
	C_RESET="$(tput sgr0)"     || C_RESET=''
	return 0
}

# Écriture dans le log : ne doit jamais échouer, même sans log.
# Chaque ligne est horodatée.
_log_write() {
	[[ -n "${LOG_FILE}" ]] || return 0
	local ts=""
	ts="$(date '+%Y-%m-%d %H:%M:%S')" || ts="?"
	printf '[%s] %s\n' "${ts}" "${*}" >>"${LOG_FILE}" 2>/dev/null || return 0
	return 0
}

# Détail destiné au log uniquement (la console reste lisible).
_log() {
	_log_write "${*}"
	return 0
}

# Supprime les .part laissés par une exécution interrompue (SIGKILL à
# l'extinction, coupure). Appelé avec le verrou tenu : aucun backup actif.
_cleanup_stale_parts() {
	local file="" dir="" owner="" rc=0
	for dir in "${NAS_MOUNT}" "${NAS_MOUNT}/${SNAPSHOT_SUBDIR}"; do
		[[ -d ${dir} ]] || continue
		for file in "${dir}"/*.part; do
			[[ -e ${file} ]] || continue
			# Uniquement nos archives, et uniquement celles de cet utilisateur :
			# le verrou est par UID, un autre utilisateur peut sauvegarder.
			case "${file##*/}" in
			*.tar.gz.part | *.tar.gz.age.part) ;;
			*) continue ;;
			esac
			owner="$(stat -c %u -- "${file}" 2>/dev/null)" || continue
			[[ ${owner} == "${UID}" ]] || continue
			_WARN "reste d'archive interrompue supprimé : ${file##*/}"
			rm -f -- "${file}" || rc=1
		done
	done
	return "${rc}"
}

# Prend le verrou exclusif (une seule instance qui écrit à la fois).
_acquire_lock() {
	_need flock || return 1
	local lock_dir="" lock_file=""
	lock_dir="${XDG_RUNTIME_DIR:-${HOME}/.local/state/${SCRIPTNAME}}"
	[[ ${lock_dir} == /* ]] || lock_dir="${HOME}/.local/state/${SCRIPTNAME}"
	if ! mkdir -p -- "${lock_dir}" 2>/dev/null; then
		_ERR "dossier de verrou inaccessible : ${lock_dir}"
		return 1
	fi
	chmod 700 -- "${lock_dir}" 2>/dev/null || true
	lock_file="${lock_dir}/${SCRIPTNAME}.${UID}.lock"
	if ! exec 9>"${lock_file}"; then
		_ERR "impossible d'ouvrir le verrou ${lock_file}"
		return 1
	fi
	if [[ ${LOCK_WAIT} =~ ^[0-9]+$ ]] && ((LOCK_WAIT > 0)); then
		if ! flock -w "${LOCK_WAIT}" 9; then
			_ERR "verrou occupé depuis plus de ${LOCK_WAIT} s (${lock_file})"
			return 1
		fi
	elif ! flock -n 9; then
		_ERR "une autre instance de ${SCRIPTNAME} est déjà en cours (${lock_file})"
		return 1
	fi
	return 0
}

# Supprime les journaux de ~/.local/share/$SCRIPTNAME (--delete-logs).
delete_logs() {
	local dir="${HOME}/.local/share/${SCRIPTNAME}"
	local f sz=0 total=0 rc=0 human=""
	local -a files=() others=()

	if [[ ! -d ${dir} ]]; then
		_INFO "aucun journal (${dir} absent)"
		return 0
	fi
	# Journaux + restes éventuels du fichier témoin d'écriture (.write-probe.PID).
	mapfile -t files < <(find "${dir}" -maxdepth 1 -type f \
		\( -name "${SCRIPTNAME}-*.log" -o -name ".write-probe.*" \) -print 2>/dev/null || true)
	# Tout le reste est laissé en place (et signalé).
	mapfile -t others < <(find "${dir}" -maxdepth 1 -type f \
		! -name "${SCRIPTNAME}-*.log" ! -name ".write-probe.*" -print 2>/dev/null || true)

	if ((${#files[@]} == 0)); then
		_INFO "aucun journal à supprimer dans ${dir}"
		if ((${#others[@]} > 0)); then
			local no=${#others[@]} c=""
			c="$(_count "${no}" "autre fichier conservé" "autres fichiers conservés")"
			_INFO "${c}"
		fi
		return 0
	fi

	for f in "${files[@]}"; do
		sz="$(_file_size "${f}")"
		total=$((total + sz))
	done
	human="$(_human_size "${total}")"

	if ((DRY_RUN == 1)); then
		for f in "${files[@]}"; do
			_INFO "serait supprimé : ${f##*/}"
		done
		local nf=${#files[@]} c=""
		c="$(_count "${nf}" journal journaux)"
		_INFO "${c}, ${human} — --dry-run, rien n'a été supprimé"
		if ((${#others[@]} > 0)); then
			local no=${#others[@]} c=""
			c="$(_count "${no}" "autre fichier conservé" "autres fichiers conservés")"
			_INFO "${c}"
		fi
		return 0
	fi

	local nf=${#files[@]} c=""
	c="$(_count "${nf}" journal journaux)"
	if ! _confirm "Supprimer ${c} de ${dir} (${human}) ?"; then
		_INFO "annulé — rien n'a été supprimé"
		return 0
	fi

	for f in "${files[@]}"; do
		if ! _RUN "Suppression de ${f##*/}" rm -f -- "${f}"; then
			rc=1
		fi
	done
	if ((${#others[@]} > 0)); then
		local no=${#others[@]} c=""
		c="$(_count "${no}" "autre fichier conservé" "autres fichiers conservés")"
		_INFO "${c} dans ${dir}"
	fi
	printf '\n'
	return "${rc}"
}

_init_log() {
	local dir="${HOME}/.local/share/${SCRIPTNAME}"
	if ! mkdir -p -- "${dir}" 2>/dev/null; then
		LOG_FILE=""
		_WARN "dossier de logs inaccessible (${dir}) : sortie non journalisée"
		return 0
	fi
	chmod 700 -- "${dir}" 2>/dev/null
	# Le fichier n'est créé qu'au premier message (pas de log vide).
	LOG_FILE="${dir}/${SCRIPTNAME}-${RUN_DATE}.log"
	local probe="${dir}/.write-probe.$$"
	if ! : >"${probe}" 2>/dev/null; then
		LOG_FILE=""
		_WARN "dossier de logs non inscriptible (${dir}) : sortie non journalisée"
		return 0
	fi
	rm -f -- "${probe}" 2>/dev/null
	return 0
}

_OK() {
	printf ' %b✓%b %s\n' "${C_GREEN}" "${C_RESET}" "${*}"
	_log_write " ✓ ${*}"
	return 0
}

_ERR() {
	printf ' %b✗%b %s\n' "${C_RED}" "${C_RESET}" "${*}" >&2
	_log_write " ✗ ${*}"
	return 0
}

_WARN() {
	printf ' %b!%b %s\n' "${C_YELLOW}" "${C_RESET}" "${*}" >&2
	_log_write " ! ${*}"
	return 0
}

_INFO() {
	printf ' %b·%b %s\n' "${C_CYAN}" "${C_RESET}" "${*}"
	return 0
}

_human_size() {
	local bytes="${1:-0}"
	LC_ALL=C awk -v b="${bytes}" 'BEGIN {
		split("o Ko Mo Go To", u, " ")
		i = 1
		s = b + 0
		while (s >= 1024 && i < 5) { s /= 1024; i++ }
		if (i == 1) printf "%d %s", s, u[i]
		else printf "%.1f %s", s, u[i]
	}'
	return 0
}

# _count N singulier pluriel -> « 3 archives », « 1 archive » (0 = pluriel)
_count() {
	local n="${1}" w=""
	if [[ ${n} == "1" ]]; then w="${2}"; else w="${3}"; fi
	printf '%s %s' "${n}" "${w}"
	return 0
}

_file_size() {
	local size
	size="$(stat -c %s -- "${1}" 2>/dev/null)" || size=0
	[[ ${size} =~ ^[0-9]+$ ]] || size=0
	printf '%s' "${size}"
}

_need() {
	local tool missing=0
	for tool in "${@}"; do
		if ! command -v "${tool}" >/dev/null 2>&1; then
			_ERR "dépendance manquante : ${tool}"
			missing=1
		fi
	done
	return "${missing}"
}

# Remplit à la largeur demandée en caractères (bash printf compterait les
# octets et décalerait les en-têtes accentués).
_pad() {
	local s="${1:-}" w="${2:-0}" n=0
	local LC_ALL=C.UTF-8
	n=$((w - ${#s}))
	((n < 0)) && n=0
	printf '%s%*s' "${s}" "${n}" ''
}

_dashes() {
	printf '%*s' "${1:-1}" '' | tr ' ' '-'
}

# =============================================================================
# FICHIER DE CONFIGURATION
# =============================================================================

# La configuration n'est pas nécessaire pour l'aide et la version.
_cfg_needed() {
	local i=0
	local -a a=("${@}")
	((${#a[@]} == 0)) && return 1
	while ((i < ${#a[@]})); do
		case "${a[${i}]}" in
		--config|--keep)
			i=$((i + 2))
			continue
			;;
		--config=*|--keep=*)
			i=$((i + 1))
			continue
			;;
		help|--help|-h|-help|--version|-V|--delete-logs) return 1 ;;
		*) ;;
		esac
		i=$((i + 1))
	done
	return 0
}

_script_dir() {
	local src="${BASH_SOURCE[0]:-}" real=""
	[[ -n ${src} ]] || return 0
	real="$(readlink -f -- "${src}" 2>/dev/null)" || real="${src}"
	printf '%s' "${real%/*}"
}

# Résout le chemin du fichier de configuration (1 = --config sans valeur).
_config_path() {
	local explicit="" arg dir="" i=0
	local -a args=("${@}")

	while ((i < ${#args[@]})); do
		arg="${args[${i}]}"
		case "${arg}" in
		--config)
			i=$((i + 1))
			explicit="${args[${i}]:-}"
			if [[ -z ${explicit} ]]; then
				return 1
			fi
			;;
		--config=*) explicit="${arg#*=}" ;;
		*) ;;
		esac
		i=$((i + 1))
	done

	if [[ -n ${explicit} ]]; then
		printf '%s' "${explicit}"
		return 0
	fi
	if [[ -n "${PRIVATE_BACKUP_CONFIG:-}" ]]; then
		printf '%s' "${PRIVATE_BACKUP_CONFIG}"
		return 0
	fi

	dir="$(_script_dir)"
	if [[ -n ${dir} ]] && [[ -f "${dir}/${CONFIG_BASENAME}" ]]; then
		printf '%s' "${dir}/${CONFIG_BASENAME}"
		return 0
	fi
	dir="${XDG_CONFIG_HOME:-${HOME}/.config}/${SCRIPTNAME}/config"
	if [[ -f ${dir} ]]; then
		printf '%s' "${dir}"
		return 0
	fi
	printf '%s' ""
	return 0
}

_config_not_found() {
	local dir=""
	dir="$(_script_dir)"
	_ERR "aucun fichier de configuration trouvé"
	printf '   attendu : %s\n' "${dir:+${dir}/${CONFIG_BASENAME}}" >&2
	printf '          ou %s\n' "${XDG_CONFIG_HOME:-${HOME}/.config}/${SCRIPTNAME}/config" >&2
	printf '   ou : --config FICHIER (ou la variable %s)\n' "PRIVATE_BACKUP_CONFIG" >&2
	return 0
}

# Exécuté par le script : un fichier modifiable par le groupe ou tous est un
# risque d'exécution de code.
_config_perms_warn() {
	local perms=""
	perms="$(stat -c %A -- "${1}" 2>/dev/null)" || perms=""
	[[ ${#perms} -eq 10 ]] || return 0
	if [[ ${perms:5:1} == "w" ]] || [[ ${perms:8:1} == "w" ]]; then
		_WARN "${1} est modifiable par le groupe ou tous : ce fichier est exécuté par ${SCRIPTNAME}"
	fi
	return 0
}

_config_defaults() {
	: "${NAS:=/media/NAS}"
	: "${BACKUP_SUBDIR:=backup/data2restore}"
	: "${KEEP_DEFAULT:=1}"
	: "${VERIFY_DEFAULT:=1}"
	: "${SNAPSHOT_DEFAULT:=auto}"
	: "${SNAPSHOT_MAX_MB:=512}"
	: "${NAS_TIMEOUT:=20}"
	: "${LOG_FILES:=1}"
	: "${ENCRYPT:=}"
	: "${AGE_RECIPIENT:=}"
	: "${AGE_IDENTITY:=}"

	# Surcharges d'environnement (tests, usage ponctuel) : elles ont le dernier
	# mot sur le fichier de configuration.
	if [[ -n "${PRIVATE_BACKUP_NAS:-}" ]]; then
		NAS="${PRIVATE_BACKUP_NAS}"
	fi
	if [[ -n "${PRIVATE_BACKUP_SUBDIR:-}" ]]; then
		BACKUP_SUBDIR="${PRIVATE_BACKUP_SUBDIR}"
	fi
	if [[ -n "${PRIVATE_BACKUP_ENCRYPT:-}" ]]; then
		ENCRYPT="${PRIVATE_BACKUP_ENCRYPT}"
	fi
	if [[ -n "${PRIVATE_BACKUP_AGE_RECIPIENT:-}" ]]; then
		AGE_RECIPIENT="${PRIVATE_BACKUP_AGE_RECIPIENT}"
	fi
	if [[ -n "${PRIVATE_BACKUP_AGE_IDENTITY:-}" ]]; then
		AGE_IDENTITY="${PRIVATE_BACKUP_AGE_IDENTITY}"
	fi

	VERIFY="${VERIFY_DEFAULT}"
	KEEP="${KEEP_DEFAULT}"
	SNAPSHOT_MODE="${SNAPSHOT_DEFAULT}"
	return 0
}

_config_validate() {
	local k errs=0

	if ((${#SOURCES[@]} == 0)); then
		_ERR "aucun profil défini : tableau SOURCES vide dans ${CFG_FILE}"
		return 1
	fi

	for k in "${!SOURCES[@]}"; do
		if ! _valid_profile_name "${k}"; then
			_ERR "nom de profil invalide : ${k}"
			errs=1
		fi
		if ! _source_path_ok "${SOURCES[${k}]}"; then
			_ERR "SOURCES[${k}] doit être relatif à \$HOME, sans « .. » ni « . » (reçu : ${SOURCES[${k}]:-vide})"
			errs=1
		fi
	done

	for k in "${!COMMANDS[@]}"; do
		if ! _valid_profile_name "${k}"; then
			_ERR "nom de profil invalide dans COMMANDS : ${k}"
			errs=1
		fi
		_known_profile "${k}" || _WARN "COMMANDS[${k}] : profil absent de SOURCES (ignoré)"
	done
	for k in "${!EXCLUDES[@]}"; do
		if ! _valid_profile_name "${k}"; then
			_ERR "nom de profil invalide dans EXCLUDES : ${k}"
			errs=1
		fi
		_known_profile "${k}" || _WARN "EXCLUDES[${k}] : profil absent de SOURCES (ignoré)"
	done

	case "${VERIFY_DEFAULT}" in
	0|1) ;;
	*)
		_ERR "VERIFY_DEFAULT doit valoir 0 ou 1 (reçu : ${VERIFY_DEFAULT})"
		errs=1
		;;
	esac
	case "${SNAPSHOT_DEFAULT}" in
	auto|yes|no) ;;
	*)
		_ERR "SNAPSHOT_DEFAULT doit valoir auto, yes ou no (reçu : ${SNAPSHOT_DEFAULT})"
		errs=1
		;;
	esac
	case "${ENCRYPT}" in
	""|age) ;;
	*)
		_ERR "ENCRYPT doit valoir \"\" ou age (reçu : ${ENCRYPT})"
		errs=1
		;;
	esac
	if [[ ! ${KEEP_DEFAULT} =~ ^[0-9]+$ ]] || ((KEEP_DEFAULT < 1)); then
		_ERR "KEEP_DEFAULT doit être un entier >= 1 (reçu : ${KEEP_DEFAULT})"
		errs=1
	fi
	if [[ ! ${SNAPSHOT_MAX_MB} =~ ^[0-9]+$ ]] || ((SNAPSHOT_MAX_MB < 1)); then
		_ERR "SNAPSHOT_MAX_MB doit être un entier >= 1 (reçu : ${SNAPSHOT_MAX_MB})"
		errs=1
	fi
	if [[ ! ${NAS_TIMEOUT} =~ ^[0-9]+$ ]] || ((NAS_TIMEOUT < 1)); then
		_ERR "NAS_TIMEOUT doit être un entier >= 1 (reçu : ${NAS_TIMEOUT})"
		errs=1
	fi
	if [[ ${ENCRYPT} == "age" ]] && [[ -z ${AGE_IDENTITY} ]]; then
		_ERR "ENCRYPT=age : AGE_IDENTITY est vide (clé privée pour vérifier/restaurer)"
		errs=1
	fi
	case "${LOG_FILES}" in
	0|1) ;;
	*)
		_ERR "LOG_FILES doit valoir 0 ou 1 (reçu : ${LOG_FILES})"
		errs=1
		;;
	esac
	if [[ -z ${NAS} ]] || [[ -z ${BACKUP_SUBDIR} ]]; then
		_ERR "NAS et BACKUP_SUBDIR doivent être renseignés"
		errs=1
	fi
	return "${errs}"
}

# -----------------------------------------------------------------------------
# Réécriture des blocs de profils dans le fichier de configuration
# -----------------------------------------------------------------------------

# Échappe une valeur pour une affectation entre guillemets doubles.
_dq() {
	local v="${1}"
	v="${v//\\/\\\\}"
	v="${v//\"/\\\"}"
	v="${v//\$/\\\$}"
	v="${v//\`/\\\`}"
	printf '%s' "${v}"
}

# Contenu du bloc NAME (SOURCES, COMMANDS, EXCLUDES) trié par clé.
_config_block() {
	local name="${1}"
	local -n arr="${name}"
	local -a keys=()
	local k out=""
	if ((${#arr[@]} > 0)); then
		mapfile -t keys < <(printf '%s\n' "${!arr[@]}" | sort || true)
	fi
	out="${name}=("
	for k in "${keys[@]}"; do
		out+=$'\n\t'"[\"${k}\"]=\"$(_dq "${arr[${k}]}")\""
	done
	if ((${#keys[@]} > 0)); then
		out+=$'\n'
	fi
	out+=")"
	printf '%s\n' "${out}"
}

# Remplace, dans FILE, le contenu entre « # >>> NAME » et « # <<< NAME ».
_config_write_block() {
	local file="${1}" name="${2}" content="" tmp="" rc=0
	content="$(_config_block "${name}")" || return 1
	tmp="${file}.blk.$$"
	BLOCK_NAME="${name}" BLOCK_CONTENT="${content}" awk '
		BEGIN {
			name = ENVIRON["BLOCK_NAME"]
			content = ENVIRON["BLOCK_CONTENT"]
			inb = 0
			seen = 0
		}
		$0 == "# >>> " name { print; print content; inb = 1; seen = 1; next }
		$0 == "# <<< " name { inb = 0 }
		inb == 0 { print }
		END { if (seen == 0) exit 3 }
	' "${file}" >"${tmp}"
	rc=$?
	if ((rc != 0)); then
		rm -f -- "${tmp}"
		_ERR "bloc « ${name} » introuvable : le fichier doit contenir « # >>> ${name} » et « # <<< ${name} »"
		return 1
	fi
	if ! mv -f -- "${tmp}" "${file}"; then
		rm -f -- "${tmp}"
		return 1
	fi
	return 0
}

# Valide un fichier de configuration candidat en le faisant valider par le
# script lui-même (`config-check`), dans un processus séparé : aucun risque de
# pollution des tableaux courants, et exactement les mêmes règles.
_config_validate_file() {
	local f="${1}" self="${BASH_SOURCE[0]:-$0}" out=""
	[[ -f ${f} ]] || return 1
	if ! bash -n "${f}" 2>/dev/null; then
		_ERR "syntaxe invalide dans le fichier généré"
		return 1
	fi
	if ! out="$(bash "${self}" --config "${f}" config-check 2>&1)"; then
		_ERR "configuration refusée :"
		printf '%s\n' "${out}" >&2
		return 1
	fi
	return 0
}

# Écrit les tableaux en mémoire dans CFG_FILE, avec sauvegarde et contrôles.
_config_save() {
	local file="${CFG_FILE}" tmp="" bak="" block
	if [[ -z ${file} ]]; then
		_ERR "aucun fichier de configuration chargé"
		return 1
	fi
	tmp="${file}.tmp.$$"
	if ! cp -p -- "${file}" "${tmp}" 2>/dev/null; then
		_ERR "copie impossible vers ${tmp}"
		return 1
	fi
	for block in SOURCES COMMANDS EXCLUDES; do
		if ! _config_write_block "${tmp}" "${block}"; then
			rm -f -- "${tmp}"
			return 1
		fi
	done
	if ! bash -n "${tmp}" 2>/dev/null; then
		rm -f -- "${tmp}"
		_ERR "fichier de configuration généré invalide (syntaxe) — rien n'a été écrit"
		return 1
	fi
	if ! _config_validate_file "${tmp}"; then
		rm -f -- "${tmp}"
		_ERR "fichier de configuration généré invalide (contenu) — rien n'a été écrit"
		return 1
	fi
	bak="${file}.bak"
	cp -p -- "${file}" "${bak}" 2>/dev/null || _WARN "sauvegarde ${bak} impossible"
	if ! mv -f -- "${tmp}" "${file}"; then
		rm -f -- "${tmp}"
		_ERR "écriture impossible : ${file}"
		return 1
	fi
	_OK "configuration mise à jour : ${file}"
	_INFO "sauvegarde précédente : ${bak}"
	return 0
}

# =============================================================================
# TRAPS : nettoyage garanti, quelle que soit la sortie
# =============================================================================

_cleanup_parts() {
	if [[ -n "${PART_FILE}" ]] && [[ -e "${PART_FILE}" ]]; then
		rm -f -- "${PART_FILE}" 2>/dev/null
	fi
	PART_FILE=""
	return 0
}

_on_exit() {
	_cleanup_parts
	if [[ -n "${LOG_FILE}" ]] && [[ -s "${LOG_FILE}" ]] && ((INTERRUPTED == 0)); then
		if ((PORCELAIN == 1)); then
			printf '\n %bLog%b : %s\n' "${C_DIM}" "${C_RESET}" "${LOG_FILE}" >&2
		else
			printf '\n %bLog%b : %s\n' "${C_DIM}" "${C_RESET}" "${LOG_FILE}"
		fi
	fi
	return 0
}

_on_signal() {
	local sig="${1:-INT}" code=130
	[[ ${sig} == "TERM" ]] && code=143
	[[ ${sig} == "HUP" ]] && code=129
	INTERRUPTED=1
	printf '\n'
	_WARN "interrompu (SIG${sig})"
	if ((CHILD_PID > 0)); then
		kill -TERM "${CHILD_PID}" 2>/dev/null
		wait "${CHILD_PID}" 2>/dev/null
	fi
	if [[ -n "${PART_FILE}" ]] && [[ -e "${PART_FILE}" ]]; then
		_WARN "archive partielle supprimée : ${PART_FILE##*/}"
	fi
	_cleanup_parts
	exit "${code}"
}

# =============================================================================
# EXÉCUTION AVEC INDICATEUR DE PROGRESSION
# =============================================================================

_spin() {
	local pid="${1}" msg="${2}" i=0 total=0
	[[ -t 2 ]] || return 0
	total=${#SPIN_FRAMES[@]}
	while kill -0 "${pid}" 2>/dev/null; do
		printf '\r %b%s%b %s' "${C_RED}" "${SPIN_FRAMES[$((i % total))]}" "${C_RESET}" "${msg}" >&2
		sleep 0.1
		i=$((i + 1))
	done
	printf '\r\033[2K' >&2
	return 0
}

# _RUN "message" commande [arguments...]
# Lance la commande en arrière-plan (pour l'indicateur), journalise sa sortie,
# renvoie son code de retour. Ne quitte jamais : l'appelant décide.
_RUN() {
	local msg="${1:-}"
	shift || true
	if (($# == 0)); then
		_ERR "interne : _RUN sans commande"
		return 2
	fi

	local rc=0 target="/dev/null" t0="${SECONDS}"
	[[ -n "${LOG_FILE}" ]] && target="${LOG_FILE}"

	_log "RUN  ${msg}"
	_log "CMD  ${*}"

	"${@}" >>"${target}" 2>&1 9>&- &
	CHILD_PID=$!
	_spin "${CHILD_PID}" "${msg}"
	wait "${CHILD_PID}"
	rc=$?
	CHILD_PID=0
	_log "RC   ${rc} (durée $((SECONDS - t0)) s)"

	if ((rc == 0)); then
		_OK "${msg}"
	else
		_ERR "${msg} — code ${rc}"
	fi
	return "${rc}"
}

_show_log_tail() {
	[[ -n "${LOG_FILE}" ]] && [[ -s "${LOG_FILE}" ]] || return 0
	printf '\n%b--- 10 dernières lignes du log ---%b\n' "${C_DIM}" "${C_RESET}"
	tail -n 10 -- "${LOG_FILE}" 2>/dev/null
	printf '%b-----------------------------------%b\n' "${C_DIM}" "${C_RESET}"
	return 0
}

# =============================================================================
# NAS
# =============================================================================

_check_nas() {
	# Garde-fou : une configuration vide ne doit jamais produire NAS_MOUNT="/".
	if [[ -z ${NAS} ]] || [[ -z ${BACKUP_SUBDIR} ]]; then
		_ERR "configuration incomplète : NAS et BACKUP_SUBDIR doivent être renseignés"
		return 1
	fi
	if [[ ${NAS} != /* ]]; then
		_ERR "NAS doit être un chemin absolu (reçu : ${NAS})"
		return 1
	fi
	if ! _path_relative_ok "${BACKUP_SUBDIR}"; then
		_ERR "BACKUP_SUBDIR invalide : ${BACKUP_SUBDIR} (relatif, sans « .. »)"
		return 1
	fi
	NAS_MOUNT="${NAS%/}/${BACKUP_SUBDIR#/}"
	if [[ -z ${NAS_MOUNT} ]] || [[ ${NAS_MOUNT} == "/" ]]; then
		_ERR "chemin de stockage invalide (${NAS} + ${BACKUP_SUBDIR})"
		return 1
	fi

	if ! timeout "${NAS_TIMEOUT}" findmnt -rn -M "${NAS}" -o TARGET >/dev/null 2>&1; then
		_ERR "NAS non monté : ${NAS} n'est pas un point de montage"
		return 1
	fi
	return 0
}

# Variante pour les commandes qui écrivent sur le NAS.
_check_nas_rw() {
	_check_nas || return 1
	if ! mkdir -p -- "${NAS_MOUNT}" 2>/dev/null; then
		_ERR "impossible de créer ${NAS_MOUNT}"
		return 1
	fi
	if ! timeout "${NAS_TIMEOUT}" touch -- "${NAS_MOUNT}/.write-test.$$" 2>/dev/null; then
		_ERR "NAS non inscriptible (ou injoignable) : ${NAS_MOUNT}"
		return 1
	fi
	rm -f -- "${NAS_MOUNT}/.write-test.$$" 2>/dev/null
	return 0
}

_check_nas_perms() {
	[[ -d "${NAS_MOUNT}" ]] || return 0
	if [[ -O "${NAS_MOUNT}" ]]; then
		chmod 700 -- "${NAS_MOUNT}" 2>/dev/null || _WARN "chmod 700 impossible sur ${NAS_MOUNT}"
	else
		_WARN "${NAS_MOUNT} n'appartient pas à ${USER:-utilisateur courant} : permissions non modifiables (chiffrement conseillé)"
	fi
	return 0
}

_free_kb() {
	local kb
	kb="$(timeout "${NAS_TIMEOUT}" df -P --output=avail -- "${NAS_MOUNT}" 2>/dev/null | tail -n 1)" || kb=0
	[[ ${kb} =~ ^[0-9]+$ ]] || kb=0
	printf '%s' "${kb}"
}

# =============================================================================
# ARCHIVES : nommage, découverte, vérification
# =============================================================================

_enc_suffix() {
	case "${ENCRYPT}" in
	age) printf '%s' ".age" ;;
	*)   printf '%s' "" ;;
	esac
}

_archive_is_encrypted() {
	case "${1}" in
	*.age|*.age.part) return 0 ;;
	*) return 1 ;;
	esac
}

# Renseigne AGE_RECIPIENT à partir de AGE_IDENTITY si besoin : la clé publique
# est déduite de la clé privée (age-keygen -y, ou ssh-keygen -y pour une clé SSH).
_age_recipient() {
	[[ -n ${AGE_RECIPIENT} ]] && return 0
	local ident="${AGE_IDENTITY}" pub=""
	if [[ -z ${ident} ]]; then
		_ERR "AGE_IDENTITY est vide : impossible de déduire le destinataire"
		return 1
	fi
	if [[ ${ident} != /* ]]; then
		ident="${HOME}/${ident}"
	fi
	if pub="$(age-keygen -y "${ident}" 2>/dev/null)"; then
		AGE_RECIPIENT="${pub}"
		_log "destinataire déduit de ${ident} (clé age)"
		return 0
	fi
	if pub="$(ssh-keygen -y -P '' -f "${ident}" 2>/dev/null)"; then
		AGE_RECIPIENT="${pub}"
		_log "destinataire déduit de ${ident} (clé SSH)"
		return 0
	fi
	_ERR "impossible de déduire la clé publique de ${ident} — définis AGE_RECIPIENT"
	return 1
}

_encrypt() {
	case "${ENCRYPT}" in
	age) age --encrypt --recipient "${AGE_RECIPIENT}" ;;
	*)   cat ;;
	esac
}

_decrypt() {
	case "${1}" in
	*.age|*.age.part)
		local ident="${AGE_IDENTITY}"
		# Chemin absolu ou relatif à $HOME (comme les profils).
		if [[ ${ident} != /* ]]; then
			ident="${HOME}/${ident}"
		fi
		age --decrypt -i "${ident}" -- "${1}"
		;;
	*) cat -- "${1}" ;;
	esac
}

# Analyse un nom d'archive ; renseigne ARCH_PROFILE et ARCH_DATEKEY
# (AAAAMMJJHHMMSS). Reconnaît le format actuel et l'ancien (JJ_MM_AAAA).
_parse_archive() {
	local base="${1##*/}"
	ARCH_PROFILE=""
	ARCH_DATEKEY=""

	if [[ ${base} =~ ^(.+)_([0-9]{4})-([0-9]{2})-([0-9]{2})-([0-9]{2})\.([0-9]{2})\.([0-9]{2})\.tar\.gz(\.age)?$ ]]; then
		ARCH_PROFILE="${BASH_REMATCH[1]}"
		ARCH_DATEKEY="${BASH_REMATCH[2]}${BASH_REMATCH[3]}${BASH_REMATCH[4]}${BASH_REMATCH[5]}${BASH_REMATCH[6]}${BASH_REMATCH[7]}"
		return 0
	fi
	if [[ ${base} =~ ^(.+)_([0-9]{2})_([0-9]{2})_([0-9]{4})-([0-9]{2})\.([0-9]{2})\.([0-9]{2})\.tar\.gz(\.age)?$ ]]; then
		ARCH_PROFILE="${BASH_REMATCH[1]}"
		ARCH_DATEKEY="${BASH_REMATCH[4]}${BASH_REMATCH[3]}${BASH_REMATCH[2]}${BASH_REMATCH[5]}${BASH_REMATCH[6]}${BASH_REMATCH[7]}"
		return 0
	fi
	return 1
}

# Construit les tableaux ARCH_*, triés par groupe puis date décroissante.
# Groupe = « PROFIL » ou « pre-restore/PROFIL ».
_collect_archives() {
	ARCH_GROUP=()
	ARCH_DT=()
	ARCH_PATH=()
	ARCH_SIZE=()

	local dir rel f mtime size group dt
	local -a files=() rows=()

	for dir in "${NAS_MOUNT}" "${NAS_MOUNT}/${SNAPSHOT_SUBDIR}"; do
		[[ -d ${dir} ]] || continue
		rel=""
		[[ ${dir} == "${NAS_MOUNT}/${SNAPSHOT_SUBDIR}" ]] && rel="${SNAPSHOT_SUBDIR}/"

		files=()
		mapfile -t files < <(find "${dir}" -maxdepth 1 -type f \
			\( -name '*.tar.gz' -o -name '*.tar.gz.age' \) \
			-print 2>/dev/null || true)

		((${#files[@]} == 0)) && continue
		for f in "${files[@]}"; do
			_parse_archive "${f}" || continue
			mtime="$(stat -c %Y -- "${f}" 2>/dev/null)" || mtime=0
			[[ ${mtime} =~ ^[0-9]+$ ]] || mtime=0
			size="$(_file_size "${f}")"
			rows+=("${rel}${ARCH_PROFILE}"$'\t'"${ARCH_DATEKEY}"$'\t'"${mtime}"$'\t'"${size}"$'\t'"${f}")
		done
	done

	((${#rows[@]} == 0)) && return 0

	while IFS=$'\t' read -r group dt mtime size f; do
		[[ -n ${group} ]] || continue
		ARCH_GROUP+=("${group}")
		ARCH_DT+=("${dt}")
		ARCH_SIZE+=("${size}")
		ARCH_PATH+=("${f}")
	done < <(printf '%s\n' "${rows[@]}" | sort -t$'\t' -k1,1 -k2,2r -k3,3r || true)
	return 0
}

_latest_archive() {
	local group="${1}" i
	LATEST_PATH=""
	LATEST_DT=""
	LATEST_SIZE=0
	for i in "${!ARCH_GROUP[@]}"; do
		if [[ ${ARCH_GROUP[${i}]} == "${group}" ]]; then
			LATEST_PATH="${ARCH_PATH[${i}]}"
			LATEST_DT="${ARCH_DT[${i}]}"
			LATEST_SIZE="${ARCH_SIZE[${i}]}"
			return 0
		fi
	done
	return 1
}

# Comme `_latest_archive`, mais renvoie la première archive réellement valide
# (utilisé en secours quand la plus récente est corrompue).
_find_valid_archive() {
	local group="${1}" i
	for i in "${!ARCH_GROUP[@]}"; do
		if [[ ${ARCH_GROUP[${i}]} == "${group}" ]]; then
			if _verify_archive "${ARCH_PATH[${i}]}"; then
				LATEST_PATH="${ARCH_PATH[${i}]}"
				LATEST_DT="${ARCH_DT[${i}]}"
				LATEST_SIZE="${ARCH_SIZE[${i}]}"
				return 0
			fi
		fi
	done
	return 1
}

# Vérifie une archive : 0 = valide, 1 = corrompue/vide, 2 = indécidable
# (chiffrée et clé indisponible).
# 0 = valide, 1 = corrompue/vide, 2 = indécidable (clé indisponible).
# `with_list` = 1 journalise la liste des entrées (si LOG_FILES=1).
_verify_archive() {
	local f="${1}" with_list="${2:-0}" rc=0
	local listing=0
	[[ -f ${f} ]] || return 1
	[[ -s ${f} ]] || return 1
	if ((with_list == 1)) && ((LOG_FILES == 1)) && [[ -n ${LOG_FILE} ]]; then
		listing=1
	fi

	if _archive_is_encrypted "${f}"; then
		if ((listing == 1)); then
			_decrypt "${f}" 2>/dev/null | tar -tzvf - >>"${LOG_FILE}" 2>/dev/null
		else
			_decrypt "${f}" 2>/dev/null | tar -tzf - >/dev/null 2>&1
		fi
		rc=$?
		((rc == 0)) && return 0
		# Distinguer « clé absente » (indécidable) de « archive corrompue ».
		local err=""
		err="$(_decrypt "${f}" 2>&1 >/dev/null)" || true
		case "${err}" in
		*"no identity matched"*) return 2 ;;
		*) return 1 ;;
		esac
	fi

	if ((listing == 1)); then
		tar -tzvf "${f}" >>"${LOG_FILE}" 2>/dev/null
	else
		tar -tzf "${f}" >/dev/null 2>&1
	fi
	rc=$?
	((rc == 0)) && return 0
	return 1
}

# Liste les entrées d'une archive (chiffrée ou non).
_archive_list() {
	if _archive_is_encrypted "${1}"; then
		_decrypt "${1}" | tar -tz
	else
		tar -tzf "${1}"
	fi
}

# Écrit dans ${2} la racine de l'archive ${1} (chemin du profil sauvegardé).
# Échoue si l'archive contient plusieurs racines distinctes.
_archive_root_to() {
	local f="${1}" out="${2}" root="" line=""
	while IFS= read -r line; do
		line="${line#./}"
		if [[ -z ${root} ]]; then
			root="${line%/}"
			continue
		fi
		if [[ ${line%/} != "${root}" ]] && [[ ${line} != "${root}/"* ]]; then
			return 1
		fi
	done < <(_archive_list "${f}" 2>/dev/null || true)
	[[ -n ${root} ]] || return 1
	printf '%s' "${root}" >"${out}"
	return 0
}

_archive_root() {
	local f="${1}" tmp=""
	tmp="$(mktemp)" || return 1
	if ! _archive_root_to "${f}" "${tmp}" || [[ ! -s ${tmp} ]]; then
		rm -f -- "${tmp}"
		return 1
	fi
	cat -- "${tmp}"
	rm -f -- "${tmp}"
	return 0
}

# Deux profils se chevauchent-ils (même dossier, ou l'un contenu dans l'autre) ?
_source_overlap() {
	local p1="${1}" p2="${2}"
	[[ ${p1} == "${p2}" ]] && return 0
	[[ ${p1} == "${p2}/"* ]] && return 0
	[[ ${p2} == "${p1}/"* ]] && return 0
	return 1
}

# Avertit sur les profils dont les dossiers se chevauchent.
_config_conflicts() {
	local -a keys=()
	local i j
	mapfile -t keys < <(printf '%s\n' "${!SOURCES[@]}" | sort || true)
	((${#keys[@]} >= 2)) || return 0
	for ((i = 0; i < ${#keys[@]}; i++)); do
		for ((j = i + 1; j < ${#keys[@]}; j++)); do
			if _source_overlap "${SOURCES[${keys[i]}]}" "${SOURCES[${keys[j]}]}"; then
				_WARN "profils ${keys[i]} (${SOURCES[${keys[i]}]}) et ${keys[j]} (${SOURCES[${keys[j]}]}) : dossiers identiques ou imbriqués"
			fi
		done
	done
	return 0
}

_known_profile() {
	[[ -n "${SOURCES[${1}]:-}" ]]
}

_valid_profile_name() {
	[[ ${1} =~ ^[A-Z][A-Z0-9_]*$ ]]
}

# Chemin relatif sûr : ni absolu, ni option, ni composant « .. ».
_path_relative_ok() {
	local p="${1}" case_p=""
	[[ -n ${p} ]] || return 1
	[[ ${p} != /* ]] || return 1
	[[ ${p} != -* ]] || return 1
	[[ ${p} != *$'\n'* ]] || return 1
	[[ ${p} != *$'\r'* ]] || return 1
	case_p="/${p}/"
	[[ ${case_p} != *"/../"* ]] || return 1
	return 0
}

# Dossier source d'un profil : relatif à $HOME, pas « . » (tout le home).
_source_path_ok() {
	local p="${1}"
	_path_relative_ok "${p}" || return 1
	[[ ${p} != "." ]] || return 1
	return 0
}

# Contrôle de sécurité des chemins de la configuration.
_config_paths_check() {
	local k="" rc=0
	for k in "${!SOURCES[@]}"; do
		if ! _valid_profile_name "${k}"; then
			_ERR "nom de profil invalide : ${k}"
			rc=1
		fi
		if ! _source_path_ok "${SOURCES[${k}]}"; then
			_ERR "SOURCES[${k}] : dossier invalide (${SOURCES[${k}]}) — relatif à \$HOME, sans « .. »"
			rc=1
		fi
	done
	for k in "${!COMMANDS[@]}" "${!EXCLUDES[@]}"; do
		if ! _valid_profile_name "${k}"; then
			_ERR "nom de profil invalide dans COMMANDS/EXCLUDES : ${k}"
			rc=1
		fi
	done
	if [[ -n ${NAS} && ${NAS} != /* ]]; then
		_ERR "NAS invalide : ${NAS} — chemin absolu attendu"
		rc=1
	fi
	if ! _path_relative_ok "${BACKUP_SUBDIR}"; then
		_ERR "BACKUP_SUBDIR invalide : ${BACKUP_SUBDIR} — relatif, sans « .. »"
		rc=1
	fi
	return "${rc}"
}

# Refuse tout chemin hors du stockage (sécurité avant suppression/vérification).
_ensure_in_nas() {
	local f="${1}" real="" base=""
	real="$(readlink -f -- "${f}" 2>/dev/null)" || real="${f}"
	base="$(readlink -f -- "${NAS_MOUNT}" 2>/dev/null)" || base="${NAS_MOUNT}"
	if [[ ${real} != "${base}/"* ]]; then
		_ERR "chemin hors du stockage (${base}) : ${f}"
		return 1
	fi
	return 0
}

_fmt_datekey() {
	local dk="${1}"
	if [[ ${#dk} -ne 14 ]]; then
		printf '%s' "?"
		return 0
	fi
	printf '%s-%s-%s %s:%s:%s' "${dk:0:4}" "${dk:4:2}" "${dk:6:2}" "${dk:8:2}" "${dk:10:2}" "${dk:12:2}"
}

_group_label() {
	if [[ ${1} == "${SNAPSHOT_SUBDIR}/"* ]]; then
		printf '%s (instantané)' "${1#"${SNAPSHOT_SUBDIR}/"}"
	else
		printf '%s' "${1}"
	fi
}

_group_profile() {
	printf '%s' "${1#"${SNAPSHOT_SUBDIR}/"}"
}

# =============================================================================
# AFFICHAGE
# =============================================================================

_usage() {
	local g="${C_GREEN}" r="${C_RESET}" b="${C_BOLD}" d="${C_DIM}" c="${C_CYAN}" y="${C_YELLOW}"

	printf '\n%b%s%b %bv%s%b — %s\n' \
		"${b}" "${SCRIPTNAME}" "${r}" "${y}" "${VER}" "${r}" \
		"sauvegarde et restauration de données privées"

	printf '\n%bUsage%b : %s <commande> [options]\n' "${b}" "${r}" "${SCRIPTNAME}"

	printf '\n%bCommandes%b\n' "${b}" "${r}"
	printf '  %b%-20s%b %b%-30s%b %s\n' "${g}" "backup" "${r}" "${d}" "[PROFIL...]" "${r}" "sauvegarder un ou plusieurs profils"
	printf '  %b%-20s%b %b%-30s%b %s\n' "${g}" "restore" "${r}" "${d}" "[PROFIL]" "${r}" "restaurer l'archive la plus récente"
	printf '  %b%-20s%b %b%-30s%b %s\n' "${g}" "rollback" "${r}" "${d}" "[PROFIL]" "${r}" "revenir à l'instantané pré-restauration"
	printf '  %b%-20s%b %b%-30s%b %s\n' "${g}" "delete_old" "${r}" "${d}" "" "${r}" "appliquer la politique de rétention"
	printf '  %b%-20s%b %b%-30s%b %s\n' "${g}" "show" "${r}" "${d}" "" "${r}" "profils et dernière archive"
	printf '  %b%-20s%b %b%-30s%b %s\n' "${g}" "list" "${r}" "${d}" "[PROFIL]" "${r}" "lister les archives"
	printf '  %b%-20s%b %b%-30s%b %s\n' "${g}" "verify" "${r}" "${d}" "FICHIER" "${r}" "vérifier l'intégrité d'une archive"
	printf '  %b%-20s%b %b%-30s%b %s\n' "${g}" "delete-archive" "${r}" "${d}" "FICHIER..." "${r}" "supprimer des archives"
	printf '  %b%-20s%b %b%-30s%b %s\n' "${g}" "encrypt-archives" "${r}" "${d}" "[PROFIL...]" "${r}" "chiffrer les archives en clair (age)"
	printf '  %b%-20s%b %b%-30s%b %s\n' "${g}" "adopt-orphans" "${r}" "${d}" "[PROFIL...]" "${r}" "réintégrer les profils orphelins (dossier déduit)"
	printf '  %b%-20s%b %b%-30s%b %s\n' "${g}" "timer-add" "${r}" "${d}" "PROFIL quotidien HH:MM" "${r}" "planifier une sauvegarde (systemd --user)"
	printf '  %b%-20s%b %b%-30s%b %s\n' "${g}" "" "${r}" "${d}" "PROFIL hebdomadaire JOUR HH:MM" "${r}" "  (--extinction : retenter à l'extinction)"
	printf '  %b%-20s%b %b%-30s%b %s\n' "${g}" "timer-remove" "${r}" "${d}" "PROFIL" "${r}" "supprimer la planification d'un profil"
	printf '  %b%-20s%b %b%-30s%b %s\n' "${g}" "timer-list" "${r}" "${d}" "[--porcelain]" "${r}" "lister les sauvegardes automatiques"
	printf '  %b%-20s%b %b%-30s%b %s\n' "${g}" "timer-run" "${r}" "${d}" "PROFIL" "${r}" "lancer la sauvegarde planifiée maintenant"
	printf '  %b%-20s%b %b%-30s%b %s\n' "${g}" "timer-sync" "${r}" "${d}" "" "${r}" "régénérer le service des planifications"
	printf '  %b%-20s%b %b%-30s%b %s\n' "${g}" "timer-shutdown-enable" "${r}" "${d}" "" "${r}" "installer le service d'extinction (root)"
	printf '  %b%-20s%b %b%-30s%b %s\n' "${g}" "timer-shutdown-disable" "${r}" "${d}" "" "${r}" "retirer le service d'extinction (root)"
	printf '  %b%-20s%b %b%-30s%b %s\n' "${g}" "backup-pending" "${r}" "${d}" "[--shutdown]" "${r}" "sauvegarder les profils reportés"
	printf '  %b%-20s%b %b%-30s%b %s\n' "${g}" "timer-linger" "${r}" "${d}" "" "${r}" "autoriser les timers hors session (root)"
	printf '  %b%-20s%b %b%-30s%b %s\n' "${g}" "profile-add" "${r}" "${d}" "NOM DOSSIER [BINAIRE] [EXCL]" "${r}" "ajouter ou modifier un profil"
	printf '  %b%-20s%b %b%-30s%b %s\n' "${g}" "profile-remove" "${r}" "${d}" "NOM" "${r}" "retirer un profil"
	printf '  %b%-20s%b %b%-30s%b %s\n' "${g}" "config-set" "${r}" "${d}" "CLE=VALEUR..." "${r}" "modifier des paramètres"
	printf '  %b%-20s%b %b%-30s%b %s\n' "${g}" "config-path" "${r}" "${d}" "" "${r}" "chemin du fichier de configuration"
	printf '  %b%-20s%b %b%-30s%b %s\n' "${g}" "config-check" "${r}" "${d}" "" "${r}" "valider la configuration"
	printf '  %b%-20s%b %b%-30s%b %s\n' "${g}" "--delete-logs" "${r}" "${d}" "[--dry-run] [--yes]" "${r}" "supprimer les journaux"
	printf '  %b%-20s%b %b%-30s%b %s\n' "${g}" "help | --version" "${r}" "${d}" "" "${r}" "cette aide, version"

	printf '\n%bOptions%b\n' "${b}" "${r}"
	local opt desc
	while IFS='|' read -r opt desc; do
		[[ -n ${opt} ]] || continue
		printf '  %b%-16s%b %s\n' "${c}" "${opt}" "${r}" "${desc}"
	done <<OPTS
--dry-run|n'écrit et n'efface rien : affiche ce qui serait fait
--yes, -y|ne pas demander de confirmation
--no-verify|ne pas vérifier l'intégrité (backup, delete_old, encrypt-archives)
--keep N|archives conservées par profil (delete_old, défaut ${KEEP_DEFAULT})
--orphans|inclure les profils hors configuration dans la rétention (delete_old)
--purge-orphans|supprimer toutes les archives des profils hors configuration
--snapshot|forcer l'instantané avant restauration
--no-snapshot|interdire l'instantané avant restauration
--porcelain|sortie tabulée (interfaces) pour show, list et timer-list
--archive FILE|restaurer cette archive précise (avec restore)
--config FILE|utiliser ce fichier de configuration
--extinction|planifier : tenter la sauvegarde à l'extinction si l'application est ouverte
--no-extinction|planifier : désactiver ce mode
--plan FILE|écrire le plan d'adoption dans FILE (adopt-orphans)
--apply-plan FILE|appliquer ce plan sans réanalyser les archives
--delete-logs|supprimer les journaux (action seule, avec --dry-run/--yes)
OPTS

	local conf_affichee="${CFG_FILE}"
	if [[ -z ${conf_affichee} ]]; then
		conf_affichee="aucune (défaut : ${XDG_CONFIG_HOME:-${HOME}/.config}/${SCRIPTNAME}/config)"
	fi
	printf '\n'
	printf '%b%-13s%b : %s\n' "${c}" "Configuration" "${r}" "${conf_affichee}"
	printf '%b%-13s%b : %s\n' "${c}" "Stockage" "${r}" "${NAS_MOUNT:-${NAS}/${BACKUP_SUBDIR}}"
	printf '%b%-13s%b : %s\n' "${c}" "Secrets" "${r}" "archives et journaux 0600, dossiers 0700 (umask 077)"
	printf '%b%-13s%b : %s\n' "${c}" "Journaux" "${r}" "${HOME}/.local/share/${SCRIPTNAME}"
	printf '%b%-13s%b : %s\n' "${c}" "Interface" "${r}" "private-data_backup-tui.sh (interface texte, gum)"
	printf '\n'
	return 0
}

show() {
	_check_nas || return 1
	if ! [[ -d ${NAS_MOUNT} ]]; then
		_INFO "aucune archive (${NAS_MOUNT} absent)"
		return 0
	fi
	_collect_archives

	local -a profils=() orphelins=()
	local -A connus=() vu=()
	local profil cmd src i group total=0 orphan_total=0 snap_total=0 snap_count=0

	mapfile -t profils < <(printf '%s\n' "${!SOURCES[@]}" | sort || true)

	# Sortie tabulée stable, destinée aux interfaces (TUI, scripts) :
	# profil, dossier, binaire de contrôle, dernière archive, date, taille.
	if ((PORCELAIN == 1)); then
		local base=""
		for profil in "${profils[@]}"; do
			src="${SOURCES[${profil}]}"
			cmd="${COMMANDS[${profil}]:-}"
			if _latest_archive "${profil}"; then
				base="${LATEST_PATH##*/}"
				printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
					"${profil}" "${src}" "${cmd:--}" "${base}" \
					"${LATEST_DT}" "${LATEST_SIZE}" "${EXCLUDES[${profil}]:--}"
			else
				printf '%s\t%s\t%s\t-\t-\t0\t%s\n' \
					"${profil}" "${src}" "${cmd:--}" "${EXCLUDES[${profil}]:--}"
			fi
		done
		return 0
	fi

	for profil in "${profils[@]}"; do
		connus[${profil}]=1
	done

	# Profils présents sur le NAS mais absents de SOURCES (orphelins).
	for i in "${!ARCH_GROUP[@]}"; do
		group="${ARCH_GROUP[${i}]}"
		[[ ${group} == "${SNAPSHOT_SUBDIR}/"* ]] && continue
		[[ -n "${connus[${group}]:-}" ]] && continue
		[[ -n "${vu[${group}]:-}" ]] && continue
		vu[${group}]=1
		orphelins+=("${group}")
	done
	if ((${#orphelins[@]} > 0)); then
		mapfile -t orphelins < <(printf '%s\n' "${orphelins[@]}" | sort || true)
	fi

	local w_prof=6 w_src=20 w_cmd=12 w_arch=16
	local base=""
	for profil in "${profils[@]}" "${orphelins[@]}"; do
		((${#profil} > w_prof)) && w_prof=${#profil}
		if _latest_archive "${profil}"; then
			base="${LATEST_PATH##*/}"
			((${#base} > w_arch)) && w_arch=${#base}
		fi
	done
	for profil in "${profils[@]}"; do
		src="${SOURCES[${profil}]}"
		((${#src} > w_src)) && w_src=${#src}
		cmd="${COMMANDS[${profil}]:-}"
		((${#cmd} > w_cmd)) && w_cmd=${#cmd}
	done

	local d_prof d_src d_cmd d_arch d_size
	d_prof="$(_dashes "${w_prof}")"
	d_src="$(_dashes "${w_src}")"
	d_cmd="$(_dashes "${w_cmd}")"
	d_arch="$(_dashes "${w_arch}")"
	d_size="$(_dashes 10)"

	# Cellule « dossier » des profils orphelins : texte + remplissage calculé
	# à la main (les séquences de couleur fausseraient %-*s).
	local hors_cfg="(hors configuration)"
	local hors_pad=""
	((w_src > ${#hors_cfg})) && hors_pad="$(printf '%*s' "$((w_src - ${#hors_cfg}))" '')"

	printf '\n%bProfils%b %b(config : %s)%b\n' \
		"${C_BOLD}" "${C_RESET}" "${C_DIM}" "${CFG_FILE:-valeurs par défaut}" "${C_RESET}"
	_pad "Profil" "${w_prof}"
	printf '  '
	_pad "Dossier" "${w_src}"
	printf '  '
	_pad "Contrôle" "${w_cmd}"
	printf '  '
	_pad "Dernière archive" "${w_arch}"
	printf '  %s\n' "Taille"
	printf '%s  %s  %s  %s  %s\n' "${d_prof}" "${d_src}" "${d_cmd}" "${d_arch}" "${d_size}"

	local when size_h
	for profil in "${profils[@]}"; do
		if _latest_archive "${profil}"; then
			when="${LATEST_PATH##*/}"
			size_h="$(_human_size "${LATEST_SIZE}")"
			_pad "${profil}" "${w_prof}"
			printf '  '
			_pad "${SOURCES[${profil}]}" "${w_src}"
			printf '  '
			_pad "${COMMANDS[${profil}]:-}" "${w_cmd}"
			printf '  '
			_pad "${when}" "${w_arch}"
			printf '  %s\n' "${size_h}"
		else
			_pad "${profil}" "${w_prof}"
			printf '  '
			_pad "${SOURCES[${profil}]}" "${w_src}"
			printf '  '
			_pad "${COMMANDS[${profil}]:-}" "${w_cmd}"
			printf '  %b(aucune)%b\n' "${C_RED}" "${C_RESET}"
		fi
	done

	# Orphelins : mêmes colonnes, dossier = « (hors configuration) ».
	for profil in "${orphelins[@]}"; do
		if ! _latest_archive "${profil}"; then
			continue
		fi
		when="${LATEST_PATH##*/}"
		size_h="$(_human_size "${LATEST_SIZE}")"
		_pad "${profil}" "${w_prof}"
		printf '  %b%s%b%s  ' \
			"${C_YELLOW}" "${hors_cfg}" "${C_RESET}" "${hors_pad}"
		_pad "" "${w_cmd}"
		printf '  '
		_pad "${when}" "${w_arch}"
		printf '  %s\n' "${size_h}"
	done

	for i in "${!ARCH_GROUP[@]}"; do
		group="${ARCH_GROUP[${i}]}"
		total=$((total + ARCH_SIZE[i]))
		if [[ ${group} == "${SNAPSHOT_SUBDIR}/"* ]]; then
			snap_total=$((snap_total + ARCH_SIZE[i]))
			snap_count=$((snap_count + 1))
			continue
		fi
		profil="$(_group_profile "${group}")"
		if [[ -z "${connus[${profil}]:-}" ]]; then
			orphan_total=$((orphan_total + ARCH_SIZE[i]))
		fi
	done

	local total_h orphan_h
	total_h="$(_human_size "${total}")"
	local na=${#ARCH_PATH[@]} ca=""
	ca="$(_count "${na}" archive archives)"
	printf '\n%bContenu de %s%b : %s, %s' \
		"${C_BOLD}" "${NAS_MOUNT}" "${C_RESET}" "${ca}" "${total_h}"
	if ((${#orphelins[@]} > 0)); then
		orphan_h="$(_human_size "${orphan_total}")"
		printf ' dont %s de profils hors configuration' "${orphan_h}"
	fi
	printf '\n'

	if ((${#orphelins[@]} > 0)); then
		printf ' %b(hors configuration) = archives d'"'"'un profil qui n'"'"'est plus déclaré dans la config%b\n' \
			"${C_DIM}" "${C_RESET}"
		printf ' %bdu script ; conservées en l'"'"'état (« delete_old --purge-orphans » pour les supprimer).%b\n' \
			"${C_DIM}" "${C_RESET}"
	fi

	local snap_h
	snap_h="$(_human_size "${snap_total}")"
	local cs=""
	cs="$(_count "${snap_count}" fichier fichiers)"
	printf ' Instantanés avant restauration : %s, %s\n\n' "${cs}" "${snap_h}"
	return 0
}

list() {
	local filter="${1:-}"
	_check_nas || return 1
	if ! [[ -d ${NAS_MOUNT} ]]; then
		_INFO "aucune archive (${NAS_MOUNT} absent)"
		return 0
	fi
	_collect_archives

	# Sortie tabulée stable : groupe, date, taille, chemin.
	if ((PORCELAIN == 1)); then
		local i
		for i in "${!ARCH_PATH[@]}"; do
			printf '%s\t%s\t%s\t%s\n' \
				"${ARCH_GROUP[${i}]}" "${ARCH_DT[${i}]}" "${ARCH_SIZE[${i}]}" "${ARCH_PATH[${i}]}"
		done
		return 0
	fi

	if ((${#ARCH_PATH[@]} == 0)); then
		_INFO "aucune archive dans ${NAS_MOUNT}"
		return 0
	fi

	filter="${filter^^}"
	local d_prof d_when d_size d_file d_enc
	d_prof="$(_dashes 26)"
	d_when="$(_dashes 19)"
	d_size="$(_dashes 10)"
	d_file="$(_dashes 10)"
	d_enc="$(_dashes 6)"

	# La première colonne marque les profils hors configuration d'une « * ».
	printf '\n  %-26s  %-19s  %10s  %-6s  %s\n' "Profil" "Date" "Taille" "Chiffr." "Fichier"
	printf '  %s  %s  %s  %s  %s\n' "${d_prof}" "${d_when}" "${d_size}" "${d_enc}" "${d_file}"

	local i group label when size_h profil_group enc skipped=0 orphans=0 mark=""
	for i in "${!ARCH_PATH[@]}"; do
		group="${ARCH_GROUP[${i}]}"
		profil_group="$(_group_profile "${group}")"
		if [[ -n ${filter} ]] && [[ ${profil_group} != "${filter}" ]]; then
			skipped=$((skipped + 1))
			continue
		fi
		label="$(_group_label "${group}")"
		when="$(_fmt_datekey "${ARCH_DT[${i}]}")"
		size_h="$(_human_size "${ARCH_SIZE[${i}]}")"
		if _known_profile "${profil_group}"; then
			mark=" "
		else
			mark="*"
			orphans=$((orphans + 1))
		fi
		case "${ARCH_PATH[${i}]}" in
		*.age) enc="age" ;;
		*) enc="-" ;;
		esac
		printf '%s %-26s  %-19s  %10s  %-6s  %s\n' \
			"${mark}" "${label}" "${when}" "${size_h}" "${enc}" "${ARCH_PATH[${i}]##*/}"
	done
	printf '\n'
	if ((orphans > 0)); then
		printf ' %b* = profil hors configuration (absent de SOURCES) ; conservé, à purger avec%b\n' \
			"${C_DIM}" "${C_RESET}"
		printf ' %b    « delete_old --purge-orphans » (avec confirmation).%b\n' \
			"${C_DIM}" "${C_RESET}"
	fi
	if ((skipped > 0)); then
		local cs=""
		cs="$(_count "${skipped}" "archive masquée" "archives masquées")"
		_INFO "${cs} par le filtre"
	fi
	return 0
}

# =============================================================================
# BACKUP
# =============================================================================

# Écrit l'archive d'un profil dans `${out}` (fichier .part : atomicité).
_backup_tar() {
	local profil="${1}" src="${2}" out="${3}" rc=0 pat
	local -a opts=()

	if [[ -n "${EXCLUDES[${profil}]:-}" ]]; then
		local IFS='|'
		for pat in ${EXCLUDES[${profil}]}; do
			opts+=(--exclude="${pat}" --exclude="*/${pat}")
		done
		unset IFS
	fi

	local opts_str="" flag_disp="-czf"
	if ((${#opts[@]} > 0)); then
		opts_str="${opts[*]} "
	fi
	# -v journalise la liste des fichiers ajoutés (LOG_FILES=1). L'option est
	# passée séparément : « -czfv » ferait de « v » le nom de l'archive.
	local -a taropts=(-c -z)
	if ((LOG_FILES == 1)); then
		taropts+=(-v)
		flag_disp="-czvf"
	fi
	if [[ -n "${ENCRYPT}" ]]; then
		_log "tar ${flag_disp} - ${opts_str}-C ${HOME} ${src} | ${ENCRYPT} > ${out}"
		tar "${taropts[@]}" -f - "${opts[@]}" -C "${HOME}" "${src}" | _encrypt >"${out}"
		rc=$?
	else
		_log "tar ${flag_disp} ${out} ${opts_str}-C ${HOME} ${src}"
		tar "${taropts[@]}" -f "${out}" "${opts[@]}" -C "${HOME}" "${src}"
		rc=$?
	fi
	if ((LOG_FILES == 1)); then
		_log "--- fin de la liste des fichiers ---"
	fi

	# tar : 0 = OK, 1 = « fichier modifié pendant la lecture » (archive
	# utilisable), >= 2 = échec réel. Avec chiffrement, pipefail renvoie le code
	# du dernier maillon en échec : un age en échec (2) l'emporte donc.
	if ((rc == 1)); then
		_log "avertissement tar : des fichiers ont été modifiés pendant la lecture (archive conservée)"
		return 0
	fi
	((rc == 0)) && return 0
	return "${rc}"
}

_backup_one() {
	local profil="${1}" explicit="${2:-0}"
	local src cmd abs target part enc size_h bytes
	if ! _valid_profile_name "${profil}"; then
		_ERR "nom de profil invalide : ${profil} — refuse par sécurité"
		return 1
	fi
	src="${SOURCES[${profil}]}"
	if ! _source_path_ok "${src}"; then
		_ERR "${profil} : dossier source invalide (${src:-absent}) — refuse par sécurité"
		return 1
	fi
	abs="${HOME}/${src}"

	if ! [[ -e ${abs} ]]; then
		if ((explicit == 1)); then
			_ERR "${profil} : source absente (~/${src}) — échec"
			return 1
		fi
		_WARN "${profil} : source absente (~/${src}) — profil ignoré"
		return 3
	fi

	cmd="${COMMANDS[${profil}]:-}"
	if [[ -n ${cmd} ]] && pgrep -x -- "${cmd}" >/dev/null 2>&1; then
		_WARN "${profil} : ${cmd} est en cours d'exécution — ferme-le puis relance"
		_pending_add "${profil}" "${cmd} est en cours d'exécution"
		return 3
	fi

	enc="$(_enc_suffix)"
	target="${NAS_MOUNT}/${profil}_${RUN_DATE}.tar.gz${enc}"
	part="${target}.part"

	_log "profil ${profil} : source=${abs}"
	_log "profil ${profil} : exclusions=${EXCLUDES[${profil}]:-aucune}"
	_log "profil ${profil} : cible=${target}"

	if ((DRY_RUN == 1)); then
		bytes="$(du -sb -- "${abs}" 2>/dev/null | cut -f1)" || bytes=0
		[[ ${bytes} =~ ^[0-9]+$ ]] || bytes=0
		size_h="$(_human_size "${bytes}")"
		_INFO "${profil} : serait écrit dans ${target##*/} (~${size_h} de source)"
		return 0
	fi

	PART_FILE="${part}"
	if ! _RUN "Sauvegarde de ${profil} (~/${src})" _backup_tar "${profil}" "${src}" "${part}"; then
		_show_log_tail
		_cleanup_parts
		return 1
	fi

	chmod 600 -- "${part}" 2>/dev/null || _WARN "${profil} : chmod 600 impossible sur l'archive"

	if ((VERIFY == 1)); then
		local vrc=0
		_RUN "Vérification de ${part##*/}" _verify_archive "${part}"
		vrc=$?
		case "${vrc}" in
		0) _log "profil ${profil} : vérification OK" ;;
		2) _WARN "${profil} : archive chiffrée non vérifiable (clé indisponible)" ;;
		*)
			_cleanup_parts
			_ERR "${profil} : archive corrompue après écriture — rejetée et supprimée"
			return 1
			;;
		esac
	fi

	if ! mv -f -- "${part}" "${target}"; then
		_ERR "${profil} : renommage final impossible (${target##*/})"
		_cleanup_parts
		return 1
	fi
	PART_FILE=""

	bytes="$(_file_size "${target}")"
	size_h="$(_human_size "${bytes}")"
	_log "profil ${profil} : terminé, ${bytes} octets (${size_h})"
	_pending_clear "${profil}"
	_INFO "${profil} : ${target##*/} (${size_h})"
	return 0
}

backup() {
	local -a wanted=("${@}")
	local -a profils=()
	local profil p explicit rc_one rc=0 skipped=0 done_count=0

	_check_nas_rw || return 1
	_check_nas_perms
	_cleanup_stale_parts
	_collect_archives

	if ((${#wanted[@]} > 0)); then
		for p in "${wanted[@]}"; do
			p="${p^^}"
			if ! _known_profile "${p}"; then
				_ERR "profil inconnu : ${p} (voir « show »)"
				rc=2
				continue
			fi
			profils+=("${p}")
		done
		((rc == 2)) && return 2
	else
		mapfile -t profils < <(printf '%s\n' "${!SOURCES[@]}" | sort || true)
	fi

	# Déduplication (un profil demandé deux fois ne doit pas être sauvegardé
	# deux fois dans la même archive nommée).
	local -A vu=()
	local -a uniq=()
	for p in "${profils[@]}"; do
		[[ -n "${vu[${p}]:-}" ]] && continue
		vu[${p}]=1
		uniq+=("${p}")
	done
	if ((${#uniq[@]} > 0)); then
		profils=("${uniq[@]}")
	fi

	# Espace libre, estimé d'après la dernière archive de chaque profil.
	local need_kb=0 free_kb size_kb need_h free_h
	for profil in "${profils[@]}"; do
		if _latest_archive "${profil}"; then
			size_kb=$((LATEST_SIZE / 1024))
			need_kb=$((need_kb + size_kb + size_kb / 5))
		fi
	done
	need_kb=$((need_kb + 262144))
	free_kb="$(_free_kb)"
	if ((free_kb > 0)) && ((free_kb < need_kb)); then
		need_h="$(_human_size $((need_kb * 1024)))"
		free_h="$(_human_size $((free_kb * 1024)))"
		_ERR "espace insuffisant sur le NAS : ${free_h} libres, ~${need_h} estimés"
		return 1
	fi

	local now
	now="$(date '+%d/%m/%Y %H:%M:%S')" || now="?"
	printf '\n%bSauvegarde du %s%b → %s\n' "${C_BOLD}" "${now}" "${C_RESET}" "${NAS_MOUNT}"

	for profil in "${profils[@]}"; do
		explicit=0
		if ((${#wanted[@]} > 0)); then
			for p in "${wanted[@]}"; do
				[[ ${p^^} == "${profil}" ]] && explicit=1
			done
		fi
		_backup_one "${profil}" "${explicit}"
		rc_one=$?
		case "${rc_one}" in
		0) done_count=$((done_count + 1)) ;;
		3)
			if ((STRICT_SKIP == 1)); then
				# Planifié : une sauvegarde non faite doit être visible.
				rc=1
				FAILURES=$((FAILURES + 1))
			else
				skipped=$((skipped + 1))
			fi
			;;
		*)
			rc=1
			FAILURES=$((FAILURES + 1))
			;;
		esac
	done


	local c_done="" c_skip=""
	if ((DRY_RUN == 1)); then
		c_done="$(_count "${done_count}" "sauvegarde prévue" "sauvegardes prévues")"
		c_skip="$(_count "${skipped}" ignoré ignorés)"
		printf '\n%bBilan (dry-run)%b : %s, %s, %d en échec\n' \
			"${C_BOLD}" "${C_RESET}" "${c_done}" "${c_skip}" "${FAILURES}"
		return "${rc}"
	fi

	c_done="$(_count "${done_count}" sauvegardée sauvegardées)"
	c_skip="$(_count "${skipped}" ignorée ignorées)"
	printf '\n%bBilan%b : %s, %s, %d en échec\n' \
		"${C_BOLD}" "${C_RESET}" "${c_done}" "${c_skip}" "${FAILURES}"
	if ((FAILURES > 0)); then
		_show_log_tail
		return 1
	fi
	return "${rc}"
}

# =============================================================================
# RESTORE
# =============================================================================

_is_tty() {
	[[ -t 0 ]]
}

_confirm() {
	local question="${1}" answer=""
	if ((ASSUME_YES == 1)); then
		return 0
	fi
	if ! _is_tty; then
		_ERR "confirmation impossible (entrée standard non interactive) — utilise --yes"
		return 1
	fi
	printf ' %b?%b %s [o/N] ' "${C_CYAN}" "${C_RESET}" "${question}"
	if ! read -r answer; then
		printf '\n'
		return 1
	fi
	case "${answer}" in
	o|O|oui|Oui|OUI|y|Y|yes|Yes|YES) return 0 ;;
	*) return 1 ;;
	esac
}

_dir_size_mb() {
	local mb
	mb="$(du -sm -- "${1}" 2>/dev/null | cut -f1)" || mb=0
	[[ ${mb} =~ ^[0-9]+$ ]] || mb=0
	printf '%s' "${mb}"
}

_snapshot_path() {
	local enc=""
	enc="$(_enc_suffix)"
	printf '%s/%s/%s_%s.tar.gz%s' \
		"${NAS_MOUNT}" "${SNAPSHOT_SUBDIR}" "${1}" "${RUN_DATE}" "${enc}"
}

# Instantané de l'état courant avant écrasement. 0 = fait ou inutile.
_snapshot_before_restore() {
	local profil="${1}"
	local src="${SOURCES[${profil}]}"
	local abs="${HOME}/${src}"
	local dir size_mb target rc=0

	[[ -e ${abs} ]] || return 0

	case "${SNAPSHOT_MODE}" in
	no)
		_log "instantané ${profil} : ignoré (--no-snapshot)"
		_WARN "pas d'instantané (--no-snapshot) : l'état actuel de ~/${src} sera perdu"
		return 0
		;;
	auto)
		size_mb="$(_dir_size_mb "${abs}")"
		if ((size_mb > SNAPSHOT_MAX_MB)); then
			_log "instantané ${profil} : ignoré (${size_mb} Mo > ${SNAPSHOT_MAX_MB} Mo)"
			_WARN "instantané ignoré : ~/${src} fait ${size_mb} Mo (> ${SNAPSHOT_MAX_MB} Mo) — utilise --snapshot pour forcer"
			return 0
		fi
		_log "instantané ${profil} : mode auto, ${size_mb} Mo <= ${SNAPSHOT_MAX_MB} Mo"
		;;
	*) ;;
	esac

	dir="${NAS_MOUNT}/${SNAPSHOT_SUBDIR}"
	if ! mkdir -p -- "${dir}" 2>/dev/null; then
		_ERR "impossible de créer ${dir}"
		return 1
	fi
	[[ -O ${dir} ]] && chmod 700 -- "${dir}" 2>/dev/null
	target="$(_snapshot_path "${profil}")"

	# Même moteur que les archives : exclusions du profil et chiffrement
	# éventuel sont appliqués, et l'écriture reste atomique (.part + mv).
	PART_FILE="${target}.part"
	if ! _RUN "Instantané de ~/${src} (exclusions appliquées)" \
		_backup_tar "${profil}" "${src}" "${target}.part"; then
		_cleanup_parts
		_ERR "instantané impossible — restauration annulée"
		return 1
	fi
	chmod 600 -- "${target}.part" 2>/dev/null
	PART_FILE=""
	if ! mv -f -- "${target}.part" "${target}"; then
		_cleanup_parts
		_ERR "renommage de l'instantané impossible"
		return 1
	fi

	if ((VERIFY == 1)); then
		_RUN "Vérification de l'instantané ${target##*/}" _verify_archive "${target}"
		rc=$?
		case "${rc}" in
		0) ;;
		2) _WARN "instantané chiffré non vérifiable (clé indisponible)" ;;
		*)
			rm -f -- "${target}" 2>/dev/null
			_ERR "instantané corrompu — restauration annulée"
			return 1
			;;
		esac
	fi

	local snap_bytes=0 snap_size=""
	snap_bytes="$(_file_size "${target}")"
	snap_size="$(_human_size "${snap_bytes}")"
	_log "instantané ${profil} : ${target} (${snap_size})"
	_OK "instantané : ${SNAPSHOT_SUBDIR}/${target##*/}"
	return 0
}

_restore_extract() {
	local file="${1}" dest="${2}" suffix="${3}" rc=0
	local -a opts=(--extract --gzip --directory "${dest}" --no-same-owner --backup --suffix="${suffix}")

	local -a vopts=()
	if ((LOG_FILES == 1)); then
		vopts=(--verbose)
	fi
	if _archive_is_encrypted "${file}"; then
		_log "decrypt ${file} | tar ${opts[*]} ${vopts[*]:-} --file -"
		_decrypt "${file}" | tar "${opts[@]}" "${vopts[@]}" --file -
		rc=$?
	else
		_log "tar ${opts[*]} ${vopts[*]:-} --file ${file}"
		tar "${opts[@]}" "${vopts[@]}" --file "${file}"
		rc=$?
	fi
	if ((LOG_FILES == 1)); then
		_log "--- fin de la liste des fichiers extraits ---"
	fi
	if ((rc == 1)); then
		_log "avertissement tar : des fichiers ont été modifiés pendant l'extraction"
		return 0
	fi
	return "${rc}"
}

# _pick_archive GROUPE PROFIL [libellé] : archive la plus récente du groupe,
# vérifiée, avec repli sur la précédente valide. Renseigne RESTORE_FILE.
RESTORE_FILE=""
_pick_archive() {
	local group="${1}" profil="${2}" label="${3:-Restauration}" rc=0

	RESTORE_FILE=""
	if ! _latest_archive "${group}"; then
		_ERR "${label} : aucune archive pour ${profil}"
		return 1
	fi
	RESTORE_FILE="${LATEST_PATH}"

	_RUN "Vérification de ${RESTORE_FILE##*/}" _verify_archive "${RESTORE_FILE}"
	rc=$?
	if ((rc == 1)); then
		_WARN "${profil} : ${RESTORE_FILE##*/} est corrompue — recherche d'une archive antérieure valide"
		if ! _find_valid_archive "${group}"; then
			_ERR "${profil} : aucune archive valide — opération refusée"
			return 1
		fi
		RESTORE_FILE="${LATEST_PATH}"
		_INFO "reprise sur ${RESTORE_FILE##*/}"
	elif ((rc == 2)); then
		_WARN "${profil} : archive non vérifiable (clé indisponible) — poursuite"
	fi
	return 0
}

# _restore_file FICHIER PROFIL [instantané 0|1] [libellé] [déjà vérifiée 0|1]
_restore_file() {
	local file="${1}" profil="${2}" with_snapshot="${3:-1}" label="${4:-Restauration}" verified="${5:-0}"
	local suffix="" when="" size_h="" rc=0

	if ! _valid_profile_name "${profil}"; then
		_ERR "nom de profil invalide : ${profil} — restauration refusée"
		return 1
	fi
	if ! _source_path_ok "${SOURCES[${profil}]:-}"; then
		_ERR "${profil} : dossier source invalide — restauration refusée"
		return 1
	fi
	[[ -f ${file} ]] || {
		_ERR "archive absente : ${file}"
		return 1
	}
	if ! _parse_archive "${file}"; then
		_ERR "nom d'archive non reconnu : ${file##*/}"
		return 1
	fi
	when="$(_fmt_datekey "${ARCH_DATEKEY}")"
	local bytes=0
	bytes="$(_file_size "${file}")"
	size_h="$(_human_size "${bytes}")"
	_log "${label} ${profil} : archive=${file} (${when}, ${size_h})"
	printf '\n%b%s%b %s ← %s (%s, %s)\n' \
		"${C_BOLD}" "${label}" "${C_RESET}" "${profil}" "${file##*/}" "${when}" "${size_h}"

	if ((verified == 0)); then
		_RUN "Vérification de ${file##*/}" _verify_archive "${file}"
		rc=$?
		_log "${label} ${profil} : vérification rc=${rc}"
		if ((rc == 1)); then
			_ERR "${profil} : ${file##*/} est corrompue — opération refusée"
			return 1
		elif ((rc == 2)); then
			_WARN "${profil} : archive non vérifiable (clé indisponible) — poursuite"
		fi
	fi

	if ((DRY_RUN == 1)); then
		_INFO "${profil} : --dry-run, rien n'a été extrait"
		return 0
	fi

	if ! _confirm "${label} : écraser ~/${SOURCES[${profil}]} avec ${file##*/} ?"; then
		_INFO "${profil} : annulé"
		return 3
	fi

	if ((with_snapshot == 1)); then
		if ! _snapshot_before_restore "${profil}"; then
			return 1
		fi
	fi

	suffix=".pre-restore-${RUN_DATE}"
	_log "${label} ${profil} : extraction vers ${HOME} (sauvegardes *.pre-restore-${RUN_DATE})"
	if ! _RUN "${label} de ${profil} (${file##*/})" _restore_extract "${file}" "${HOME}" "${suffix}"; then
		_show_log_tail
		_ERR "${profil} : restauration en échec (les fichiers déjà extraits sont conservés)"
		return 1
	fi
	return 0
}

# Cœur de `restore` / `rollback` : groupe « PROFIL » ou « pre-restore/PROFIL ».
_restore_from() {
	local group="${1}" profil="${2}" with_snapshot="${3:-1}" label="${4:-Restauration}"
	if ! _pick_archive "${group}" "${profil}" "${label}"; then
		return 1
	fi
	_restore_file "${RESTORE_FILE}" "${profil}" "${with_snapshot}" "${label}" 1
}

_restore_one() {
	local profil="${1^^}" cmd
	if ! _known_profile "${profil}"; then
		_ERR "profil inconnu : ${profil} (voir « show »)"
		return 2
	fi
	cmd="${COMMANDS[${profil}]:-}"
	if [[ -n ${cmd} ]] && pgrep -x -- "${cmd}" >/dev/null 2>&1; then
		_ERR "${profil} : ferme ${cmd} d'abord"
		return 1
	fi
	_restore_from "${profil}" "${profil}" 1 "Restauration"
}

_rollback_one() {
	local profil="${1^^}" cmd
	if ! _known_profile "${profil}"; then
		_ERR "profil inconnu : ${profil} (voir « show »)"
		return 2
	fi
	cmd="${COMMANDS[${profil}]:-}"
	if [[ -n ${cmd} ]] && pgrep -x -- "${cmd}" >/dev/null 2>&1; then
		_ERR "${profil} : ferme ${cmd} d'abord"
		return 1
	fi
	_restore_from "${SNAPSHOT_SUBDIR}/${profil}" "${profil}" 0 "Retour arrière"
}

restore() {
	local target="${1:-}" rc=0
	_check_nas_rw || return 1
	_check_nas_perms
	_collect_archives

	# Restauration d'une archive précise (choisie dans `list`).
	if [[ -n ${ARCHIVE_FILE} ]]; then
		_ensure_in_nas "${ARCHIVE_FILE}" || return 1
		if ! _parse_archive "${ARCHIVE_FILE}"; then
			_ERR "nom d'archive non reconnu : ${ARCHIVE_FILE##*/}"
			return 2
		fi
		local profil_archive="${ARCH_PROFILE^^}"
		if ! _known_profile "${profil_archive}"; then
			_ERR "archive d'un profil inconnu : ${profil_archive} (voir « show »)"
			return 2
		fi
		local cmd_archive="${COMMANDS[${profil_archive}]:-}"
		if [[ -n ${cmd_archive} ]] && pgrep -x -- "${cmd_archive}" >/dev/null 2>&1; then
			_ERR "${profil_archive} : ferme ${cmd_archive} d'abord"
			return 1
		fi
		_restore_file "${ARCHIVE_FILE}" "${profil_archive}" 1 "Restauration"
		return "${?}"
	fi

	if [[ -n ${target} ]]; then
		_restore_one "${target}"
		return "${?}"
	fi

	if ! _is_tty; then
		_ERR "aucun profil fourni et entrée standard non interactive — usage : restore PROFIL"
		return 2
	fi

	local -a profils=()
	mapfile -t profils < <(printf '%s\n' "${!SOURCES[@]}" | sort || true)

	printf '\n%bChoisissez un profil à restaurer :%b\n\n' "${C_CYAN}" "${C_RESET}"
	local -i i=1
	local profil when size_h
	for profil in "${profils[@]}"; do
		if _latest_archive "${profil}"; then
			when="$(_fmt_datekey "${LATEST_DT}")"
			size_h="$(_human_size "${LATEST_SIZE}")"
			printf '  %b%2d)%b %-14s %s  %s\n' \
				"${C_GREEN}" "${i}" "${C_RESET}" "${profil}" "${when}" "${size_h}"
		else
			printf '  %b%2d)%b %-14s %b(aucune archive)%b\n' \
				"${C_GREEN}" "${i}" "${C_RESET}" "${profil}" "${C_RED}" "${C_RESET}"
		fi
		i=$((i + 1))
	done
	local all_idx=${i}
	printf '  %b%2d)%b TOUS\n' "${C_GREEN}" "${i}" "${C_RESET}"
	i=$((i + 1))
	local cancel_idx=${i}
	printf '  %b%2d)%b Annuler\n' "${C_GREEN}" "${i}" "${C_RESET}"

	local choice=""
	printf '\n%b#?%b ' "${C_CYAN}" "${C_RESET}"
	if ! read -r choice; then
		printf '\n'
		_ERR "aucune saisie — abandon"
		return 2
	fi
	if [[ ! ${choice} =~ ^[0-9]+$ ]] || ((choice < 1 || choice > cancel_idx)); then
		_ERR "choix invalide"
		return 2
	fi
	if ((choice == cancel_idx)); then
		_INFO "annulé"
		return 0
	fi
	if ((choice == all_idx)); then
		local liste=""
		liste="$(printf '%s, ' "${profils[@]}")"
		if ! _confirm "Restaurer TOUS les profils (${liste%, }) ?"; then
			_INFO "annulé"
			return 0
		fi
		for profil in "${profils[@]}"; do
			_restore_one "${profil}"
			rc=$?
			((rc == 1)) && FAILURES=$((FAILURES + 1))
		done
		((FAILURES > 0)) && return 1
		return 0
	fi

	_restore_one "${profils[$((choice - 1))]}"
	return "${?}"
}

# =============================================================================
# ROLLBACK : restaurer un instantané pré-restauration
# =============================================================================

rollback() {
	local target="${1:-}"
	_check_nas_rw || return 1
	_check_nas_perms
	_collect_archives

	if [[ -n ${target} ]]; then
		_rollback_one "${target}"
		return "${?}"
	fi

	# Profils disposant d'au moins un instantané.
	local -a profils=()
	local -A vu=()
	local i group p
	for i in "${!ARCH_GROUP[@]}"; do
		group="${ARCH_GROUP[${i}]}"
		[[ ${group} == "${SNAPSHOT_SUBDIR}/"* ]] || continue
		p="$(_group_profile "${group}")"
		[[ -n "${vu[${p}]:-}" ]] && continue
		vu[${p}]=1
		profils+=("${p}")
	done

	if ((${#profils[@]} == 0)); then
		_INFO "aucun instantané dans ${NAS_MOUNT}/${SNAPSHOT_SUBDIR}"
		return 0
	fi
	mapfile -t profils < <(printf '%s\n' "${profils[@]}" | sort || true)

	if ! _is_tty; then
		_ERR "instantanés disponibles :"
		local when size_h
		for p in "${profils[@]}"; do
			_latest_archive "${SNAPSHOT_SUBDIR}/${p}"
			when="$(_fmt_datekey "${LATEST_DT}")"
			size_h="$(_human_size "${LATEST_SIZE}")"
			printf '   %-14s %s  %s\n' "${p}" "${when}" "${size_h}" >&2
		done
		_ERR "usage : rollback PROFIL"
		return 2
	fi

	printf '\n%bInstantanés disponibles :%b\n\n' "${C_CYAN}" "${C_RESET}"
	local -i k=1
	local when size_h
	for p in "${profils[@]}"; do
		_latest_archive "${SNAPSHOT_SUBDIR}/${p}"
		when="$(_fmt_datekey "${LATEST_DT}")"
		size_h="$(_human_size "${LATEST_SIZE}")"
		printf '  %b%2d)%b %-14s %s  %s\n' "${C_GREEN}" "${k}" "${C_RESET}" "${p}" "${when}" "${size_h}"
		k=$((k + 1))
	done
	local cancel_idx=${k}
	printf '  %b%2d)%b Annuler\n' "${C_GREEN}" "${k}" "${C_RESET}"

	local choice=""
	printf '\n%b#?%b ' "${C_CYAN}" "${C_RESET}"
	if ! read -r choice; then
		printf '\n'
		_ERR "aucune saisie — abandon"
		return 2
	fi
	if [[ ! ${choice} =~ ^[0-9]+$ ]] || ((choice < 1 || choice > cancel_idx)); then
		_ERR "choix invalide"
		return 2
	fi
	if ((choice == cancel_idx)); then
		_INFO "annulé"
		return 0
	fi
	_rollback_one "${profils[$((choice - 1))]}"
	return "${?}"
}

# =============================================================================
# VÉRIFICATION ET SUPPRESSION D'UNE ARCHIVE
# =============================================================================

verify() {
	local f="${1:-}" rc=0
	if [[ -z ${f} ]]; then
		_ERR "usage : verify FICHIER"
		return 2
	fi
	if [[ ! -f ${f} ]]; then
		_ERR "fichier absent : ${f}"
		return 1
	fi
	if ((LOG_FILES == 1)); then
		_log "--- contenu de ${f##*/} ---"
	fi
	_RUN "Vérification de ${f##*/}" _verify_archive "${f}" 1
	rc=$?
	if ((LOG_FILES == 1)); then
		_log "--- fin du contenu ---"
	fi
	case "${rc}" in
	0)
		local bytes=0 size_h=""
		bytes="$(_file_size "${f}")"
		size_h="$(_human_size "${bytes}")"
		_OK "archive valide : ${f##*/} (${size_h})"
		return 0
		;;
	2)
		_WARN "non vérifiable (clé indisponible) : ${f##*/}"
		return 2
		;;
	*)
		_ERR "archive corrompue ou vide : ${f##*/}"
		return 1
		;;
	esac
}

delete_archive() {
	local -a files=("${@}")
	local f rc=0
	if ((${#files[@]} == 0)); then
		_ERR "usage : delete-archive FICHIER..."
		return 2
	fi
	_check_nas_rw || return 1
	# Tout valider avant d'effacer quoi que ce soit.
	for f in "${files[@]}"; do
		_ensure_in_nas "${f}" || return 1
		if [[ ! -f ${f} ]]; then
			_ERR "fichier absent : ${f}"
			return 1
		fi
	done
	if ((DRY_RUN == 1)); then
		for f in "${files[@]}"; do
			_INFO "serait supprimé : ${f##*/}"
		done
		return 0
	fi
	if ((${#files[@]} > 1)); then
		for f in "${files[@]}"; do
			_INFO "à supprimer : ${f##*/}"
		done
	fi
	local nf=${#files[@]} c=""
	c="$(_count "${nf}" fichier fichiers)"
	if ! _confirm "Supprimer définitivement ${c} ?"; then
		_INFO "annulé — rien n'a été supprimé"
		return 0
	fi
	for f in "${files[@]}"; do
		if ! _RUN "Suppression de ${f##*/}" rm -f -- "${f}"; then
			rc=1
		fi
	done
	return "${rc}"
}

# =============================================================================
# PARAMÈTRES (écriture des valeurs simples du fichier de configuration)
# =============================================================================

# Clés modifiables par `config-set` (liste blanche).
_config_key_ok() {
	case "${1}" in
	NAS|BACKUP_SUBDIR|KEEP_DEFAULT|VERIFY_DEFAULT|SNAPSHOT_DEFAULT|SNAPSHOT_MAX_MB|NAS_TIMEOUT|LOG_FILES|ENCRYPT|AGE_RECIPIENT|AGE_IDENTITY) return 0 ;;
	*) return 1 ;;
	esac
}

# Remplace (ou ajoute) une affectation simple KEY="..." dans FILE.
_config_write_scalar() {
	local file="${1}" key="${2}" val="${3}" tmp="${1}.sc.$$"
	local esc=""
	esc="$(_dq "${val}")"
	SCALAR_KEY="${key}" SCALAR_VAL="${esc}" awk '
		BEGIN { k = ENVIRON["SCALAR_KEY"]; v = ENVIRON["SCALAR_VAL"]; done = 0 }
		!done && $0 ~ ("^" k "[ \t]*=") { print k "=\"" v "\""; done = 1; next }
		{ print }
		END { if (!done) print k "=\"" v "\"" }
	' "${file}" >"${tmp}" || {
		rm -f -- "${tmp}"
		return 1
	}
	if ! mv -f -- "${tmp}" "${file}"; then
		rm -f -- "${tmp}"
		return 1
	fi
	return 0
}

config_set() {
	local -a pairs=("${@}")
	local pair key val file="${CFG_FILE}" tmp="" bak=""

	if ((${#pairs[@]} == 0)); then
		_ERR "usage : config-set CLE=VALEUR [CLE=VALEUR...]"
		return 2
	fi
	if [[ -z ${file} ]]; then
		_ERR "aucun fichier de configuration chargé"
		return 1
	fi
	for pair in "${pairs[@]}"; do
		if [[ ${pair} != *=* ]]; then
			_ERR "argument invalide : ${pair} (attendu CLE=VALEUR)"
			return 2
		fi
		key="${pair%%=*}"
		if [[ -z ${key} ]] || ! _config_key_ok "${key}"; then
			_ERR "clé non modifiable : ${key:-?} (voir la liste dans le script)"
			return 2
		fi
	done

	tmp="${file}.tmp.$$"
	if ! cp -p -- "${file}" "${tmp}" 2>/dev/null; then
		_ERR "copie impossible vers ${tmp}"
		return 1
	fi
	for pair in "${pairs[@]}"; do
		key="${pair%%=*}"
		val="${pair#*=}"
		if [[ ${val} == *$'\n'* ]] || [[ ${val} == *$'\r'* ]]; then
			rm -f -- "${tmp}"
			_ERR "valeur multiligne refusée pour ${key}"
			return 2
		fi
		if ! _config_write_scalar "${tmp}" "${key}" "${val}"; then
			rm -f -- "${tmp}"
			_ERR "écriture de ${key} impossible"
			return 1
		fi
	done
	if ! _config_validate_file "${tmp}"; then
		rm -f -- "${tmp}"
		_ERR "rien n'a été écrit"
		return 1
	fi
	bak="${file}.bak"
	cp -p -- "${file}" "${bak}" 2>/dev/null || _WARN "sauvegarde ${bak} impossible"
	if ! mv -f -- "${tmp}" "${file}"; then
		rm -f -- "${tmp}"
		_ERR "écriture impossible : ${file}"
		return 1
	fi
	_OK "configuration mise à jour : ${file}"
	for pair in "${pairs[@]}"; do
		_INFO "${pair%%=*} = ${pair#*=}"
	done
	return 0
}

# =============================================================================
# ADOPTION DES PROFILS ORPHELINS
# =============================================================================

adopt_orphans() {
	local -a filtres=("${@}") noms=() sources=()
	local -A filtre=() vu=()
	local i group src tmp="" rc=0

	# Application d'un plan préparé : aucune relecture des archives.
	if [[ -n ${APPLY_PLAN} ]]; then
		if [[ ! -r ${APPLY_PLAN} ]]; then
			_ERR "plan illisible : ${APPLY_PLAN}"
			return 2
		fi
		while IFS=$'\t' read -r i src; do
			[[ -n ${i} ]] || continue
			if ! _source_path_ok "${src}"; then
				_ERR "plan invalide : dossier manquant, absolu ou avec « .. » pour ${i}"
				return 2
			fi
			if _known_profile "${i}"; then
				_ERR "déjà dans la configuration : ${i}"
				return 2
			fi
			noms+=("${i}")
			sources+=("${src}")
		done <"${APPLY_PLAN}"
		if ((${#noms[@]} == 0)); then
			_INFO "plan vide — rien à adopter"
			return 0
		fi
	else
		_check_nas || return 1
		_collect_archives
	fi

	for i in "${filtres[@]}"; do
		i="${i^^}"
		if _known_profile "${i}"; then
			_ERR "profil déjà dans la configuration : ${i}"
			return 2
		fi
		filtre[${i}]=1
	done

	# Un candidat par profil orphelin : son archive la plus récente.
	if [[ -z ${APPLY_PLAN} ]]; then
	for i in "${!ARCH_GROUP[@]}"; do
		group="${ARCH_GROUP[${i}]}"
		[[ ${group} == "${SNAPSHOT_SUBDIR}/"* ]] && continue
		_known_profile "${group}" && continue
		if ! _valid_profile_name "${group}"; then
			_WARN "${group} : nom de profil invalide — ignoré"
			rc=1
			continue
		fi
		[[ -n "${vu[${group}]:-}" ]] && continue
		vu[${group}]=1
		if ((${#filtres[@]} > 0)) && [[ -z "${filtre[${group}]:-}" ]]; then
			continue
		fi
		if ((DRY_RUN == 1)); then
			_INFO "analyse de ${ARCH_PATH[${i}]##*/}…"
		fi
		tmp="$(mktemp)" || return 1
		if ! _RUN "Analyse de ${ARCH_PATH[${i}]##*/}" _archive_root_to "${ARCH_PATH[${i}]}" "${tmp}"; then
			rm -f -- "${tmp}"
			_WARN "${group} : racine indéterminée (plusieurs dossiers dans l'archive) — ignoré"
			rc=1
			continue
		fi
		src="$(cat -- "${tmp}")"
		rm -f -- "${tmp}"
		if ! _source_path_ok "${src}"; then
			_WARN "${group} : racine non adoptable (${src}) — ignoré"
			rc=1
			continue
		fi
		noms+=("${group}")
		sources+=("${src}")
	done
	fi

	# Écriture du plan si demandée (permet d'appliquer sans réanalyser).
	if [[ -n ${PLAN_FILE} ]]; then
		: >"${PLAN_FILE}" || {
			_ERR "impossible d'écrire le plan : ${PLAN_FILE}"
			return 1
		}
		for i in "${!noms[@]}"; do
			printf '%s\t%s\n' "${noms[${i}]}" "${sources[${i}]}" >>"${PLAN_FILE}"
		done
	fi

	if ((${#noms[@]} == 0)); then
		_INFO "aucun profil orphelin à adopter"
		return "${rc}"
	fi

	printf '\n%bProfils orphelins à adopter%b :\n' "${C_BOLD}" "${C_RESET}"
	for i in "${!noms[@]}"; do
		printf '  %b+%b %-14s ← ~/%s\n' "${C_GREEN}" "${C_RESET}" "${noms[${i}]}" "${sources[${i}]}"
	done

	# Conflits avec les profils existants et entre les adoptés.
	local k j
	for i in "${!noms[@]}"; do
		for k in "${!SOURCES[@]}"; do
			if _source_overlap "${sources[${i}]}" "${SOURCES[${k}]}"; then
				_WARN "${noms[${i}]} (~/${sources[${i}]}) chevauche ${k} (~/${SOURCES[${k}]})"
			fi
		done
		for ((j = 0; j < i; j++)); do
			if _source_overlap "${sources[${i}]}" "${sources[${j}]}"; then
				_WARN "${noms[${i}]} (~/${sources[${i}]}) chevauche ${noms[${j}]} (~/${sources[${j}]})"
			fi
		done
	done

	if ((DRY_RUN == 1)); then
		_INFO "--dry-run : rien n'a été écrit"
		return "${rc}"
	fi
	local cn=""
	cn="$(_count "${#noms[@]}" profil profils)"
	if ! _confirm "Ajouter ${cn} à la configuration ?"; then
		_INFO "annulé — configuration inchangée"
		return "${rc}"
	fi

	for i in "${!noms[@]}"; do
		SOURCES[${noms[${i}]}]="${sources[${i}]}"
	done
	if ! _config_save; then
		_ERR "adoption non enregistrée"
		return 1
	fi
	_config_conflicts
	local cn=""
	cn="$(_count "${#noms[@]}" "profil adopté" "profils adoptés")"
	_INFO "${cn} ; ils ne sont plus orphelins"
	return "${rc}"
}

# =============================================================================
# SAUVEGARDES AUTOMATIQUES (timers systemd --user)
# =============================================================================
# Un template de service et un timer par profil, dans
# ~/.config/systemd/user. Aucun privilège root : les timers tournent avec le
# gestionnaire systemd de l'utilisateur. Sans « linger », ils ne s'exécutent
# que pendant une session ouverte (timer-linger l'active).

_timer_unit_dir() {
	local base="${XDG_CONFIG_HOME:-${HOME}/.config}"
	[[ ${base} == /* ]] || base="${HOME}/.config"
	printf '%s' "${PRIVATE_BACKUP_UNIT_DIR:-${base}/systemd/user}"
}

_timer_unit() {
	printf '%s@%s.timer' "${SCRIPTNAME}" "${1}"
}

_timer_service_unit() {
	printf '%s@%s.service' "${SCRIPTNAME}" "${1}"
}

_timer_valid_time() {
	[[ ${1} =~ ^([01][0-9]|2[0-3]):[0-5][0-9]$ ]]
}

# Jour français ou anglais -> abréviation systemd (Mon…Sun).
_timer_day() {
	local d=""
	d="$(printf '%s' "${1}" | tr '[:upper:]' '[:lower:]')"
	d="${d//é/e}"; d="${d//è/e}"; d="${d//ê/e}"; d="${d//ë/e}"
	d="${d//à/a}"; d="${d//â/a}"; d="${d//ä/a}"
	d="${d//î/i}"; d="${d//ï/i}"
	d="${d//ô/o}"; d="${d//ö/o}"
	d="${d//û/u}"; d="${d//ü/u}"; d="${d//ù/u}"
	d="${d//ç/c}"
	case "${d}" in
	lundi | lun | monday | mon) printf 'Mon' ;;
	mardi | mar | tuesday | tue) printf 'Tue' ;;
	mercredi | mer | wednesday | wed) printf 'Wed' ;;
	jeudi | jeu | thursday | thu) printf 'Thu' ;;
	vendredi | ven | friday | fri) printf 'Fri' ;;
	samedi | sam | saturday | sat) printf 'Sat' ;;
	dimanche | dim | sunday | sun) printf 'Sun' ;;
	*) return 1 ;;
	esac
	return 0
}

# Abréviation systemd -> nom français (affichage).
_timer_day_fr() {
	case "${1}" in
	Mon) printf 'lundi' ;;
	Tue) printf 'mardi' ;;
	Wed) printf 'mercredi' ;;
	Thu) printf 'jeudi' ;;
	Fri) printf 'vendredi' ;;
	Sat) printf 'samedi' ;;
	Sun) printf 'dimanche' ;;
	*) printf '%s' "${1}" ;;
	esac
	return 0
}

# Écrit un fichier d'unité de façon atomique.
_timer_put() {
	local path="${1}" dir="" tmp=""
	shift
	dir="${path%/*}"
	if ! mkdir -p -- "${dir}" 2>/dev/null; then
		_ERR "dossier d'unités inaccessible : ${dir}"
		return 1
	fi
	tmp="${path}.tmp.$$"
	if ! printf '%s\n' "${@}" >"${tmp}" 2>/dev/null; then
		rm -f -- "${tmp}"
		_ERR "écriture impossible : ${path}"
		return 1
	fi
	if ! mv -f -- "${tmp}" "${path}"; then
		rm -f -- "${tmp}"
		_ERR "écriture impossible : ${path}"
		return 1
	fi
	return 0
}

# Variante de _timer_put : contenu lu sur l'entrée standard.
_timer_put_stdin() {
	local path="${1}" dir="" tmp=""
	dir="${path%/*}"
	if ! mkdir -p -- "${dir}" 2>/dev/null; then
		_ERR "dossier d'unités inaccessible : ${dir}"
		return 1
	fi
	tmp="${path}.tmp.$$"
	if ! cat >"${tmp}" 2>/dev/null; then
		rm -f -- "${tmp}"
		_ERR "écriture impossible : ${path}"
		return 1
	fi
	if ! mv -f -- "${tmp}" "${path}"; then
		rm -f -- "${tmp}"
		_ERR "écriture impossible : ${path}"
		return 1
	fi
	return 0
}

# Guillemets sûrs pour une valeur d'unité systemd (ExecStart/Environment).
_systemd_quote() {
	local s="${1:-}"
	[[ ${s} != *$'\n'* && ${s} != *$'\r'* ]] || return 1
	s="${s//\\/\\\\}"
	s="${s//\"/\\\"}"
	s="${s//%/%%}"
	printf '"%s"' "${s}"
}

# Template de service commun à tous les profils (%i = nom du profil).
_timer_write_service() {
	local cfg="${1}" dir="" path="" script="" cfgexec="" cfgq=""
	dir="$(_timer_unit_dir)"
	path="${dir}/${SCRIPTNAME}@.service"
	script="$(_systemd_quote "${SELF_PATH}")" || {
		_ERR "chemin du script invalide pour l'unité (retour à la ligne)"
		return 1
	}
	if [[ -n ${cfg} ]]; then
		cfgq="$(_systemd_quote "${cfg}")" || {
			_ERR "chemin de configuration invalide pour l'unité"
			return 1
		}
		cfgexec="--config ${cfgq} "
	fi
	_timer_put "${path}" \
		"[Unit]" \
		"Description=Sauvegarde automatique du profil %i (${SCRIPTNAME})" \
		"" \
		"[Service]" \
		"Type=oneshot" \
		"Environment=PRIVATE_BACKUP_LOCK_WAIT=7200" \
		"Environment=PRIVATE_BACKUP_STRICT_SKIP=1" \
		"ExecStart=${script} ${cfgexec}backup %i" \
		"TimeoutStartSec=12h" \
		"Nice=10" \
		"IOSchedulingClass=idle"
}

# Timer d'un profil. Les métadonnées (fréquence, heure, jour) sont conservées
# dans un commentaire pour que timer-list n'ait pas à réinterpréter OnCalendar.
_timer_write_timer() {
	local name="${1}" freq="${2}" time="${3}" day="${4}" ext="${5:-0}"
	local dir="" path="" cal="" desc="" meta="" dayfr="" extmeta=""
	dayfr="$(_timer_day_fr "${day}")"
	dir="$(_timer_unit_dir)"
	path="${dir}/$(_timer_unit "${name}")"
	((ext == 1)) && extmeta=" extinction=1"
	if [[ ${freq} == "hebdomadaire" ]]; then
		cal="${day} *-*-* ${time}:00"
		desc="hebdomadaire (${dayfr})"
		meta="# private-data-backup: frequence=hebdomadaire heure=${time} jour=${dayfr}${extmeta}"
	else
		cal="*-*-* ${time}:00"
		desc="quotidienne"
		meta="# private-data-backup: frequence=quotidien heure=${time}${extmeta}"
	fi
	_timer_put "${path}" \
		"${meta}" \
		"" \
		"[Unit]" \
		"Description=Sauvegarde ${desc} du profil ${name}" \
		"" \
		"[Timer]" \
		"OnCalendar=${cal}" \
		"Persistent=true" \
		"AccuracySec=1min" \
		"" \
		"[Install]" \
		"WantedBy=timers.target"
}

# Métadonnées d'un fichier timer : « fréquence<TAB>heure<TAB>jour ».
_timer_meta() {
	local file="${1}" meta="" kv="" key="" val="" freq="?" time="?" day="" ext="0"
	local -a champs=()
	meta="$(sed -n 's/^# private-data-backup: //p' "${file}" 2>/dev/null | head -n 1)" || meta=""
	if [[ -n ${meta} ]]; then
		read -r -a champs <<<"${meta}"
		for kv in "${champs[@]}"; do
			key="${kv%%=*}"
			val="${kv#*=}"
			case "${key}" in
			frequence) freq="${val}" ;;
			heure) time="${val}" ;;
			jour) day="${val}" ;;
			extinction) ext="${val}" ;;
			*) ;;
			esac
		done
	fi
	printf '%s|%s|%s|%s' "${freq}" "${time}" "${day}" "${ext}"
}

_timer_extinction() {
	local dir="" file=""
	_valid_profile_name "${1}" || return 1
	dir="$(_timer_unit_dir)"
	file="${dir}/$(_timer_unit "${1}")"
	[[ -f ${file} ]] && grep -q 'extinction=1' "${file}" 2>/dev/null
}

_shutdown_unit_path() {
	printf '%s/%s' "${SYSTEM_UNIT_DIR}" "${SYSTEM_UNIT_NAME}"
}

_shutdown_unit_installed() {
	local path=""
	path="$(_shutdown_unit_path)"
	[[ -f ${path} ]]
}

_session_unit_path() {
	local dir=""
	dir="$(_timer_unit_dir)"
	printf '%s/%s' "${dir}" "${SESSION_UNIT_NAME}"
}

_session_unit_installed() {
	local path=""
	path="$(_session_unit_path)"
	[[ -f ${path} ]]
}

# Fin de session graphique (déconnexion) : le gestionnaire utilisateur reste
# vivant avec linger, mais graphical-session.target s'arrête.
_session_unit_lines() {
	local script="" cfg=""
	script="$(_systemd_quote "${SELF_PATH}")" || {
		_ERR "chemin du script invalide pour le service de session"
		return 1
	}
	if [[ -n ${CFG_FILE} ]]; then
		cfg="$(readlink -f -- "${CFG_FILE}" 2>/dev/null)" || cfg="${CFG_FILE}"
		cfg="$(_systemd_quote "${cfg}")" || {
			_ERR "chemin de configuration invalide pour le service de session"
			return 1
		}
	fi
	printf '%s\n' \
		"[Unit]" \
		"Description=Sauvegardes private-data_backup en attente (fin de session)" \
		"PartOf=graphical-session.target" \
		"" \
		"[Service]" \
		"Type=oneshot" \
		"RemainAfterExit=yes" \
		"ExecStart=/bin/true" \
		"ExecStop=${script}${cfg:+ --config ${cfg}} backup-pending --shutdown" \
		"Environment=PRIVATE_BACKUP_LOCK_WAIT=7200" \
		"Environment=PRIVATE_BACKUP_STRICT_SKIP=1" \
		"TimeoutStopSec=infinity" \
		"" \
		"[Install]" \
		"WantedBy=default.target graphical-session.target"
	return 0
}

# Installe le service de fin de session (sans root).
_session_unit_write() {
	local path=""
	path="$(_session_unit_path)"
	if ! _session_unit_lines | _timer_put_stdin "${path}"; then
		return 1
	fi
	"${SYSTEMCTL_BIN}" --user daemon-reload 2>/dev/null || _WARN "daemon-reload utilisateur a échoué"
	if ! "${SYSTEMCTL_BIN}" --user enable --now "${SESSION_UNIT_NAME}" 2>&1; then
		_ERR "activation du service de fin de session impossible"
		return 1
	fi
	return 0
}

_timer_state() {
	local unit="${1}" st=""
	st="$("${SYSTEMCTL_BIN}" --user is-active "${unit}" 2>/dev/null)" || true
	printf '%s' "${st:--}"
}

_timer_next() {
	local unit="${1}" out="" short=""
	out="$("${SYSTEMCTL_BIN}" --user show -p NextElapseUSecRealtime --value "${unit}" 2>/dev/null)" || out=""
	case "${out}" in
	"" | n/a | 0)
		printf '%s' "-"
		return 0
		;;
	*) ;;
	esac
	# Format compact et stable (systemd renvoie une date localisée longue).
	short="$(date -d "${out}" '+%Y-%m-%d %H:%M' 2>/dev/null)" || short="${out}"
	printf '%s' "${short}"
}

_timer_result() {
	# « success » est aussi renvoyé pour un service jamais exécuté : on
	# s'appuie sur la date de dernier démarrage pour distinguer les deux.
	local unit="${1}" started="" out=""
	started="$("${SYSTEMCTL_BIN}" --user show -p ExecMainStartTimestamp --value "${unit}" 2>/dev/null)" || started=""
	case "${started}" in
	"" | n/a) printf '%s' "-"; return 0 ;;
	*) ;;
	esac
	out="$("${SYSTEMCTL_BIN}" --user show -p Result --value "${unit}" 2>/dev/null)" || out=""
	printf '%s' "${out:--}"
}

_timer_exists() {
	local dir="" unit=""
	_valid_profile_name "${1}" || return 1
	dir="$(_timer_unit_dir)"
	unit="$(_timer_unit "${1}")"
	[[ -f "${dir}/${unit}" ]]
}

_timer_user() {
	local u="${USER:-}"
	if [[ -z ${u} ]]; then
		u="$(id -un)" || u="${LOGNAME:-utilisateur}"
	fi
	printf '%s' "${u}"
}

_linger_state() {
	local out="" user=""
	user="$(_timer_user)"
	if command -v loginctl >/dev/null 2>&1; then
		out="$(loginctl show-user "${user}" --property=Linger --value 2>/dev/null)" || out=""
	fi
	case "${out}" in
	yes | no) printf '%s' "${out}" ;;
	*) printf 'inconnu' ;;
	esac
}

# Notification bureau (best effort) ; sans notify-send, journal seulement.
_notify() {
	local title="${1}" body="${2}"
	((NOTIFY_ENABLED == 1)) || return 0
	if command -v notify-send >/dev/null 2>&1; then
		timeout 5 notify-send --app-name="${SCRIPTNAME}" --urgency=normal \
			--icon=dialog-information "${title}" "${body}" 2>/dev/null || true
		return 0
	fi
	_log "notification : ${title} — ${body}"
	return 0
}

_pending_file() {
	_valid_profile_name "${1}" || return 1
	printf '%s/%s' "${PENDING_DIR}" "${1}"
}

_pending_has() {
	local file=""
	file="$(_pending_file "${1}")"
	[[ -f ${file} ]]
}

_pending_clear() {
	local file=""
	file="$(_pending_file "${1}")" || return 0
	if [[ -e ${file} ]]; then
		rm -f -- "${file}" 2>/dev/null && _log "attente d'extinction levée : ${1}"
	fi
	return 0
}

_pending_list() {
	local file="" name=""
	[[ -d ${PENDING_DIR} ]] || return 0
	for file in "${PENDING_DIR}"/*; do
		[[ -f ${file} ]] || continue
		name="${file##*/}"
		_valid_profile_name "${name}" || continue
		printf '%s\n' "${name}"
	done | sort || true
}

# Marque un profil pour une tentative à l'extinction (si son timer l'autorise).
_pending_add() {
	local name="${1}" reason="${2}" file="" tmp="" state=""
	((DRY_RUN == 1)) && return 0
	_timer_extinction "${name}" || return 0
	file="$(_pending_file "${name}")" || return 0
	[[ -f ${file} ]] && return 0
	state="${PENDING_DIR%/*}"
	if ! mkdir -p -- "${PENDING_DIR}" 2>/dev/null; then
		_WARN "${name} : dossier d'attente inaccessible (${PENDING_DIR})"
		return 1
	fi
	chmod 700 -- "${state}" "${PENDING_DIR}" 2>/dev/null || true
	tmp="${file}.tmp.$$"
	local now=""
	now="$(date '+%Y-%m-%d %H:%M:%S')" || now="?"
	if ! printf '%s\t%s\n' "${now}" "${reason}" >"${tmp}" 2>/dev/null; then
		rm -f -- "${tmp}"
		_WARN "${name} : écriture de l'attente impossible"
		return 1
	fi
	chmod 600 -- "${tmp}" 2>/dev/null || true
	if ! mv -f -- "${tmp}" "${file}"; then
		rm -f -- "${tmp}"
		_WARN "${name} : écriture de l'attente impossible"
		return 1
	fi
	_log "sauvegarde reportée à l'extinction : ${name} (${reason})"
	_notify "Sauvegarde reportée" \
		"${name} : ${reason}. Elle sera tentée à la fermeture de session."
	return 0
}

_timer_need_systemd() {
	if ! command -v "${SYSTEMCTL_BIN}" >/dev/null 2>&1; then
		_ERR "systemctl introuvable : les timers nécessitent systemd"
		return 1
	fi
	return 0
}

# Avertit si les timers ne survivront pas à la fermeture de session.
_timer_linger_warn() {
	local st=""
	st="$(_linger_state)"
	if [[ ${st} == "no" ]]; then
		_WARN "linger désactivé : les timers ne tournent que session ouverte"
		_INFO "pour les exécuter en continu : ${SCRIPTNAME} timer-linger"
	fi
	return 0
}

timer_add() {
	local name="${1:-}" freq="${2:-}" a3="${3:-}" a4="${4:-}"
	local time="" day="" dayfr="" dir="" path="" unit="" cfg="" rc=0 ext=0
	name="${name^^}"
	if ! _valid_profile_name "${name}" || ! _known_profile "${name}"; then
		_ERR "profil inconnu : ${name} (voir show)"
		return 2
	fi
	freq="$(printf '%s' "${freq}" | tr '[:upper:]' '[:lower:]')"
	case "${freq}" in
	quotidien | daily | jour)
		freq="quotidien"
		time="${a3}"
		;;
	hebdomadaire | weekly | semaine)
		freq="hebdomadaire"
		day="$(_timer_day "${a3}")" || {
			_ERR "jour invalide : ${a3} (lundi…dimanche)"
			return 2
		}
		time="${a4}"
		;;
	*)
		_ERR "fréquence attendue : quotidien HH:MM ou hebdomadaire JOUR HH:MM"
		return 2
		;;
	esac
	if ! _timer_valid_time "${time}"; then
		_ERR "heure invalide : ${time:-absente} (format HH:MM, 00:00–23:59)"
		return 2
	fi
	if ! _timer_need_systemd; then
		return 1
	fi
	# Mode extinction : explicite (--extinction/--no-extinction), sinon
	# conservé tel quel pour une planification existante.
	ext="${EXTINCTION_VAL}"
	if ((EXTINCTION_SET == 0)); then
		ext=0
		_timer_extinction "${name}" && ext=1
	fi

	dir="$(_timer_unit_dir)"
	path="${dir}/$(_timer_unit "${name}")"
	unit="$(_timer_unit "${name}")"
	svc="$(_timer_service_unit "${name}")"
	if [[ -n ${CFG_FILE} ]]; then
		cfg="$(readlink -f -- "${CFG_FILE}" 2>/dev/null)" || cfg="${CFG_FILE}"
	fi

	if ((DRY_RUN == 1)); then
		_INFO "profil   : ${name}"
		_INFO "service  : ${dir}/${SCRIPTNAME}@.service"
		_INFO "timer    : ${path}"
		if [[ ${freq} == "hebdomadaire" ]]; then
			_INFO "calendrier : ${day} *-*-* ${time}:00"
		else
			_INFO "calendrier : *-*-* ${time}:00"
		fi
		_INFO "commandes : ${SYSTEMCTL_BIN} --user daemon-reload && ${SYSTEMCTL_BIN} --user enable --now ${unit}"
		((ext == 1)) && _INFO "mode extinction : oui (service ${SYSTEM_UNIT_NAME})"
		return 0
	fi

	if ! _timer_write_service "${cfg}"; then
		return 1
	fi
	if ! _timer_write_timer "${name}" "${freq}" "${time}" "${day}" "${ext}"; then
		return 1
	fi
	if ! "${SYSTEMCTL_BIN}" --user daemon-reload 2>/dev/null; then
		_WARN "daemon-reload a échoué (les unités existent, réessaie plus tard)"
		rc=1
	fi
	if ! "${SYSTEMCTL_BIN}" --user enable --now "${unit}" 2>&1; then
		_ERR "activation impossible : ${unit}"
		return 1
	fi
	if [[ ${freq} == "hebdomadaire" ]]; then
		dayfr="$(_timer_day_fr "${day}")"
		_OK "${name} : sauvegarde hebdomadaire le ${dayfr} à ${time}"
	else
		_OK "${name} : sauvegarde quotidienne à ${time}"
	fi
	if ((ext == 1)); then
		_INFO "mode extinction : les sauvegardes impossibles seront tentées à la fermeture de session"
		if ! _shutdown_unit_installed || ! _session_unit_installed; then
			_WARN "services d'extinction incomplets — ${SCRIPTNAME} timer-shutdown-enable"
		fi
	else
		_pending_clear "${name}"
	fi
	_INFO "timer actif : ${unit}"
	_timer_linger_warn
	return "${rc}"
}

timer_remove() {
	local name="${1:-}" dir="" path="" unit="" rc=0
	name="${name^^}"
	if ! _valid_profile_name "${name}"; then
		_ERR "nom de profil invalide : ${name:-absent}"
		return 2
	fi
	if ! _timer_exists "${name}"; then
		_ERR "aucune planification pour ${name}"
		return 2
	fi
	if ! _timer_need_systemd; then
		return 1
	fi
	dir="$(_timer_unit_dir)"
	path="${dir}/$(_timer_unit "${name}")"
	unit="$(_timer_unit "${name}")"

	if ((DRY_RUN == 1)); then
		_INFO "désactiverait ${unit} et supprimerait ${path}"
		[[ -f ${dir}/${SCRIPTNAME}@.service ]] && _INFO "conserverait le service ${SCRIPTNAME}@.service (partagé)"
		return 0
	fi
	if ! _confirm "Supprimer la sauvegarde automatique de ${name} ?"; then
		_INFO "annulé — planification inchangée"
		return 3
	fi

	if ! "${SYSTEMCTL_BIN}" --user disable --now "${unit}" 2>&1; then
		_WARN "désactivation de ${unit} incomplète"
		rc=1
	fi
	if ! rm -f -- "${path}"; then
		_ERR "suppression impossible : ${path}"
		return 1
	fi
	# Le template de service ne sert que s'il reste au moins un timer.
	if ! compgen -G "${dir}/${SCRIPTNAME}@*.timer" >/dev/null; then
		rm -f -- "${dir}/${SCRIPTNAME}@.service" 2>/dev/null
	fi
	if ! "${SYSTEMCTL_BIN}" --user daemon-reload 2>/dev/null; then
		_WARN "daemon-reload a échoué"
		rc=1
	fi
	_pending_clear "${name}"
	_OK "${name} : sauvegarde automatique supprimée"
	return "${rc}"
}

timer_run() {
	local name="${1:-}" svc="" out=""
	name="${name^^}"
	if ! _valid_profile_name "${name}"; then
		_ERR "nom de profil invalide : ${name:-absent}"
		return 2
	fi
	if ! _timer_exists "${name}"; then
		_ERR "aucune planification pour ${name}"
		return 2
	fi
	if ! _timer_need_systemd; then
		return 1
	fi
	svc="$(_timer_service_unit "${name}")"
	if ((DRY_RUN == 1)); then
		_INFO "lancerait ${SYSTEMCTL_BIN} --user start ${svc}"
		return 0
	fi
	# --no-block : le service peut durer des heures, on ne bloque pas le terminal.
	if ! out="$("${SYSTEMCTL_BIN}" --user start --no-block "${svc}" 2>&1)"; then
		_ERR "lancement impossible : ${svc}"
		[[ -n ${out} ]] && printf '%s\n' "${out}" >&2
		return 1
	fi
	_OK "${name} : sauvegarde lancée (service ${svc})"
	_INFO "suivi : journalctl --user -u ${svc} -f"
	return 0
}

timer_list() {
	local dir="" file="" name="" meta="" freq="" time="" day="" ext="" when="" unit="" svc="" st="" next="" res="" n=0 ext_h=""
	local -a noms=()
	dir="$(_timer_unit_dir)"
	if ! compgen -G "${dir}/${SCRIPTNAME}@*.timer" >/dev/null; then
		if ((PORCELAIN == 0)); then
			_INFO "aucune sauvegarde automatique"
			local -a attente0=()
			mapfile -t attente0 < <(_pending_list || true)
			if ((${#attente0[@]} > 0)); then
				_INFO "en attente d'extinction : ${attente0[*]}"
			fi
		fi
		return 0
	fi
	while IFS= read -r file; do
		[[ -n ${file} ]] && noms+=("${file}")
	done < <(compgen -G "${dir}/${SCRIPTNAME}@*.timer" | sort || true)

	if ((PORCELAIN == 1)); then
		for file in "${noms[@]}"; do
			name="${file##*/}"
			name="${name#"${SCRIPTNAME}"@}"
			name="${name%.timer}"
			meta="$(_timer_meta "${file}")"
			IFS='|' read -r freq time day ext <<<"${meta}"
			when="${time}"
			[[ ${freq} == "hebdomadaire" ]] && when="${day} ${time}"
			unit="$(_timer_unit "${name}")"
			svc="$(_timer_service_unit "${name}")"
			st="$(_timer_state "${unit}")"
			next="$(_timer_next "${unit}")"
			res="$(_timer_result "${svc}")"
			ext_h="non"
			[[ ${ext} == 1 ]] && ext_h="oui"
			printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
				"${name}" "${freq}" "${when}" "${next}" "${st}" "${res}" "${ext_h}"
		done
		return 0
	fi

	local -a col_name=() col_freq=() col_next=() col_state=() col_res=() col_ext=()
	local w_name=6 w_freq=10 w_next=19 w_ext=10
	for file in "${noms[@]}"; do
		name="${file##*/}"
		name="${name#"${SCRIPTNAME}"@}"
		name="${name%.timer}"
		meta="$(_timer_meta "${file}")"
		IFS='|' read -r freq time day ext <<<"${meta}"
		when="${time}"
		[[ ${freq} == "hebdomadaire" ]] && when="${day} ${time}"
		unit="$(_timer_unit "${name}")"
		svc="$(_timer_service_unit "${name}")"
		st="$(_timer_state "${unit}")"
		next="$(_timer_next "${unit}")"
		res="$(_timer_result "${svc}")"
		ext_h="non"
		[[ ${ext} == 1 ]] && ext_h="oui"
		col_name+=("${name}")
		col_freq+=("${freq} ${when}")
		col_next+=("${next}")
		col_state+=("${st}")
		col_res+=("${res}")
		col_ext+=("${ext_h}")
		((${#name} > w_name)) && w_name=${#name}
		((${#freq} + 1 + ${#when} > w_freq)) && w_freq=$((${#freq} + 1 + ${#when}))
		((${#next} > w_next)) && w_next=${#next}
		((${#ext_h} > w_ext)) && w_ext=${#ext_h}
		n=$((n + 1))
	done

	printf '\n%b' "${C_BOLD}"
	_pad "PROFIL" "${w_name}"
	printf ' '
	_pad "FRÉQUENCE" "${w_freq}"
	printf ' '
	_pad "PROCHAINE EXÉCUTION" "${w_next}"
	printf ' '
	_pad "ÉTAT" 9
	printf ' '
	_pad "EXTINCTION" "${w_ext}"
	printf ' %s%b\n' "DERNIER RÉSULTAT" "${C_RESET}"
	local idx=0
	for idx in "${!col_name[@]}"; do
		_pad "${col_name[${idx}]}" "${w_name}"
		printf ' '
		_pad "${col_freq[${idx}]}" "${w_freq}"
		printf ' '
		_pad "${col_next[${idx}]}" "${w_next}"
		printf ' '
		_pad "${col_state[${idx}]}" 9
		printf ' '
		_pad "${col_ext[${idx}]}" "${w_ext}"
		printf ' %s\n' "${col_res[${idx}]}"
	done

	local linger=""
	linger="$(_linger_state)"
	printf '\n'
	case "${linger}" in
	yes) _INFO "linger actif : les timers tournent même session fermée" ;;
	no)
		_WARN "linger inactif : les timers ne tournent que session ouverte"
		_INFO "activer : ${SCRIPTNAME} timer-linger"
		;;
	*) _WARN "état du linger indéterminé (loginctl indisponible)" ;;
	esac

	# Profils en attente d'extinction et état du service système.
	local -a attente=()
	mapfile -t attente < <(_pending_list || true)
	if ((${#attente[@]} > 0)); then
		_INFO "en attente d'extinction : ${attente[*]}"
	fi
	local ext_count=0
	for file in "${noms[@]}"; do
		name="${file##*/}"
		name="${name#"${SCRIPTNAME}"@}"
		name="${name%.timer}"
		_timer_extinction "${name}" && ext_count=$((ext_count + 1))
	done
	if ((ext_count > 0)); then
		if ! _shutdown_unit_installed || ! _session_unit_installed; then
			_WARN "mode extinction utilisé mais service incomplet — ${SCRIPTNAME} timer-shutdown-enable"
		else
			_INFO "services d'extinction installés (session + système)"
		fi
	fi

	# Signale un template obsolète (chemin du script ou mode strict absent).
	file="${dir}/${SCRIPTNAME}@.service"
	local selfq=""
	selfq="$(_systemd_quote "${SELF_PATH}")" || selfq="${SELF_PATH//%/%%}"
	if [[ -f ${file} ]]; then
		if ! grep -qF "${selfq}" "${file}" 2>/dev/null; then
			_WARN "le service pointe vers un autre chemin que ${SELF_PATH} — relance ${SCRIPTNAME} timer-sync"
		fi
		if ! grep -qF "PRIVATE_BACKUP_STRICT_SKIP=1" "${file}" 2>/dev/null; then
			_WARN "service généré avant le mode strict — relance ${SCRIPTNAME} timer-sync"
		fi
	fi
	local cn=""
	cn="$(_count "${n}" "planification enregistrée" "planifications enregistrées")"
	_INFO "${cn} : ${dir}"
	return 0
}

# Exécute les sauvegardes marquées « à l'extinction ».
# --shutdown : attend la fermeture de l'application (sans limite) au lieu
# d'abandonner ; utilisé par le service système d'extinction.
backup_pending() {
	local -a noms=()
	local name="" cmd="" r=0 rc=0 done_count=0
	mapfile -t noms < <(_pending_list || true)
	if ((${#noms[@]} == 0)); then
		_INFO "aucune sauvegarde en attente d'extinction"
		return 0
	fi
	if ((SHUTDOWN_RUN == 1)); then
		STRICT_SKIP=1
		_INFO "mode extinction : ${#noms[@]} profil(s) en attente"
	fi
	for name in "${noms[@]}"; do
		if ! _valid_profile_name "${name}" || ! _known_profile "${name}"; then
			_WARN "${name} : profil absent de la configuration — attente levée"
			_pending_clear "${name}"
			continue
		fi
		if ! _timer_extinction "${name}"; then
			_INFO "${name} : mode extinction désactivé — attente levée"
			_pending_clear "${name}"
			continue
		fi
		cmd="${COMMANDS[${name}]:-}"
		if [[ -n ${cmd} ]] && pgrep -x -- "${cmd}" >/dev/null 2>&1; then
			if ((SHUTDOWN_RUN == 1)); then
				_notify "Extinction en attente" \
					"${name} : ${cmd} est encore ouvert. Ferme-le pour permettre la sauvegarde."
				_INFO "${name} : attente de la fermeture de ${cmd}…"
				while pgrep -x -- "${cmd}" >/dev/null 2>&1; do
					sleep 2
				done
			else
				_WARN "${name} : ${cmd} est en cours d'exécution — attente conservée"
				rc=1
				continue
			fi
		fi
		backup "${name}"
		r=$?
		if ((r == 0)); then
			_pending_clear "${name}"
			done_count=$((done_count + 1))
		else
			_WARN "${name} : sauvegarde d'extinction non aboutie — attente conservée"
			rc=1
		fi
	done
	local cn=""
	cn="$(_count "${done_count}" "sauvegarde effectuée" "sauvegardes effectuées")"
	_INFO "attente d'extinction : ${cn}"
	return "${rc}"
}

# Contenu du service système exécuté à l'extinction.
_shutdown_unit_lines() {
	local user="" group="" uid="" home="" state="" cfg="" script="" nas="" mount_unit="" after=""
	local env_home="" env_runtime="" env_state=""
	user="$(_timer_user)"
	group="$(id -gn "${user}" 2>/dev/null)" || group="${user}"
	uid="$(id -u "${user}" 2>/dev/null)" || uid="${UID}"
	home="${HOME}"
	state="${XDG_STATE_HOME:-${home}/.local/state}"
	[[ ${state} == /* ]] || state="${home}/.local/state"
	script="$(_systemd_quote "${SELF_PATH}")" || {
		_ERR "chemin du script invalide pour l'unité d'extinction"
		return 1
	}
	if [[ -n ${CFG_FILE} ]]; then
		cfg="$(readlink -f -- "${CFG_FILE}" 2>/dev/null)" || cfg="${CFG_FILE}"
		cfg="$(_systemd_quote "${cfg}")" || {
			_ERR "chemin de configuration invalide pour l'unité d'extinction"
			return 1
		}
	fi
	nas="${NAS}"
	env_home="$(_systemd_quote "HOME=${home}")" || return 1
	env_runtime="$(_systemd_quote "XDG_RUNTIME_DIR=/run/user/${uid}")" || return 1
	env_state="$(_systemd_quote "XDG_STATE_HOME=${state}")" || return 1
	mount_unit=""
	if [[ -n ${nas} ]] && command -v systemd-escape >/dev/null 2>&1; then
		mount_unit="$(systemd-escape -p --suffix=mount "${nas}" 2>/dev/null)" || mount_unit=""
	fi
	after="After=user@${uid}.service user-runtime-dir@${uid}.service"
	[[ -n ${mount_unit} ]] && after="${after} ${mount_unit}"

	printf '%s\n' \
		"[Unit]" \
		"Description=Sauvegardes private-data_backup en attente (extinction)" \
		"DefaultDependencies=no" \
		"${after}" \
		"Before=shutdown.target" \
		"" \
		"[Service]" \
		"Type=oneshot" \
		"User=${user}" \
		"Group=${group}" \
		"Environment=${env_home}" \
		"Environment=${env_runtime}" \
		"Environment=${env_state}" \
		"Environment=PRIVATE_BACKUP_LOCK_WAIT=7200" \
		"Environment=PRIVATE_BACKUP_STRICT_SKIP=1" \
		"ExecStart=${script}${cfg:+ --config ${cfg}} backup-pending --shutdown" \
		"TimeoutStartSec=infinity" \
		"Nice=10" \
		"IOSchedulingClass=idle" \
		"" \
		"[Install]" \
		"WantedBy=shutdown.target"
	_log "service d'extinction : NAS=${nas}"
	return 0
}

# Installe (root) le service systemd d'extinction.
timer_shutdown_enable() {
	local path="" spath="" dir="" tmp="" need_root=0 rc=0 out="" user=""
	path="$(_shutdown_unit_path)"
	spath="$(_session_unit_path)"
	dir="${path%/*}"
	if ((DRY_RUN == 1)); then
		_INFO "installerait : ${path}"
		_INFO "installerait : ${spath}"
		return 0
	fi
	if ! _confirm "Installer le service d'extinction (root) ?"; then
		_INFO "annulé — service d'extinction non installé"
		return 3
	fi
	if [[ ! -w ${dir} ]] || [[ ${PRIVATE_BACKUP_FORCE_ROOT:-0} == 1 ]]; then
		need_root=1
	fi
	if ((need_root == 1)) && ! command -v pkexec >/dev/null 2>&1; then
		_ERR "pkexec introuvable : installe ${path} en root puis « systemctl enable ${SYSTEM_UNIT_NAME} »"
		return 1
	fi
	if ! _session_unit_write; then
		_ERR "service de fin de session non installé"
		return 1
	fi
	tmp="$(mktemp)" || return 1
	if ! _shutdown_unit_lines >"${tmp}"; then
		rm -f -- "${tmp}"
		return 1
	fi
	chmod 644 -- "${tmp}" 2>/dev/null || true
	if ((need_root == 1)); then
		# Une seule élévation : installation + daemon-reload + enable.
		local inst="" sc=""
		inst="$(command -v install)" || inst="/usr/bin/install"
		sc="$(command -v "${SYSTEMCTL_BIN}")" || sc="/usr/bin/systemctl"
		# shellcheck disable=SC2016 # $1… sont lus par le bash lancé via pkexec
		if ! out="$(pkexec /bin/bash -c '
			set -u
			"$1" -m 0644 "$2" "$3" || exit 1
			"$4" daemon-reload || exit 1
			"$4" enable "$5" || exit 1
		' _ "${inst}" "${tmp}" "${path}" "${sc}" "${SYSTEM_UNIT_NAME}" 2>&1)"; then
			_ERR "installation/activation du service refusée ou impossible"
			[[ -n ${out} ]] && printf '%s\n' "${out}" >&2
			rm -f -- "${tmp}"
			return 1
		fi
		rm -f -- "${tmp}"
	else
		if ! install -m 0644 -- "${tmp}" "${path}" 2>/dev/null; then
			_ERR "écriture impossible : ${path}"
			rm -f -- "${tmp}"
			return 1
		fi
		rm -f -- "${tmp}"
		if ! "${SYSTEMCTL_BIN}" daemon-reload 2>/dev/null; then
			_WARN "daemon-reload a échoué"
			rc=1
		fi
		if ! "${SYSTEMCTL_BIN}" enable "${SYSTEM_UNIT_NAME}" 2>&1; then
			_ERR "activation du service d'extinction impossible"
			return 1
		fi
	fi
	user="$(_timer_user)"
	_OK "service d'extinction installé : ${path}"
	_OK "service de fin de session installé : ${spath}"
	_INFO "exécution à la fin de session et à l'extinction, en tant que ${user}"
	return "${rc}"
}

timer_shutdown_disable() {
	local path="" spath="" dir="" need_root=0 rc=0 out="" sc=""
	path="$(_shutdown_unit_path)"
	spath="$(_session_unit_path)"
	dir="${path%/*}"
	if ! [[ -f ${path} ]] && ! _session_unit_installed; then
		_INFO "service d'extinction déjà absent"
		return 0
	fi
	if ((DRY_RUN == 1)); then
		_INFO "désactiverait et supprimerait ${path}"
		return 0
	fi
	if ! _confirm "Retirer les services d'extinction (root) ?"; then
		_INFO "annulé — service inchangé"
		return 3
	fi
	# Service de fin de session (utilisateur, sans root).
	if _session_unit_installed; then
		"${SYSTEMCTL_BIN}" --user disable "${SESSION_UNIT_NAME}" 2>/dev/null || _WARN "désactivation du service de session incomplète"
		rm -f -- "${spath}" 2>/dev/null || _WARN "suppression du service de session impossible"
		"${SYSTEMCTL_BIN}" --user daemon-reload 2>/dev/null || rc=1
	fi
	if [[ ! -f ${path} ]]; then
		_OK "service d'extinction retiré"
		return "${rc}"
	fi
	if [[ ! -w ${dir} ]] || [[ ${PRIVATE_BACKUP_FORCE_ROOT:-0} == 1 ]]; then
		need_root=1
	fi
	if ((need_root == 1)); then
		if ! command -v pkexec >/dev/null 2>&1; then
			_ERR "pkexec introuvable : retire ${path} en root puis « systemctl disable ${SYSTEM_UNIT_NAME} »"
			return 1
		fi
		# Une seule élévation : disable + suppression + daemon-reload.
		sc="$(command -v "${SYSTEMCTL_BIN}")" || sc="/usr/bin/systemctl"
		# shellcheck disable=SC2016 # $1… sont lus par le bash lancé via pkexec
		if ! out="$(pkexec /bin/bash -c '
			set -u
			"$1" disable "$2" 2>/dev/null || true
			rm -f -- "$3" || exit 1
			"$1" daemon-reload || exit 1
		' _ "${sc}" "${SYSTEM_UNIT_NAME}" "${path}" 2>&1)"; then
			_ERR "retrait du service refusé ou impossible"
			[[ -n ${out} ]] && printf '%s\n' "${out}" >&2
			return 1
		fi
	else
		"${SYSTEMCTL_BIN}" disable "${SYSTEM_UNIT_NAME}" 2>/dev/null || _WARN "désactivation incomplète"
		if ! rm -f -- "${path}"; then
			_ERR "suppression impossible : ${path}"
			return 1
		fi
		"${SYSTEMCTL_BIN}" daemon-reload 2>/dev/null || rc=1
	fi
	_OK "service d'extinction retiré"
	local diru="" file="" name=""
	diru="$(_timer_unit_dir)"
	local reste=0
	for file in "${diru}/${SCRIPTNAME}"@*.timer; do
		[[ -f ${file} ]] || continue
		name="${file##*/}"
		name="${name#"${SCRIPTNAME}"@}"
		name="${name%.timer}"
		_timer_extinction "${name}" && reste=$((reste + 1))
	done
	if ((reste > 0)); then
		_WARN "${reste} planification(s) utilisent encore le mode extinction"
	fi
	return "${rc}"
}

# Réécrit le template de service (chemin du script, config, réglages) sans
# toucher aux planifications. Utile après mise à jour de l'outil.
timer_sync() {
	local dir="" path="" cfg="" rc=0 syspath=""
	dir="$(_timer_unit_dir)"
	if ! compgen -G "${dir}/${SCRIPTNAME}@*.timer" >/dev/null; then
		_INFO "aucune planification à mettre à jour"
		return 0
	fi
	if ! _timer_need_systemd; then
		return 1
	fi
	if [[ -n ${CFG_FILE} ]]; then
		cfg="$(readlink -f -- "${CFG_FILE}" 2>/dev/null)" || cfg="${CFG_FILE}"
	fi
	path="${dir}/${SCRIPTNAME}@.service"
	if ((DRY_RUN == 1)); then
		_INFO "réécrirait ${path} (script, config, verrou, mode strict)"
		return 0
	fi
	if ! _timer_write_service "${cfg}"; then
		return 1
	fi
	if ! "${SYSTEMCTL_BIN}" --user daemon-reload 2>/dev/null; then
		_WARN "daemon-reload a échoué"
		rc=1
	fi
	_OK "service mis à jour : ${path}"
	_INFO "les planifications existantes sont conservées"
	if _session_unit_installed; then
		_session_unit_write || rc=1
		_INFO "service de fin de session mis à jour"
	fi
	if _shutdown_unit_installed; then
		syspath="$(_shutdown_unit_path)"
		local selfq=""
		selfq="$(_systemd_quote "${SELF_PATH}")" || selfq="${SELF_PATH//%/%%}"
		if ! grep -qF "${selfq}" "${syspath}" 2>/dev/null; then
			_WARN "le service d'extinction pointe vers un autre chemin — relance ${SCRIPTNAME} timer-shutdown-enable"
		fi
	fi
	return "${rc}"
}

timer_linger() {
	local st="" out="" user=""
	user="$(_timer_user)"
	st="$(_linger_state)"
	if [[ ${st} == "yes" ]]; then
		_INFO "linger déjà actif pour ${user}"
		return 0
	fi
	if ! command -v loginctl >/dev/null 2>&1; then
		_ERR "loginctl introuvable (paquet systemd)"
		return 1
	fi
	if ((DRY_RUN == 1)); then
		_INFO "exécuterait : pkexec loginctl enable-linger ${user}"
		return 0
	fi
	if ! command -v pkexec >/dev/null 2>&1; then
		_ERR "pkexec introuvable : exécute « loginctl enable-linger ${user} » en root"
		return 1
	fi
	if ! _confirm "Autoriser les timers à tourner sans session ouverte (root) ?"; then
		_INFO "annulé — linger inchangé"
		return 3
	fi
	if ! out="$(pkexec loginctl enable-linger "${user}" 2>&1)"; then
		_ERR "activation du linger refusée ou impossible"
		[[ -n ${out} ]] && printf '%s\n' "${out}" >&2
		return 1
	fi
	st="$(_linger_state)"
	if [[ ${st} == "yes" ]]; then
		_OK "linger activé : les timers tournent même session fermée"
		return 0
	fi
	_WARN "linger demandé mais état toujours « ${st} »"
	return 1
}

# =============================================================================
# PROFILS (écriture dans le fichier de configuration)
# =============================================================================

profile_add() {
	local name="${1:-}" src="${2:-}" cmd="${3:-}" excl="${4:-}" exists=0

	name="${name^^}"
	if ! _valid_profile_name "${name}"; then
		_ERR "nom de profil invalide : ${name} (lettres A-Z, chiffres, _, commence par une lettre)"
		return 2
	fi
	if ! _source_path_ok "${src}"; then
		_ERR "dossier invalide : ${src:-absent} (relatif à \$HOME, sans « .. » ni « . »)"
		return 2
	fi
	if [[ ${cmd} == *$'\n'* ]] || [[ ${cmd} == *$'\r'* ]] ||
		[[ ${excl} == *$'\n'* ]] || [[ ${excl} == *$'\r'* ]]; then
		_ERR "binaire ou exclusions sur plusieurs lignes — refuse"
		return 2
	fi
	[[ -e "${HOME}/${src}" ]] || _WARN "${HOME}/${src} n'existe pas encore"
	_known_profile "${name}" && exists=1

	SOURCES[${name}]="${src}"
	if [[ -n ${cmd} ]]; then
		COMMANDS[${name}]="${cmd}"
	else
		unset "COMMANDS[${name}]"
	fi
	if [[ -n ${excl} ]]; then
		EXCLUDES[${name}]="${excl}"
	else
		unset "EXCLUDES[${name}]"
	fi

	if ! _config_save; then
		_ERR "${name} : modification NON enregistrée"
		return 1
	fi
	if ((exists == 1)); then
		_INFO "${name} : profil mis à jour (~/${src})"
	else
		_INFO "${name} : profil ajouté (~/${src})"
	fi
	return 0
}

profile_remove() {
	local name="${1:-}"
	name="${name^^}"
	if ! _known_profile "${name}"; then
		_ERR "profil inconnu : ${name}"
		return 2
	fi
	unset "SOURCES[${name}]" "COMMANDS[${name}]" "EXCLUDES[${name}]"
	if ! _config_save; then
		_ERR "${name} : modification NON enregistrée"
		return 1
	fi
	if _timer_exists "${name}"; then
		_WARN "sauvegarde automatique toujours active : ${SCRIPTNAME} timer-remove ${name}"
	fi
	_pending_clear "${name}"
	_WARN "${name} retiré ; ses archives restent sur le NAS (orphelines : delete_old --purge-orphans)"
	return 0
}

# =============================================================================
# CHIFFREMENT DES ARCHIVES EN CLAIR
# =============================================================================

# Chiffre un fichier vers un autre (pipeline executé dans _RUN).
_encrypt_file() {
	age --encrypt --recipient "${AGE_RECIPIENT}" < "${1}" > "${2}"
}

encrypt_archives() {
	local -a filtres=("${@}") cibles=()
	local -A filtre=()
	local f i group profile total=0 total_h="" free_kb="" need_kb="" cible="" part="" rc=0

	if [[ ${ENCRYPT} != "age" ]]; then
		_ERR "chiffrement inactif : configure ENCRYPT=age et AGE_IDENTITY"
		return 2
	fi
	_check_nas_rw || return 1
	_check_nas_perms
	_collect_archives

	for f in "${filtres[@]}"; do
		f="${f^^}"
		if ! _known_profile "${f}"; then
			_ERR "profil inconnu : ${f} (voir « show »)"
			return 2
		fi
		filtre[${f}]=1
	done

	for i in "${!ARCH_PATH[@]}"; do
		f="${ARCH_PATH[${i}]}"
		case "${f}" in
		*.age) continue ;;
		*.tar.gz) ;;
		*) continue ;;
		esac
		group="${ARCH_GROUP[${i}]}"
		profile="$(_group_profile "${group}")"
		if ((${#filtres[@]} > 0)) && [[ -z "${filtre[${profile}]:-}" ]]; then
			continue
		fi
		cibles+=("${f}")
		total=$((total + ARCH_SIZE[i]))
	done

	if ((${#cibles[@]} == 0)); then
		if ((${#filtres[@]} > 0)); then
			_INFO "aucune archive en clair pour : ${filtres[*]}"
		elif ((${#ARCH_PATH[@]} == 0)); then
			_INFO "aucune archive sur le stockage"
		else
			local na=${#ARCH_PATH[@]} ca=""
			ca="$(_count "${na}" archive archives)"
			_INFO "toutes les archives sont déjà chiffrées (${ca})"
		fi
		return 0
	fi
	total_h="$(_human_size "${total}")"

	# De la place pour la copie chiffrée avant de retirer l'original.
	need_kb=$((total / 1024 + 262144))
	free_kb="$(_free_kb)"
	if ((free_kb > 0)) && ((free_kb < need_kb)); then
		local free_h="" need_h=""
		free_h="$(_human_size $((free_kb * 1024)))"
		need_h="$(_human_size $((need_kb * 1024)))"
		_ERR "espace insuffisant : ${free_h} libres, ~${need_h} nécessaires"
		return 1
	fi

	for f in "${cibles[@]}"; do
		_INFO "à chiffrer : ${f##*/}"
	done
	local nc=${#cibles[@]} cc=""
	cc="$(_count "${nc}" archive archives)"
	printf ' %b·%b %s, %s\n' "${C_CYAN}" "${C_RESET}" "${cc}" "${total_h}"

	if ((DRY_RUN == 1)); then
		_INFO "--dry-run : rien n'a été chiffré"
		return 0
	fi
	local nc=${#cibles[@]} cc=""
	cc="$(_count "${nc}" archive archives)"
	if ! _confirm "Chiffrer ${cc} et supprimer les originaux en clair ?"; then
		_INFO "annulé — rien n'a été modifié"
		return 0
	fi

	for f in "${cibles[@]}"; do
		cible="${f}.age"
		if [[ -e ${cible} ]]; then
			_WARN "${cible##*/} existe déjà — ignorée"
			continue
		fi
		part="${cible}.part"
		PART_FILE="${part}"
		if ! _RUN "Chiffrement de ${f##*/}" _encrypt_file "${f}" "${part}"; then
			_show_log_tail
			_cleanup_parts
			rc=1
			continue
		fi
		if ((VERIFY == 1)); then
			if ! _RUN "Vérification de ${part##*/}" _verify_archive "${part}"; then
				_cleanup_parts
				_ERR "${f##*/} : archive chiffrée invalide — original conservé"
				rc=1
				continue
			fi
		fi
		chmod 600 -- "${part}" 2>/dev/null
		PART_FILE=""
		if ! mv -f -- "${part}" "${cible}"; then
			_cleanup_parts
			_ERR "${cible##*/} : renommage impossible — original conservé"
			rc=1
			continue
		fi
		if ! rm -f -- "${f}"; then
			_ERR "${f##*/} : original non supprimé (les deux versions coexistent)"
			rc=1
			continue
		fi
		_log "chiffré : ${cible} ; original supprimé : ${f}"
		_INFO "${cible##*/} chiffrée, original supprimé"
	done
	return "${rc}"
}

# =============================================================================
# DELETE_OLD
# =============================================================================

delete_old() {
	_check_nas_rw || return 1
	_check_nas_perms
	_collect_archives

	if ((${#ARCH_PATH[@]} == 0)); then
		_INFO "aucune archive à traiter"
		return 0
	fi

	local -a groupes=()
	local -A seen=()
	local i group
	for i in "${!ARCH_GROUP[@]}"; do
		group="${ARCH_GROUP[${i}]}"
		if [[ -z "${seen[${group}]:-}" ]]; then
			seen[${group}]=1
			groupes+=("${group}")
		fi
	done

	local -a del_paths=() del_reasons=()
	local rc=0 kept_total=0 orphan_count=0
	local profil is_snapshot label

	if ((VERIFY == 1)); then
		_INFO "vérification des archives à conserver (relecture complète ; « --no-verify » pour l'éviter)"
	fi

	for group in "${groupes[@]}"; do
		profil="$(_group_profile "${group}")"
		is_snapshot=0
		[[ ${group} == "${SNAPSHOT_SUBDIR}/"* ]] && is_snapshot=1

		local -a paths=()
		for i in "${!ARCH_GROUP[@]}"; do
			[[ ${ARCH_GROUP[${i}]} == "${group}" ]] && paths+=("${ARCH_PATH[${i}]}")
		done

		# Profil absent de la configuration : ignoré par défaut, inclus dans la
		# rétention avec --orphans, supprimé en totalité avec --purge-orphans.
		if ((is_snapshot == 0)) && ! _known_profile "${profil}"; then
			if ((PURGE_ORPHANS == 1)); then
				for i in "${!paths[@]}"; do
					del_paths+=("${paths[${i}]}")
					del_reasons+=("orphelin")
				done
				orphan_count=$((orphan_count + ${#paths[@]}))
				continue
			fi
			if ((ORPHANS == 0)); then
				continue
			fi
		fi

		local -a g_keep=() g_del=() g_reason=()
		local n_keep=0 ok=0 p vrc
		for p in "${paths[@]}"; do
			if ((n_keep >= KEEP)); then
				g_del+=("${p}")
				g_reason+=("ancienne")
				continue
			fi
			if ((VERIFY == 1)); then
				# La vérification relit toute l'archive (long sur un gros
				# profil) : on l'affiche pour ne pas donner l'impression
				# d'un blocage. --no-verify court-circuite cette étape.
				_RUN "Vérification de ${p##*/}" _verify_archive "${p}"
				vrc=$?
			else
				[[ -s ${p} ]] && vrc=0 || vrc=1
			fi
			case "${vrc}" in
			0) g_keep+=("${p}"); n_keep=$((n_keep + 1)); ok=1 ;;
			1) g_del+=("${p}"); g_reason+=("corrompue") ;;
			*)
				# Clé indisponible : on ne juge pas, on ne supprime pas.
				g_keep+=("${p}")
				label="$(_group_label "${group}")"
				_WARN "${label} : ${p##*/} non vérifiable — conservée"
				;;
			esac
		done

		if ((ok == 0)); then
			label="$(_group_label "${group}")"
			_WARN "${label} : aucune archive vérifiée — rien supprimé pour ce profil"
			continue
		fi

		if ((${#g_keep[@]} > 0)); then
			local k
			for k in "${g_keep[@]}"; do
				_log "rétention ${group} : conserve ${k##*/}"
			done
		fi
		kept_total=$((kept_total + ${#g_keep[@]}))
		if ((${#g_del[@]} > 0)); then
			local j verb="supprime"
			((DRY_RUN == 1)) && verb="supprimerait"
			for j in "${!g_del[@]}"; do
				_log "rétention ${group} : ${verb} ${g_del[${j}]##*/} (${g_reason[${j}]})"
			done
			del_paths+=("${g_del[@]}")
			del_reasons+=("${g_reason[@]}")
		fi
	done

	if ((${#del_paths[@]} == 0)); then
		if ((PURGE_ORPHANS == 1)) && ((orphan_count == 0)); then
			_INFO "aucun profil orphelin à purger"
		fi
		local ck=""
		ck="$(_count "${kept_total}" conservée conservées)"
		_INFO "rien à supprimer (rétention : ${KEEP} par groupe, ${ck})"
		return "${rc}"
	fi

	if ((PURGE_ORPHANS == 1)) && ((orphan_count == 0)); then
		_INFO "aucun profil orphelin ; seules les archives excédentaires sont proposées"
	fi
	printf '\n%bSuppression proposée%b (rétention : %d par groupe)\n' "${C_BOLD}" "${C_RESET}" "${KEEP}"
	local total_bytes=0 fsize size_h name
	for i in "${!del_paths[@]}"; do
		fsize="$(_file_size "${del_paths[${i}]}")"
		total_bytes=$((total_bytes + fsize))
		size_h="$(_human_size "${fsize}")"
		name="${del_paths[${i}]##*/}"
		printf '  %b-%b %-60s %-12s %10s\n' \
			"${C_RED}" "${C_RESET}" "${name}" "(${del_reasons[${i}]})" "${size_h}"
	done
	size_h="$(_human_size "${total_bytes}")"
	local ck=""
	ck="$(_count "${kept_total}" conservée conservées)"
	printf '  %b→ %s libérables, %s%b\n' "${C_DIM}" "${size_h}" "${ck}" "${C_RESET}"

	if ((DRY_RUN == 1)); then
		_INFO "--dry-run : rien n'a été supprimé"
		return "${rc}"
	fi

	local nd=${#del_paths[@]} cd=""
	cd="$(_count "${nd}" fichier fichiers)"
	if ! _confirm "Supprimer définitivement ${cd} ?"; then
		_INFO "annulé — rien n'a été supprimé"
		return 0
	fi

	local deleted=0
	for i in "${!del_paths[@]}"; do
		name="${del_paths[${i}]##*/}"
		if _RUN "Suppression de ${name}" rm -f -- "${del_paths[${i}]}"; then
			deleted=$((deleted + 1))
		else
			rc=1
		fi
	done

	local cd=""
	cd="$(_count "${deleted}" "archive supprimée" "archives supprimées")"
	printf '\n%b%s%b\n' "${C_GREEN}" "${cd}" "${C_RESET}"
	if ((deleted != ${#del_paths[@]})); then
		rc=1
	fi
	return "${rc}"
}

# =============================================================================
# POINT D'ENTRÉE
# =============================================================================

main() {
	local -a raw_args=("${@}")
	# La commande est le premier argument qui n'est pas une option ; les
	# options peuvent donc la précéder (ex. « --config F show »).
	local cmd=""
	if (($# > 0)) && [[ ${1} != -* ]]; then
		cmd="${1}"
		shift
	fi

	local -a positional=()
	while (($# > 0)); do
		case "${1}" in
		--dry-run)     DRY_RUN=1 ;;
		--yes|-y)      ASSUME_YES=1 ;;
		--no-verify)   VERIFY=0 ;;
		--orphans)       ORPHANS=1 ;;
		--purge-orphans) PURGE_ORPHANS=1 ;;
		--delete-logs)   DELETE_LOGS=1 ;;
		--porcelain)     PORCELAIN=1 ;;
		--extinction)    EXTINCTION_SET=1; EXTINCTION_VAL=1 ;;
		--no-extinction) EXTINCTION_SET=1; EXTINCTION_VAL=0 ;;
		--shutdown)      SHUTDOWN_RUN=1 ;;
		--archive)       shift; ARCHIVE_FILE="${1:-}" ;;
		--plan)          shift; PLAN_FILE="${1:-}" ;;
		--plan=*)        PLAN_FILE="${1#*=}" ;;
		--apply-plan)    shift; APPLY_PLAN="${1:-}" ;;
		--apply-plan=*)  APPLY_PLAN="${1#*=}" ;;
		--archive=*)     ARCHIVE_FILE="${1#*=}" ;;
		--config)        shift ;;
		--config=*)      ;;
		--snapshot)    SNAPSHOT_MODE="yes" ;;
		--no-snapshot) SNAPSHOT_MODE="no" ;;
		--keep)        shift; KEEP="${1:-}" ;;
		--keep=*)      KEEP="${1#*=}" ;;
		--version)     printf '%s %s\n' "${SCRIPTNAME}" "${VER}"; return 0 ;;
		--help|-h)     _usage; return 0 ;;
		--)
			shift
			while (($# > 0)); do
				positional+=("${1}")
				shift
			done
			break
			;;
		-*)
			_ERR "option inconnue : ${1}"
			return 2
			;;
		*) positional+=("${1}") ;;
		esac
		shift
	done

	if [[ -z ${cmd} ]] && ((${#positional[@]} > 0)); then
		cmd="${positional[0]}"
		positional=("${positional[@]:1}")
	fi

	if [[ ! ${KEEP} =~ ^[0-9]+$ ]] || ((KEEP < 1)); then
		_ERR "--keep attend un entier positif (reçu : ${KEEP})"
		return 2
	fi

	case "${cmd}" in
	backup|restore|rollback|delete_old|show|list|verify|delete-archive|encrypt-archives|adopt-orphans|timer-add|timer-remove|timer-list|timer-run|timer-sync|timer-linger|timer-shutdown-enable|timer-shutdown-disable|backup-pending|profile-add|profile-remove|config-set|config-path|config-check|help|"") ;;
	*)
		_ERR "commande inconnue : ${cmd}"
		printf '\n' >&2
		_usage >&2
		return 2
		;;
	esac

	if ((SHUTDOWN_RUN == 1)) && [[ ${cmd} != "backup-pending" ]]; then
		_ERR "--shutdown ne s'utilise qu'avec backup-pending"
		return 2
	fi
	if ((EXTINCTION_SET == 1)) && [[ ${cmd} != "timer-add" ]]; then
		_ERR "--extinction/--no-extinction ne s'utilisent qu'avec timer-add"
		return 2
	fi

	# --delete-logs est une action autonome.
	if ((DELETE_LOGS == 1)); then
		if [[ -n ${cmd} ]]; then
			_ERR "--delete-logs s'utilise seul (sans commande)"
			return 2
		fi
		_need find stat awk rm || return 1
		_acquire_lock || return 1
		delete_logs
		return "${?}"
	fi

	if [[ -z ${cmd} ]]; then
		_usage >&2
		return 2
	fi
	if [[ ${cmd} == "help" ]]; then
		_usage
		return 0
	fi

	# `config-path` sert aux scripts : sortie pure (bannière/log sur stderr).
	[[ ${cmd} == "config-path" ]] && PORCELAIN=1

	_need tar find sort awk stat findmnt date timeout du df pgrep readlink || return 1
	case "${ENCRYPT}" in
	"") ;;
	age)
		_need age || return 1
		if [[ -z ${AGE_IDENTITY} ]]; then
			_ERR "ENCRYPT=age mais AGE_IDENTITY est vide"
			return 2
		fi
		;;
	*)
		_ERR "ENCRYPT doit valoir \"\" ou age (reçu : ${ENCRYPT})"
		return 2
		;;
	esac

	RUN_DATE="$(date +%Y-%m-%d-%H.%M.%S)" || RUN_DATE=""
	if [[ -z ${RUN_DATE} ]]; then
		_ERR "date système illisible"
		return 1
	fi

	_enable_colors
	_init_log

	# Clé publique déduite de la clé privée (journalisée).
	if [[ ${ENCRYPT} == "age" ]]; then
		_age_recipient || return 1
	fi

	# Les commandes de consultation (`show`, `list`, `config-path`…) sont
	# appelées en boucle par la TUI : elles ne créent pas de journal.
	case "${cmd}" in
	backup|restore|rollback|delete_old|delete-archive|encrypt-archives|adopt-orphans|timer-add|timer-remove|timer-run|timer-sync|timer-linger|timer-shutdown-enable|timer-shutdown-disable|backup-pending|verify|profile-add|profile-remove|config-set) LOG_RUN=1 ;;
	*) LOG_RUN=0 ;;
	esac
	if ((LOG_RUN == 1)); then
		_log "=== ${SCRIPTNAME} ${VER} — ${cmd} ==="
		_log "arguments : ${raw_args[*]}"
		_log "config    : ${CFG_FILE:-aucun (valeurs par défaut)}"
		_log "stockage  : ${NAS}/${BACKUP_SUBDIR}"
		_log "options   : dry-run=${DRY_RUN} verify=${VERIFY} keep=${KEEP} snapshot=${SNAPSHOT_MODE} encrypt=${ENCRYPT:-aucun}"
	fi

	trap '_on_exit' EXIT
	trap '_on_signal INT' INT
	trap '_on_signal TERM' TERM
	trap '_on_signal HUP' HUP

	# Verrou : une seule instance mutante à la fois (deux backups simultanés
	# pourraient produire deux archives concurrentes, et delete_old pourrait
	# supprimer une archive en cours d'écriture).
	case "${cmd}" in
	backup|backup-pending|restore|rollback|delete_old|delete-archive|encrypt-archives|adopt-orphans|profile-add|profile-remove|config-set)
		needs_lock=1
		;;
	*) needs_lock=0 ;;
	esac
	if ((needs_lock == 1)); then
		_acquire_lock || return 1
	fi

	if ((PORCELAIN == 1)); then
		printf '\n%b%s%b %bv%s%b\n' \
			"${C_CYAN}" "${SCRIPTNAME}" "${C_RESET}" "${C_YELLOW}" "${VER}" "${C_RESET}" >&2
	else
		printf '\n%b%s%b %bv%s%b\n' \
			"${C_CYAN}" "${SCRIPTNAME}" "${C_RESET}" "${C_YELLOW}" "${VER}" "${C_RESET}"
	fi

	local rc=0
	case "${cmd}" in
	backup)
		if ((${#positional[@]} > 0)); then
			backup "${positional[@]}"
		else
			backup
		fi
		rc=$?
		;;
	restore)
		restore "${positional[0]:-}"
		rc=$?
		;;
	rollback)
		rollback "${positional[0]:-}"
		rc=$?
		;;
	delete_old)
		delete_old
		rc=$?
		;;
	verify)
		verify "${positional[0]:-}"
		rc=$?
		;;
	delete-archive)
		delete_archive "${positional[@]}"
		rc=$?
		;;
	encrypt-archives)
		encrypt_archives "${positional[@]}"
		rc=$?
		;;
	adopt-orphans)
		adopt_orphans "${positional[@]}"
		rc=$?
		;;
	timer-add)
		timer_add "${positional[0]:-}" "${positional[1]:-}" "${positional[2]:-}" "${positional[3]:-}"
		rc=$?
		;;
	timer-remove)
		timer_remove "${positional[0]:-}"
		rc=$?
		;;
	timer-list)
		timer_list
		rc=$?
		;;
	timer-run)
		timer_run "${positional[0]:-}"
		rc=$?
		;;
	timer-sync)
		timer_sync
		rc=$?
		;;
	timer-shutdown-enable)
		timer_shutdown_enable
		rc=$?
		;;
	timer-shutdown-disable)
		timer_shutdown_disable
		rc=$?
		;;
	backup-pending)
		backup_pending
		rc=$?
		;;
	timer-linger)
		timer_linger
		rc=$?
		;;
	profile-add)
		profile_add "${positional[0]:-}" "${positional[1]:-}" "${positional[2]:-}" "${positional[3]:-}"
		rc=$?
		;;
	profile-remove)
		profile_remove "${positional[0]:-}"
		rc=$?
		;;
	config-set)
		config_set "${positional[@]}"
		rc=$?
		;;
	config-path)
		printf '%s\n' "${CFG_FILE}"
		rc=0
		;;
	config-check)
		if _config_paths_check; then
			_INFO "configuration valide : ${CFG_FILE}"
			_config_conflicts
			rc=0
		else
			rc=2
		fi
		;;
	show)
		show
		rc=$?
		;;
	list)
		list "${positional[0]:-}"
		rc=$?
		;;
	*) ;;
	esac
	if ((LOG_RUN == 1)); then
		_log "fin : rc=${rc}"
	fi
	return "${rc}"
}

# =============================================================================
# AMORÇAGE
# =============================================================================
# Le fichier de configuration est chargé ICI, au niveau global : un `source`
# dans une fonction rendrait locaux les `declare` du fichier et ses tableaux
# seraient perdus. `help` et `--version` fonctionnent sans configuration.

_enable_colors

_cfg_required=0
_cfg_loaded=0
if _cfg_needed "${@}"; then
	_cfg_required=1
	CFG_FILE="$(_config_path "${@}")"
	_cfg_rc=$?
	if ((_cfg_rc != 0)); then
		_ERR "option --config sans fichier"
		exit 2
	fi
	if [[ -z ${CFG_FILE} ]]; then
		_config_not_found
		exit 2
	fi
	if ! [[ -r ${CFG_FILE} ]]; then
		_ERR "fichier de configuration illisible : ${CFG_FILE}"
		exit 2
	fi
	_config_perms_warn "${CFG_FILE}"

	set +u
	# shellcheck source=/dev/null
	source "${CFG_FILE}"
	_cfg_rc=$?
	set -u
	if ((_cfg_rc != 0)); then
		_ERR "erreur d'exécution dans ${CFG_FILE} (code ${_cfg_rc})"
		exit 2
	fi
	_cfg_loaded=1
else
	# `help`/`--version` : configuration optionnelle, chargée si possible pour
	# afficher les vraies valeurs (aucune erreur bloquante).
	CFG_FILE="$(_config_path "${@}" 2>/dev/null)" || CFG_FILE=""
	if [[ -n ${CFG_FILE} ]] && [[ -r ${CFG_FILE} ]]; then
		set +u
		# shellcheck source=/dev/null
		source "${CFG_FILE}" >/dev/null 2>&1 || true
		set -u
		_cfg_loaded=1
	fi
fi

_config_defaults

if ((_cfg_required == 1)); then
	_config_validate || exit 2
fi

main "${@}"
