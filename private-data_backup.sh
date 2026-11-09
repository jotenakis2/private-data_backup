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
#   3. private_data_backup.conf à côté du script (liens symboliques résolus)
#   4. ${XDG_CONFIG_HOME:-$HOME/.config}/private-data_backup/config
#
# Toute variable absente du fichier retombe sur `_config_defaults`.

readonly VER="1.3"
SCRIPTNAME="${0##*/}"
SCRIPTNAME="${SCRIPTNAME%.sh}"
readonly SCRIPTNAME

readonly CONFIG_BASENAME="private_data_backup.conf"
readonly SNAPSHOT_SUBDIR="pre-restore"

# Valeurs de repli (surchargées par le fichier de configuration).
NAS=""
BACKUP_SUBDIR=""
KEEP_DEFAULT=1
VERIFY_DEFAULT=1
SNAPSHOT_DEFAULT="auto"
SNAPSHOT_MAX_MB=512
NAS_TIMEOUT=20
ENCRYPT=""
GPG_RECIPIENT=""
AGE_RECIPIENT=""

# Tableaux remplis par le fichier de configuration. Déclarés ici (et non dans
# le fichier) pour qu'il puisse faire de simples affectations.
declare -A SOURCES=()
declare -A COMMANDS=()
declare -A SERVICES=()
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
SERVICES_STOPPED=()
RUN_DATE=""
NAS_MOUNT=""
FAILURES=0
INTERRUPTED=0
LOG_RUN=0

DRY_RUN=0
ASSUME_YES=0
VERIFY=1
KEEP=1
ORPHANS=0
PURGE_ORPHANS=0
PORCELAIN=0
ARCHIVE_FILE=""
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
		help|--help|-h|-help|--version|-V) return 1 ;;
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
	: "${GPG_RECIPIENT:=}"
	: "${AGE_RECIPIENT:=}"

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
	if [[ -n "${PRIVATE_BACKUP_GPG_RECIPIENT:-}" ]]; then
		GPG_RECIPIENT="${PRIVATE_BACKUP_GPG_RECIPIENT}"
	fi
	if [[ -n "${PRIVATE_BACKUP_AGE_RECIPIENT:-}" ]]; then
		AGE_RECIPIENT="${PRIVATE_BACKUP_AGE_RECIPIENT}"
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
		case "${SOURCES[${k}]}" in
		"")
			_ERR "SOURCES[${k}] est vide"
			errs=1
			;;
		/*)
			_ERR "SOURCES[${k}] doit être relatif à \$HOME (reçu : ${SOURCES[${k}]})"
			errs=1
			;;
		*) ;;
		esac
	done

	for k in "${!COMMANDS[@]}"; do
		_known_profile "${k}" || _WARN "COMMANDS[${k}] : profil absent de SOURCES (ignoré)"
	done
	for k in "${!SERVICES[@]}"; do
		_known_profile "${k}" || _WARN "SERVICES[${k}] : profil absent de SOURCES (ignoré)"
	done
	for k in "${!EXCLUDES[@]}"; do
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
	""|gpg|age) ;;
	*)
		_ERR "ENCRYPT doit valoir \"\", gpg ou age (reçu : ${ENCRYPT})"
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

# Contenu du bloc NAME (SOURCES, COMMANDS, SERVICES, EXCLUDES) trié par clé.
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
		_ERR "bloc « ${name} » introuvable dans ${file}"
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
	for block in SOURCES COMMANDS SERVICES EXCLUDES; do
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

_restart_services() {
	local unit
	((${#SERVICES_STOPPED[@]} == 0)) && return 0
	for unit in "${SERVICES_STOPPED[@]}"; do
		if systemctl --user start "${unit}" 2>/dev/null; then
			_INFO "service ${unit} redémarré"
		else
			_WARN "échec du redémarrage de ${unit} — à relancer manuellement"
		fi
	done
	SERVICES_STOPPED=()
	return 0
}

_on_exit() {
	_cleanup_parts
	_restart_services
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
	_restart_services
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
	gpg) printf '%s' ".gpg" ;;
	age) printf '%s' ".age" ;;
	*)   printf '%s' "" ;;
	esac
}

_archive_is_encrypted() {
	case "${1}" in
	*.gpg|*.gpg.part|*.age|*.age.part) return 0 ;;
	*) return 1 ;;
	esac
}

_encrypt() {
	case "${ENCRYPT}" in
	gpg) gpg --batch --yes --no-tty --trust-model always --encrypt --recipient "${GPG_RECIPIENT}" ;;
	age) age --encrypt --recipient "${AGE_RECIPIENT}" ;;
	*)   cat ;;
	esac
}

_decrypt() {
	case "${1}" in
	*.gpg|*.gpg.part) gpg --batch --quiet --no-tty --decrypt -- "${1}" ;;
	*.age|*.age.part) age --decrypt -- "${1}" ;;
	*) cat -- "${1}" ;;
	esac
}

# Analyse un nom d'archive ; renseigne ARCH_PROFILE et ARCH_DATEKEY
# (AAAAMMJJHHMMSS). Reconnaît le format actuel et l'ancien (JJ_MM_AAAA).
_parse_archive() {
	local base="${1##*/}"
	ARCH_PROFILE=""
	ARCH_DATEKEY=""

	if [[ ${base} =~ ^(.+)_([0-9]{4})-([0-9]{2})-([0-9]{2})-([0-9]{2})\.([0-9]{2})\.([0-9]{2})\.tar\.gz(\.gpg|\.age)?$ ]]; then
		ARCH_PROFILE="${BASH_REMATCH[1]}"
		ARCH_DATEKEY="${BASH_REMATCH[2]}${BASH_REMATCH[3]}${BASH_REMATCH[4]}${BASH_REMATCH[5]}${BASH_REMATCH[6]}${BASH_REMATCH[7]}"
		return 0
	fi
	if [[ ${base} =~ ^(.+)_([0-9]{2})_([0-9]{2})_([0-9]{4})-([0-9]{2})\.([0-9]{2})\.([0-9]{2})\.tar\.gz(\.gpg|\.age)?$ ]]; then
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
			\( -name '*.tar.gz' -o -name '*.tar.gz.gpg' -o -name '*.tar.gz.age' \) \
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
		if ! _decrypt "${f}" >/dev/null 2>&1; then
			return 2
		fi
		return 1
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

_known_profile() {
	[[ -n "${SOURCES[${1}]:-}" ]]
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
	cat <<EOF
${C_BOLD}${SCRIPTNAME}${C_RESET} v${VER} — sauvegarde/restauration de données privées

Usage :
  ${C_GREEN}${0} backup${C_RESET}  [PROFIL...] [--dry-run] [--no-verify]
  ${C_GREEN}${0} restore${C_RESET} [PROFIL]    [--yes] [--dry-run] [--snapshot|--no-snapshot]
  ${C_GREEN}${0} rollback${C_RESET} [PROFIL]   [--yes] [--dry-run]   (instantané pré-restauration)
  ${C_GREEN}${0} verify${C_RESET} FICHIER
  ${C_GREEN}${0} delete-archive${C_RESET} FICHIER [--yes] [--dry-run]
  ${C_GREEN}${0} delete_old${C_RESET} [--keep N] [--orphans|--purge-orphans] [--dry-run] [--yes]
  ${C_GREEN}${0} show
  ${C_GREEN}${0} list${C_RESET}    [PROFIL]
  ${C_GREEN}${0} profile-add${C_RESET} NOM DOSSIER [BINAIRE] [EXCLUSIONS]
  ${C_GREEN}${0} profile-remove${C_RESET} NOM
  ${C_GREEN}${0} config-set${C_RESET} CLE=VALEUR [CLE=VALEUR...]   (NAS, rétention, chiffrement…)
  ${C_GREEN}${0} config-path | config-check
  ${C_GREEN}${0} help | --version

Options :
  --dry-run      n'écrit et n'efface rien : affiche ce qui serait fait
  --yes, -y      ne pas demander de confirmation
  --no-verify    ne pas vérifier l'intégrité des archives (backup, delete_old)
  --keep N       archives conservées par profil (delete_old, défaut ${KEEP_DEFAULT})
  --orphans      inclure les profils hors configuration dans la rétention (delete_old)
  --purge-orphans supprimer toutes les archives des profils hors configuration
  --snapshot     forcer l'instantané avant restauration
  --no-snapshot  interdire l'instantané avant restauration
  --porcelain    sortie tabulée (interfaces) pour show et list
  --archive FILE restaurer cette archive précise (avec restore)
  --config FILE  fichier de configuration (défaut : ./${CONFIG_BASENAME}
                 ou ${XDG_CONFIG_HOME:-${HOME}/.config}/${SCRIPTNAME}/config)

Configuration : ${CFG_FILE:-aucune (charge les valeurs par défaut)}
Stockage      : ${NAS_MOUNT:-${NAS}/${BACKUP_SUBDIR}}
Secrets  : archives et logs 0600, dossiers 0700 (umask 077)
EOF
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
	printf '%-*s  %-*s  %-*s  %-*s  %s\n' \
		"${w_prof}" "Profil" "${w_src}" "Dossier" "${w_cmd}" "Contrôle" "${w_arch}" "Dernière archive" "Taille"
	printf '%s  %s  %s  %s  %s\n' "${d_prof}" "${d_src}" "${d_cmd}" "${d_arch}" "${d_size}"

	local when size_h
	for profil in "${profils[@]}"; do
		if _latest_archive "${profil}"; then
			when="${LATEST_PATH##*/}"
			size_h="$(_human_size "${LATEST_SIZE}")"
			printf '%-*s  %-*s  %-*s  %-*s  %s\n' \
				"${w_prof}" "${profil}" \
				"${w_src}" "${SOURCES[${profil}]}" \
				"${w_cmd}" "${COMMANDS[${profil}]:-}" \
				"${w_arch}" "${when}" "${size_h}"
		else
			printf '%-*s  %-*s  %-*s  %b(aucune)%b\n' \
				"${w_prof}" "${profil}" \
				"${w_src}" "${SOURCES[${profil}]}" \
				"${w_cmd}" "${COMMANDS[${profil}]:-}" \
				"${C_RED}" "${C_RESET}"
		fi
	done

	# Orphelins : mêmes colonnes, dossier = « (hors configuration) ».
	for profil in "${orphelins[@]}"; do
		if ! _latest_archive "${profil}"; then
			continue
		fi
		when="${LATEST_PATH##*/}"
		size_h="$(_human_size "${LATEST_SIZE}")"
		printf '%-*s  %b%s%b%s  %-*s  %-*s  %s\n' \
			"${w_prof}" "${profil}" \
			"${C_YELLOW}" "${hors_cfg}" "${C_RESET}" "${hors_pad}" \
			"${w_cmd}" "" \
			"${w_arch}" "${when}" "${size_h}"
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
	printf '\n%bContenu de %s%b : %d archive(s), %s' \
		"${C_BOLD}" "${NAS_MOUNT}" "${C_RESET}" "${#ARCH_PATH[@]}" "${total_h}"
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
	printf ' Instantanés avant restauration : %d fichier(s), %s\n\n' "${snap_count}" "${snap_h}"
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
	local d_prof d_when d_size d_file
	d_prof="$(_dashes 26)"
	d_when="$(_dashes 19)"
	d_size="$(_dashes 10)"
	d_file="$(_dashes 10)"

	# La première colonne marque les profils hors configuration d'une « * ».
	printf '\n  %-26s  %-19s  %10s  %s\n' "Profil" "Date" "Taille" "Fichier"
	printf '  %s  %s  %s  %s\n' "${d_prof}" "${d_when}" "${d_size}" "${d_file}"

	local i group label when size_h profil_group skipped=0 orphans=0 mark=""
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
		printf '%s %-26s  %-19s  %10s  %s\n' \
			"${mark}" "${label}" "${when}" "${size_h}" "${ARCH_PATH[${i}]##*/}"
	done
	printf '\n'
	if ((orphans > 0)); then
		printf ' %b* = profil hors configuration (absent de SOURCES) ; conservé, à purger avec%b\n' \
			"${C_DIM}" "${C_RESET}"
		printf ' %b    « delete_old --purge-orphans » (avec confirmation).%b\n' \
			"${C_DIM}" "${C_RESET}"
	fi
	if ((skipped > 0)); then
		_INFO "${skipped} archive(s) masquée(s) par le filtre"
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
	# du dernier maillon en échec : un gpg en échec (2) l'emporte donc.
	if ((rc == 1)); then
		_log "avertissement tar : fichier(s) modifié(s) pendant la lecture (archive conservée)"
		return 0
	fi
	((rc == 0)) && return 0
	return "${rc}"
}

_backup_one() {
	local profil="${1}" explicit="${2:-0}"
	local src cmd abs target part enc size_h bytes
	src="${SOURCES[${profil}]}"
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
		return 3
	fi

	if [[ -n "${SERVICES[${profil}]:-}" ]]; then
		if systemctl --user is-active --quiet "${SERVICES[${profil}]}" 2>/dev/null; then
			if systemctl --user stop "${SERVICES[${profil}]}"; then
				SERVICES_STOPPED+=("${SERVICES[${profil}]}")
			else
				_WARN "${profil} : arrêt de ${SERVICES[${profil}]} impossible"
			fi
		fi
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
		_verify_archive "${part}"
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
	_restart_services

	bytes="$(_file_size "${target}")"
	size_h="$(_human_size "${bytes}")"
	_log "profil ${profil} : terminé, ${bytes} octets (${size_h})"
	_INFO "${profil} : ${target##*/} (${size_h})"
	return 0
}

backup() {
	local -a wanted=("${@}")
	local -a profils=()
	local profil p explicit rc_one rc=0 skipped=0 done_count=0

	_check_nas_rw || return 1
	_check_nas_perms
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
		3) skipped=$((skipped + 1)) ;;
		*)
			rc=1
			FAILURES=$((FAILURES + 1))
			;;
		esac
	done

	_restart_services

	if ((DRY_RUN == 1)); then
		printf '\n%bBilan (dry-run)%b : %d serait sauvegardé(e), %d ignoré(e), %d en échec\n' \
			"${C_BOLD}" "${C_RESET}" "${done_count}" "${skipped}" "${FAILURES}"
		return "${rc}"
	fi

	printf '\n%bBilan%b : %d sauvegardée(s), %d ignorée(s), %d en échec\n' \
		"${C_BOLD}" "${C_RESET}" "${done_count}" "${skipped}" "${FAILURES}"
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
		_verify_archive "${target}"
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
		_log "avertissement tar : fichier(s) modifié(s) pendant l'extraction"
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

	_verify_archive "${RESTORE_FILE}"
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
		_verify_archive "${file}"
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
	_restart_services
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
		if ! _confirm "Restaurer TOUS les profils (écrasement de ~/Documents, ~/Projects, ~/.ssh…) ?"; then
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
	_verify_archive "${f}" 1
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
	local f="${1:-}" rc=0
	if [[ -z ${f} ]]; then
		_ERR "usage : delete-archive FICHIER"
		return 2
	fi
	_check_nas_rw || return 1
	_ensure_in_nas "${f}" || return 1
	if [[ ! -f ${f} ]]; then
		_ERR "fichier absent : ${f}"
		return 1
	fi
	if ((DRY_RUN == 1)); then
		_INFO "serait supprimé : ${f##*/}"
		return 0
	fi
	if ! _confirm "Supprimer définitivement ${f##*/} ?"; then
		_INFO "annulé — rien n'a été supprimé"
		return 0
	fi
	if ! _RUN "Suppression de ${f##*/}" rm -f -- "${f}"; then
		rc=1
	fi
	return "${rc}"
}

# =============================================================================
# PARAMÈTRES (écriture des valeurs simples du fichier de configuration)
# =============================================================================

# Clés modifiables par `config-set` (liste blanche).
_config_key_ok() {
	case "${1}" in
	NAS|BACKUP_SUBDIR|KEEP_DEFAULT|VERIFY_DEFAULT|SNAPSHOT_DEFAULT|SNAPSHOT_MAX_MB|NAS_TIMEOUT|LOG_FILES|ENCRYPT|GPG_RECIPIENT|AGE_RECIPIENT) return 0 ;;
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
# PROFILS (écriture dans le fichier de configuration)
# =============================================================================

profile_add() {
	local name="${1:-}" src="${2:-}" cmd="${3:-}" excl="${4:-}" exists=0

	name="${name^^}"
	if [[ ! ${name} =~ ^[A-Z][A-Z0-9_]*$ ]]; then
		_ERR "nom de profil invalide : ${name} (lettres A-Z, chiffres, _, commence par une lettre)"
		return 2
	fi
	if [[ -z ${src} ]]; then
		_ERR "dossier source manquant (relatif à \$HOME)"
		return 2
	fi
	if [[ ${src} == /* ]]; then
		_ERR "le dossier doit être relatif à \$HOME (reçu : ${src})"
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
	unset "SOURCES[${name}]" "COMMANDS[${name}]" "SERVICES[${name}]" "EXCLUDES[${name}]"
	if ! _config_save; then
		_ERR "${name} : modification NON enregistrée"
		return 1
	fi
	_WARN "${name} retiré ; ses archives restent sur le NAS (orphelines : delete_old --purge-orphans)"
	return 0
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
	local rc=0 kept_total=0
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
		_INFO "rien à supprimer (rétention : ${KEEP} par groupe, ${kept_total} conservée(s))"
		return "${rc}"
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
	printf '  %b→ %s libérables, %d conservée(s)%b\n' \
		"${C_DIM}" "${size_h}" "${kept_total}" "${C_RESET}"

	if ((DRY_RUN == 1)); then
		_INFO "--dry-run : rien n'a été supprimé"
		return "${rc}"
	fi

	if ! _confirm "Supprimer définitivement ces ${#del_paths[@]} fichier(s) ?"; then
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

	printf '\n%b%d archive(s) supprimée(s)%b\n' "${C_GREEN}" "${deleted}" "${C_RESET}"
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
		--porcelain)     PORCELAIN=1 ;;
		--archive)       shift; ARCHIVE_FILE="${1:-}" ;;
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
	backup|restore|rollback|delete_old|show|list|verify|delete-archive|profile-add|profile-remove|config-set|config-path|config-check|help|"") ;;
	*)
		_ERR "commande inconnue : ${cmd}"
		printf '\n' >&2
		_usage >&2
		return 2
		;;
	esac

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

	_need tar find sort awk stat findmnt date timeout du || return 1
	case "${ENCRYPT}" in
	"") ;;
	gpg)
		_need gpg || return 1
		if [[ -z ${GPG_RECIPIENT} ]]; then
			_ERR "ENCRYPT=gpg mais GPG_RECIPIENT est vide"
			return 2
		fi
		;;
	age)
		_need age || return 1
		if [[ -z ${AGE_RECIPIENT} ]]; then
			_ERR "ENCRYPT=age mais AGE_RECIPIENT est vide"
			return 2
		fi
		;;
	*)
		_ERR "ENCRYPT doit valoir \"\", gpg ou age (reçu : ${ENCRYPT})"
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

	# Les commandes de consultation (`show`, `list`, `config-path`…) sont
	# appelées en boucle par la TUI : elles ne créent pas de journal.
	case "${cmd}" in
	backup|restore|rollback|delete_old|delete-archive|verify|profile-add|profile-remove|config-set) LOG_RUN=1 ;;
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
	if [[ ${cmd} == "backup" ]] || [[ ${cmd} == "restore" ]] || [[ ${cmd} == "delete_old" ]]; then
		_need flock || return 1
		local lock_file="${XDG_RUNTIME_DIR:-/tmp}/${SCRIPTNAME}.${UID}.lock"
		if ! exec 9>"${lock_file}"; then
			_ERR "impossible d'ouvrir le verrou ${lock_file}"
			return 1
		fi
		if ! flock -n 9; then
			_ERR "une autre instance de ${SCRIPTNAME} est déjà en cours (${lock_file})"
			return 1
		fi
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
		delete_archive "${positional[0]:-}"
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
		_INFO "configuration valide : ${CFG_FILE}"
		rc=0
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

_cfg_loaded=0
if _cfg_needed "${@}"; then
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
fi

_config_defaults

if ((_cfg_loaded == 1)); then
	_config_validate || exit 2
fi

main "${@}"
