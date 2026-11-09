#!/usr/bin/env bash
# shellcheck enable=all
# =============================================================================
# private-data_backup-tui.sh — interface texte (gum) pour private-data_backup.sh
#
# Périmètre : sauvegarder, restaurer (archive ou instantané), agir sur les
# archives (vérifier, supprimer, rétention, purge des orphelins) et gérer les
# profils (ajout/modification/suppression dans le fichier de configuration).
#
# Toute la logique (config, vérification, instantanés, verrou, confirmations,
# codes de retour) reste dans private-data_backup.sh ; cette interface ne fait
# que présenter et transmettre.
#
# Dépendances : gum (paquet « gum ») et le script principal à côté.
# =============================================================================

set -uo pipefail
umask 077

APP_VER=""
_self="${BASH_SOURCE[0]:-$0}"
_self="$(readlink -f -- "${_self}")" || _self="${BASH_SOURCE[0]:-$0}"
SCRIPT_DIR="$(cd -- "$(dirname -- "${_self}")" && pwd)" || exit 1
readonly CLI="${SCRIPT_DIR}/private-data_backup.sh"

# Glyphes Nerd Font (police Nerd Font requise dans le terminal).
readonly ICON_SAVE=$'\uf0c7'
readonly ICON_RESTORE=$'\uf0e2'
readonly ICON_ARCHIVE=$'\uf187'
readonly ICON_USERS=$'\uf0c0'
readonly ICON_QUIT=$'\uf011'
readonly ICON_SNAP=$'\uf0c5'
readonly ICON_EMPTY=$'\uf114'
readonly ICON_WARN=$'\uf071'
readonly ICON_CHECK=$'\uf00c'
readonly ICON_PLUS=$'\uf067'
readonly ICON_EDIT=$'\uf044'
readonly ICON_TRASH=$'\uf1f8'
readonly ICON_EYE=$'\uf06e'
readonly ICON_INFO=$'\uf129'
readonly ICON_CONFIG=$'\uf013'

# Profils (`show --porcelain`).
declare -a P_NAME=() P_SRC=() P_CMD=() P_ARCH=() P_DATE=() P_SIZE=() P_EXCL=()
# Largeurs d'affichage calculées au chargement (alignement garanti).
P_NAME_W=6
P_SRC_W=20
P_CMD_W=12

# Archives (`list --porcelain`).
declare -a A_GROUP=() A_DATE=() A_SIZE=() A_PATH=()

# Sélections courantes.
PICK_FILE=""
PICK_GROUP=""
PICK_FILES=()

# Valeurs de configuration (écran Configuration).
CFG_NAS=""
CFG_SUB=""
CFG_KEEP=""
CFG_VERIFY=""
CFG_SNAP=""
CFG_SNAP_MAX=""
CFG_TIMEOUT=""
CFG_ENCRYPT=""
CFG_AGE_ID=""
CFG_AGE=""
CFG_LOG_FILES=""
PF_NAME=""
PF_SRC=""
PF_CMD=""
PF_EXCL=""

# =============================================================================
# UTILITAIRES
# =============================================================================

# Thème de gum : si l'environnement fournit déjà les GUM_* (session Omarchy),
# on n'y touche pas. Sinon on lit le thème Omarchy courant, et à défaut on
# utilise des couleurs ANSI de base (0-15), donc celles du terminal : la TUI
# reste lisible et cohérente sur une distribution sans Omarchy.
_theme_env() {
	local file="${XDG_STATE_HOME:-${HOME}/.local/state}/omarchy/current/theme/gum_env.lua"
	local key val

	if [[ -n "${GUM_CHOOSE_CURSOR_FOREGROUND:-}" ]]; then
		return 0
	fi
	if [[ -r ${file} ]]; then
		while IFS=' ' read -r key val; do
			[[ -n ${key} ]] || continue
			if [[ -z ${!key:-} ]]; then
				export "${key}=${val}"
			fi
		done < <(sed -n 's/^hl\.env("\([A-Z0-9_]*\)", "\(#[0-9a-fA-F]\{6\}\)").*$/\1 \2/p' "${file}" || true)
	fi
	if [[ -n "${GUM_CHOOSE_CURSOR_FOREGROUND:-}" ]]; then
		return 0
	fi

	# Repli portable : couleurs ANSI de base, celles du thème du terminal.
	export GUM_CHOOSE_CURSOR_FOREGROUND=6
	export GUM_CHOOSE_HEADER_FOREGROUND=7
	export GUM_CHOOSE_SELECTED_FOREGROUND=0
	export GUM_CHOOSE_SELECTED_BACKGROUND=6
	export GUM_CONFIRM_PROMPT_FOREGROUND=6
	export GUM_CONFIRM_SELECTED_FOREGROUND=0
	export GUM_CONFIRM_SELECTED_BACKGROUND=6
	export GUM_CONFIRM_UNSELECTED_FOREGROUND=7
	export GUM_INPUT_PROMPT_FOREGROUND=6
	export GUM_INPUT_HEADER_FOREGROUND=7
	export GUM_INPUT_PLACEHOLDER_FOREGROUND=8
	export GUM_FILE_CURSOR_FOREGROUND=0
	export GUM_FILE_CURSOR_BACKGROUND=6
	export GUM_FILE_HEADER_FOREGROUND=7
	export GUM_PAGER_MATCH_FOREGROUND=6
	return 0
}

_die() {
	printf ' ✗ %s\n' "${*}" >&2
	exit 1
}

_human() {
	local bytes="${1:-0}"
	LC_ALL=C awk -v b="${bytes}" 'BEGIN {
		split("o Ko Mo Go To", u, " ")
		i = 1; s = b + 0
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

_fmt_dt() {

	local d="${1:-}"
	if [[ ${#d} -ne 14 ]]; then
		printf '%s' "—"
		return 0
	fi
	printf '%s-%s-%s %s:%s' "${d:0:4}" "${d:4:2}" "${d:6:2}" "${d:8:2}" "${d:10:2}"
}

_pause() {
	printf '\n'
	read -r -s -n 1 -p "  Entrée pour revenir au menu" || true
	printf '\n'
}

# Efface l'écran (les écrans ne doivent pas s'empiler).
_clear() {
	[[ -t 1 ]] && printf '\033[H\033[2J'
	return 0
}

_group_display() {
	if [[ ${1} == "pre-restore/"* ]]; then
		printf '%s (instantané)' "${1#pre-restore/}"
	else
		printf '%s' "${1}"
	fi
}

_profile_index() {
	# $1 = nom de profil → index dans P_*
	local want="${1}" i
	for i in "${!P_NAME[@]}"; do
		if [[ ${P_NAME[${i}]} == "${want}" ]]; then
			printf '%s' "${i}"
			return 0
		fi
	done
	return 1
}

# =============================================================================
# DONNÉES (une seule source de vérité : le script principal)
# =============================================================================

_load() {
	local out="" line a b c d e f g
	local -a lines=()

	if ! out="$("${CLI}" show --porcelain 2>/dev/null)"; then
		return 1
	fi

	P_NAME=(); P_SRC=(); P_CMD=(); P_ARCH=(); P_DATE=(); P_SIZE=(); P_EXCL=()
	mapfile -t lines <<<"${out}"
	for line in "${lines[@]}"; do
		[[ -n ${line} ]] || continue
		a=""; b=""; c=""; d=""; e=""; f=""; g=""
		IFS=$'\t' read -r a b c d e f g <<<"${line}"
		[[ ${c} == "-" ]] && c=""
		[[ ${d} == "-" ]] && d=""
		[[ ${e} == "-" ]] && e=""
		[[ ${g} == "-" ]] && g=""
		P_NAME+=("${a}")
		P_SRC+=("${b}")
		P_CMD+=("${c}")
		P_ARCH+=("${d}")
		P_DATE+=("${e}")
		P_SIZE+=("${f}")
		P_EXCL+=("${g}")
	done

	P_NAME_W=6
	P_SRC_W=20
	P_CMD_W=12
	for i in "${!P_NAME[@]}"; do
		((${#P_NAME[${i}]} > P_NAME_W)) && P_NAME_W=${#P_NAME[${i}]}
		((${#P_SRC[${i}]} > P_SRC_W)) && P_SRC_W=${#P_SRC[${i}]}
		((${#P_CMD[${i}]} > P_CMD_W)) && P_CMD_W=${#P_CMD[${i}]}
	done
	return 0
}

_load_archives() {
	local out="" line g d s p
	local -a lines=()

	A_GROUP=(); A_DATE=(); A_SIZE=(); A_PATH=()
	if ! out="$("${CLI}" list --porcelain 2>/dev/null)"; then
		return 1
	fi
	mapfile -t lines <<<"${out}"
	for line in "${lines[@]}"; do
		[[ -n ${line} ]] || continue
		g=""; d=""; s=""; p=""
		IFS=$'\t' read -r g d s p <<<"${line}"
		A_GROUP+=("${g}")
		A_DATE+=("${d}")
		A_SIZE+=("${s}")
		A_PATH+=("${p}")
	done
	return 0
}

# Affiche la configuration sous forme CLE=VALEUR, en un seul sous-processus.
_config_dump() {
	local file=""
	file="$("${CLI}" config-path 2>/dev/null)" || return 1
	[[ -n ${file} ]] && [[ -r ${file} ]] || return 1
	(
		set +u
		# shellcheck source=/dev/null # fichier de configuration de l'utilisateur
		source "${file}" >/dev/null 2>&1 || exit 1
		local k
		for k in NAS BACKUP_SUBDIR KEEP_DEFAULT VERIFY_DEFAULT SNAPSHOT_DEFAULT \
			SNAPSHOT_MAX_MB NAS_TIMEOUT LOG_FILES ENCRYPT AGE_RECIPIENT AGE_IDENTITY; do
			printf '%s=%s\n' "${k}" "${!k}"
		done
	)
}

# Lit une variable simple de la configuration.
_config_get() {
	local key="${1:-}" k="" v=""
	[[ -n ${key} ]] || return 1
	while IFS='=' read -r k v; do
		if [[ ${k} == "${key}" ]]; then
			printf '%s' "${v}"
			return 0
		fi
	done < <(_config_dump || true)
	return 1
}

_error_text() {
	local err=""
	err="$("${CLI}" show --porcelain 2>&1 >/dev/null)" || true
	printf '%s' "${err}"
}

# =============================================================================
# LIBELLÉS
# =============================================================================

_label() {
	local i="${1}" line="" when="" size="" cmd=""
	# Colonne « binaire surveillé » : le nom du processus, ou un tiret.
	cmd="${P_CMD[${i}]:--}"
	if [[ -n ${P_ARCH[${i}]} ]]; then
		when="$(_fmt_dt "${P_DATE[${i}]}")"
		size="$(_human "${P_SIZE[${i}]}")"
		line="$(printf '%-*s %-*s %-*s %s  (%s)' \
			"${P_NAME_W}" "${P_NAME[${i}]}" "${P_SRC_W}" "${P_SRC[${i}]}" \
			"${P_CMD_W}" "${cmd}" "${when}" "${size}")"
	else
		line="$(printf '%-*s %-*s %-*s %s' \
			"${P_NAME_W}" "${P_NAME[${i}]}" "${P_SRC_W}" "${P_SRC[${i}]}" \
			"${P_CMD_W}" "${cmd}" "aucune archive")"
	fi
	printf '%s' "${line}"
}

_archive_label() {
	local i="${1}" group="" when="" size="" base=""
	group="$(_group_display "${A_GROUP[${i}]}")"
	when="$(_fmt_dt "${A_DATE[${i}]}")"
	size="$(_human "${A_SIZE[${i}]}")"
	base="${A_PATH[${i}]##*/}"
	printf '%-24s %s  %9s  %s' "${group}" "${when}" "${size}" "${base}"
}

# Sélectionne une archive ; renseigne PICK_FILE / PICK_GROUP.
_pick_archive() {
	local -a labels=()
	local i pick pos=-1

	if ! _load_archives; then
		gum style --border rounded --padding "0 2" --foreground 1 "${ICON_WARN}  Liste indisponible (NAS monté ?)"
		_pause
		return 1
	fi
	if ((${#A_PATH[@]} == 0)); then
		gum style --border rounded --padding "0 2" --foreground 3 "${ICON_EMPTY}  Aucune archive."
		_pause
		return 1
	fi
	for i in "${!A_PATH[@]}"; do
		labels+=("$(_archive_label "${i}")")
	done
	pick="$(gum choose --header "${ICON_ARCHIVE}  Choisir une archive" --cursor "❯ " \
		--height 15 "${labels[@]}")" || return 1
	for i in "${!labels[@]}"; do
		if [[ ${labels[${i}]} == "${pick}" ]]; then
			pos="${i}"
			break
		fi
	done
	((pos < 0)) && return 1
	PICK_FILE="${A_PATH[${pos}]}"
	PICK_GROUP="${A_GROUP[${pos}]}"
	return 0
}

# =============================================================================
# ÉCRANS : SAUVEGARDER / RESTAURER
# =============================================================================

_screen_backup() {
	_clear
	local -a labels=() args=()
	local i pick line

	for i in "${!P_NAME[@]}"; do
		labels+=("$(_label "${i}")")
	done
	if ((${#labels[@]} == 0)); then
		gum style --border rounded --padding "0 2" --foreground 3 "${ICON_EMPTY}  Aucun profil configuré."
		_pause
		return 0
	fi

	pick="$(gum choose --no-limit --height 15 \
		--header "${ICON_SAVE}  Sauvegarder — x pour cocher, entrée pour valider" \
		--cursor "❯ " "${labels[@]}")" || return 0
	[[ -z ${pick} ]] && return 0

	while IFS= read -r line; do
		[[ -n ${line} ]] || continue
		args+=("${line%% *}")
	done <<<"${pick}"
	((${#args[@]} == 0)) && return 0

	gum confirm --affirmative "Sauvegarder" --negative "Annuler" \
		"Sauvegarder : ${args[*]} ?" || return 0

	printf '\n'
	"${CLI}" backup "${args[@]}"
	_pause
	return 0
}

_screen_restore() {
	_clear
	local -a idx=() labels=() opts=()
	local i j pos=-1 pick profile mode when size

	for i in "${!P_NAME[@]}"; do
		[[ -n ${P_ARCH[${i}]} ]] || continue
		idx+=("${i}")
		labels+=("$(_label "${i}")")
	done
	if ((${#labels[@]} == 0)); then
		gum style --border rounded --padding "0 2" --foreground 3 \
			"${ICON_EMPTY}  Aucune archive disponible : lance d'abord une sauvegarde."
		_pause
		return 0
	fi

	pick="$(gum choose --header "${ICON_RESTORE}  Restaurer — choisir un profil" \
		--cursor "❯ " "${labels[@]}")" || return 0
	for j in "${!labels[@]}"; do
		if [[ ${labels[${j}]} == "${pick}" ]]; then
			pos="${j}"
			break
		fi
	done
	((pos < 0)) && return 0
	i="${idx[${pos}]}"
	profile="${P_NAME[${i}]}"
	when="$(_fmt_dt "${P_DATE[${i}]}")"
	size="$(_human "${P_SIZE[${i}]}")"

	gum style --border rounded --padding "0 2" \
		"Restauration ${profile}" \
		"" \
		"archive : ${P_ARCH[${i}]}" \
		"date    : ${when}" \
		"taille  : ${size}" \
		"cible   : ~/${P_SRC[${i}]}" \
		"" \
		"L'archive sera vérifiée avant extraction ; les fichiers écrasés" \
		"sont conservés en *.pre-restore-<date>."

	mode="$(gum choose --header "${ICON_SNAP}  Instantané de l'état actuel avant écrasement" \
		"auto (si ≤ 512 Mo)" "oui (forcer)" "non (aucun)")" || return 0

	opts=(restore "${profile}" --yes)
	case "${mode}" in
	oui*) opts+=(--snapshot) ;;
	non*) opts+=(--no-snapshot) ;;
	*) ;;
	esac

	gum confirm --default=false --affirmative "Restaurer" --negative "Annuler" \
		"Écraser ~/${P_SRC[${i}]} avec ${P_ARCH[${i}]} ?" || return 0

	printf '\n'
	"${CLI}" "${opts[@]}"
	_pause
	return 0
}

# =============================================================================
# ÉCRAN : ARCHIVES
# =============================================================================

_archives_restore() {
	local profile="" src="" pindex=""
	_pick_archive || return 0
	profile="${PICK_GROUP#pre-restore/}"
	profile="${profile^^}"
	if pindex="$(_profile_index "${profile}")"; then
		src="${P_SRC[${pindex}]}"
	else
		src="(profil inconnu)"
	fi
	gum style --border rounded --padding "0 2" \
		"Restaurer une version" \
		"" \
		"archive : ${PICK_FILE##*/}" \
		"profil  : ${profile}" \
		"cible   : ~/${src}"
	if ! gum confirm --default=false --affirmative "Restaurer" --negative "Annuler" \
		"Écraser ~/${src} avec cette archive ?"; then
		return 0
	fi
	printf '\n'
	"${CLI}" restore --archive "${PICK_FILE}" --yes
	_pause
	return 0
}

_archives_verify() {
	_pick_archive || return 0
	printf '\n'
	"${CLI}" verify "${PICK_FILE}"
	_pause
	return 0
}

# Sélection multiple d'archives (x pour cocher) ; renseigne PICK_FILES.
_pick_archives() {
	local -a labels=()
	local i pick line
	PICK_FILES=()
	if ! _load_archives; then
		gum style --border rounded --padding "0 2" --foreground 1 "${ICON_WARN}  Liste indisponible (NAS monté ?)"
		_pause
		return 1
	fi
	if ((${#A_PATH[@]} == 0)); then
		gum style --border rounded --padding "0 2" --foreground 3 "${ICON_EMPTY}  Aucune archive."
		_pause
		return 1
	fi
	for i in "${!A_PATH[@]}"; do
		labels+=("$(_archive_label "${i}")")
	done
	pick="$(gum choose --no-limit --height 15 \
		--header "${ICON_TRASH}  Supprimer — x pour cocher, entrée pour valider" \
		--cursor "❯ " "${labels[@]}")" || return 1
	[[ -z ${pick} ]] && return 1
	while IFS= read -r line; do
		[[ -n ${line} ]] || continue
		for i in "${!labels[@]}"; do
			if [[ ${labels[${i}]} == "${line}" ]]; then
				PICK_FILES+=("${A_PATH[${i}]}")
				break
			fi
		done
	done <<<"${pick}"
	((${#PICK_FILES[@]} > 0)) || return 1
	return 0
}

_archives_delete() {
	local -a disps=()
	local f i total=0 total_h=""
	_pick_archives || return 0
	for f in "${PICK_FILES[@]}"; do
		disps+=("  - ${f##*/}")
		for i in "${!A_PATH[@]}"; do
			if [[ ${A_PATH[${i}]} == "${f}" ]]; then
				total=$((total + A_SIZE[i]))
				break
			fi
		done
	done
	total_h="$(_human "${total}")"
	gum style --border rounded --padding "0 2" "Suppression" "" "${disps[@]}" "" "total : ${total_h}"
	local np=${#PICK_FILES[@]} cp=""
	cp="$(_count "${np}" archive archives)"
	if ! gum confirm --default=false --affirmative "Supprimer" --negative "Annuler" \
		"Supprimer définitivement ${cp} ?"; then
		return 0
	fi
	printf '\n'
	"${CLI}" delete-archive "${PICK_FILES[@]}" --yes
	_pause
	return 0
}

_archives_encrypt() {
	local enc="" i clair=0
	enc="$(_config_get ENCRYPT)"
	if [[ ${enc} != "age" ]]; then
		gum style --border rounded --padding "0 2" --foreground 3 \
			"${ICON_WARN}  Chiffrement inactif : active-le dans Configuration → Chiffrement."
		_pause
		return 0
	fi
	if ! _load_archives; then
		gum style --border rounded --padding "0 2" --foreground 1 "${ICON_WARN}  Liste indisponible (NAS monté ?)"
		_pause
		return 0
	fi
	for i in "${!A_PATH[@]}"; do
		case "${A_PATH[${i}]}" in
		*.age) ;;
		*) clair=$((clair + 1)) ;;
		esac
	done
	if ((clair == 0)); then
		if ((${#A_PATH[@]} == 0)); then
			gum style --border rounded --padding "0 2" --foreground 3 \
				"${ICON_EMPTY}  Aucune archive sur le stockage."
		else
			local na=${#A_PATH[@]}
			if ((na == 1)); then
				gum style --border rounded --padding "0 2" --foreground 2 \
					"${ICON_CHECK}  L'archive est déjà chiffrée (1 archive)."
			else
				gum style --border rounded --padding "0 2" --foreground 2 \
					"${ICON_CHECK}  Toutes les archives sont déjà chiffrées (${na} archives)."
			fi
		fi
		_pause
		return 0
	fi
	printf '\n'
	"${CLI}" encrypt-archives --dry-run
	if ! gum confirm --default=false --affirmative "Chiffrer" --negative "Annuler" \
		"Chiffrer ces archives et supprimer les originaux en clair ?"; then
		return 0
	fi
	printf '\n'
	"${CLI}" encrypt-archives --yes
	_pause
	return 0
}

_archives_retention() {
	local out="" rc=0 tmp=""
	tmp="$(mktemp)" || return 0
	printf '\n'
	"${CLI}" delete_old --dry-run 2>&1 | tee "${tmp}"
	rc=${PIPESTATUS[0]}
	out="$(cat "${tmp}")"
	rm -f -- "${tmp}"
	if ((rc != 0)) || [[ ${out} == *"rien à supprimer"* ]] || [[ ${out} == *"aucune archive"* ]]; then
		_pause
		return 0
	fi
	if ! gum confirm --default=false --affirmative "Appliquer" --negative "Annuler" \
		"Appliquer cette rétention (suppressions définitives) ?"; then
		return 0
	fi
	printf '\n'
	"${CLI}" delete_old --yes
	_pause
	return 0
}

_archives_purge() {
	local out="" rc=0 tmp=""
	tmp="$(mktemp)" || return 0
	printf '\n'
	"${CLI}" delete_old --purge-orphans --dry-run --no-verify 2>&1 | tee "${tmp}"
	rc=${PIPESTATUS[0]}
	out="$(cat "${tmp}")"
	rm -f -- "${tmp}"
	if ((rc != 0)) || [[ ${out} == *"rien à supprimer"* ]] || [[ ${out} == *"aucune archive"* ]]; then
		_pause
		return 0
	fi
	if ! gum confirm --default=false --affirmative "Purger" --negative "Annuler" \
		"Supprimer tous les profils hors configuration (définitif) ?"; then
		return 0
	fi
	printf '\n'
	"${CLI}" delete_old --purge-orphans --yes --no-verify
	_pause
	return 0
}

_screen_archives() {
	local action="" count=0 total=0 i header=""
	while true; do
		_clear
		# Compteur rafraîchi à chaque passage (suppressions, purge…).
		count=0
		total=0
		if _load_archives; then
			count=${#A_PATH[@]}
			for i in "${!A_SIZE[@]}"; do
				total=$((total + A_SIZE[i]))
			done
		fi
		local cc=""
		cc="$(_count "${count}" fichier fichiers)"
		header="${ICON_ARCHIVE}  Archives — ${cc}, $(_human "${total}") — que faire ?"

		action="$(gum choose --header "${header}" --cursor "❯ " \
			"${ICON_EYE}  Voir les archives" \
			"Restaurer une version" \
			"Vérifier une archive" \
			"Supprimer des archives" \
			"Chiffrer les archives en clair" \
			"Appliquer la politique de rétention" \
			"Purger les profils orphelins" \
			"Retour")" || return 0
		case "${action}" in
		*Voir*)
			printf '\n'
			"${CLI}" list 2>&1 | gum pager --show-line-numbers=false
			# En quittant le pager, on revient au menu : ses possibilités
			# sont réaffichées.
			;;
		Restaurer*) _archives_restore ;;
		Vérifier*) _archives_verify ;;
		Supprimer*) _archives_delete ;;
		Chiffrer*) _archives_encrypt ;;
		Appliquer*) _archives_retention ;;
		Purger*) _archives_purge ;;
		*) return 0 ;;
		esac
	done
}

# =============================================================================
# ÉCRAN : PROFILS
# =============================================================================

_profile_pick() {
	local -a labels=()
	local i pick pos=-1

	if ((${#P_NAME[@]} == 0)); then
		gum style --border rounded --padding "0 2" --foreground 3 "${ICON_EMPTY}  Aucun profil."
		_pause
		return 1
	fi
	for i in "${!P_NAME[@]}"; do
		labels+=("$(_label "${i}")")
	done
	pick="$(gum choose --header "${ICON_USERS}  Choisir un profil" --cursor "❯ " "${labels[@]}")" || return 1
	for i in "${!labels[@]}"; do
		if [[ ${labels[${i}]} == "${pick}" ]]; then
			pos="${i}"
			break
		fi
	done
	((pos < 0)) && return 1
	printf '%s' "${pos}"
	return 0
}

_profile_inputs() {
	local mode="${1}" i="${2:-}" picked="" where=""

	PF_NAME=""; PF_SRC=""; PF_CMD=""; PF_EXCL=""
	if [[ ${mode} == "edit" ]]; then
		PF_NAME="${P_NAME[${i}]}"
		PF_SRC="${P_SRC[${i}]}"
		PF_CMD="${P_CMD[${i}]}"
		PF_EXCL="${P_EXCL[${i}]}"
	fi

	PF_NAME="$(gum input --header "Nom du profil (A-Z, 0-9, _)" \
		--value "${PF_NAME}" --placeholder "MUSIQUE")" || return 1
	[[ -n ${PF_NAME} ]] || return 1

	where="$(gum choose --header "Dossier à sauvegarder" \
		"Choisir dans ${HOME}" "Saisir un chemin relatif")" || return 1
	if [[ ${where} == "Choisir"* ]]; then
		picked="$(gum file --directory --all --height 18 \
			--header "Dossier (${HOME})" "${HOME}")" || return 1
		if [[ ${picked} == "${HOME}/"* ]]; then
			PF_SRC="${picked#"${HOME}/"}"
		else
			gum style --border rounded --padding "0 2" --foreground 1 \
				"${ICON_WARN}  Hors de ${HOME} : ${picked}"
			return 1
		fi
	else
		PF_SRC="$(gum input --header "Dossier relatif à \$HOME" \
			--value "${PF_SRC}" --placeholder "Documents")" || return 1
	fi
	[[ -n ${PF_SRC} ]] || return 1

	PF_CMD="$(gum input --header "Binaire à surveiller (optionnel)" \
		--value "${PF_CMD}" --placeholder "brave")" || return 1
	PF_EXCL="$(gum input --header "Exclusions tar séparées par | (optionnel)" \
		--value "${PF_EXCL}" --placeholder "Cache|GPUCache")" || return 1
	return 0
}

_profile_save() {
	local action="${1}" rc=0
	gum style --border rounded --padding "0 2" \
		"${action} un profil" \
		"" \
		"nom     : ${PF_NAME}" \
		"dossier : ~/${PF_SRC}" \
		"binaire : ${PF_CMD:-(aucun)}" \
		"exclure : ${PF_EXCL:-(aucune)}"
	gum confirm --default=false --affirmative "Enregistrer" --negative "Annuler" \
		"Écrire dans le fichier de configuration ?" || return 0
	printf '\n'
	"${CLI}" profile-add "${PF_NAME}" "${PF_SRC}" "${PF_CMD}" "${PF_EXCL}"
	rc=$?
	_pause
	return "${rc}"
}

_profile_add() {
	_profile_inputs add || return 0
	_profile_save "Ajouter"
	return 0
}

_profile_edit() {
	local pos="" old="" rc=0
	pos="$(_profile_pick)" || return 0
	old="${P_NAME[${pos}]}"
	_profile_inputs edit "${pos}" || return 0
	_profile_save "Modifier"
	rc=$?
	# Renommage : l'ancien nom est retiré seulement si l'écriture a réussi.
	if ((rc == 0)) && [[ ${PF_NAME^^} != "${old}" ]]; then
		printf '\n'
		"${CLI}" profile-remove "${old}"
		_pause
	fi
	return 0
}

_profile_adopt() {
	local tmp=""
	tmp="$(mktemp)" || return 0
	printf '\n'
	# Une seule analyse : le plan est mis en cache puis appliqué tel quel.
	"${CLI}" adopt-orphans --dry-run --plan "${tmp}"
	if [[ ! -s ${tmp} ]]; then
		rm -f -- "${tmp}"
		_pause
		return 0
	fi
	if ! gum confirm --default=false --affirmative "Adopter" --negative "Annuler" \
		"Ajouter ces profils orphelins à la configuration ?"; then
		rm -f -- "${tmp}"
		return 0
	fi
	printf '\n'
	"${CLI}" adopt-orphans --yes --apply-plan "${tmp}"
	rm -f -- "${tmp}"
	_pause
	return 0
}

_profile_check() {
	printf '\n'
	"${CLI}" config-check
	_pause
	return 0
}

_profile_remove() {
	local pos=""
	pos="$(_profile_pick)" || return 0
	if ! gum confirm --default=false --affirmative "Retirer" --negative "Annuler" \
		"Retirer ${P_NAME[${pos}]} de la configuration ? (ses archives resteront sur le NAS)"; then
		return 0
	fi
	printf '\n'
	"${CLI}" profile-remove "${P_NAME[${pos}]}"
	_pause
	return 0
}

_screen_profiles() {
	_clear
	local -a labels=()
	local i action

	for i in "${!P_NAME[@]}"; do
		labels+=("$(_label "${i}")")
	done
	if ((${#labels[@]} == 0)); then
		gum style --border rounded --padding "0 2" --foreground 3 "${ICON_EMPTY}  Aucun profil."
		_pause
		return 0
	fi
	gum style --border rounded --padding "0 2" "Profils configurés" "" "${labels[@]}"

	action="$(gum choose --header "${ICON_USERS}  Profils — que faire ?" --cursor "❯ " \
		"${ICON_PLUS}  Ajouter un profil" \
		"${ICON_EDIT}  Modifier un profil" \
		"${ICON_TRASH}  Retirer un profil" \
		"${ICON_CHECK}  Adopter les profils orphelins" \
		"${ICON_INFO}  Vérifier les conflits" \
		"Retour")" || return 0
	case "${action}" in
	*Ajouter*) _profile_add ;;
	*Modifier*) _profile_edit ;;
	*Retirer*) _profile_remove ;;
	*Adopter*) _profile_adopt ;;
	*Vérifier*) _profile_check ;;
	*) ;;
	esac
	return 0
}

# =============================================================================
# ÉCRAN : DESCRIPTION
# =============================================================================

_screen_about() {
	_clear
	local cfg="" nas="" sub="" storage=""

	cfg="$("${CLI}" config-path 2>/dev/null)" || cfg="(inconnue)"
	nas="$(_config_get NAS)" || nas=""
	sub="$(_config_get BACKUP_SUBDIR)" || sub=""
	if [[ -n ${nas} ]] && [[ -n ${sub} ]]; then
		storage="${nas%/}/${sub#/}"
	else
		storage="(non défini)"
	fi

	gum pager --show-line-numbers=false <<EOF
Private data backup v${APP_VER}
==============================

Sauvegarde et restauration de données privées vers un stockage dédié
(NAS ou disque externe), par profils déclarés dans un fichier de
configuration.

CE QUE FAIT CHAQUE ACTION
-------------------------
Sauvegarder   Archive un ou plusieurs profils (tar.gz). Refuse un profil
              dont l'application tourne, applique les exclusions, vérifie
              l'archive et ne la renomme que si elle est saine
              (écriture atomique : .part -> contrôle -> mv).

Restaurer     Restaure l'archive la plus récente d'un profil après
              vérification d'intégrité (repli sur la version précédente
              si elle est corrompue) et confirmation. Un instantané de
              l'état actuel est créé avant l'écrasement ; les fichiers
              remplacés sont conservés en *.pre-restore-<date>.

Archives      Voir toutes les archives, restaurer une version précise,
              vérifier, supprimer, appliquer la politique de rétention
              (delete_old) ou purger les profils absents de la config.

Profils       Ajouter, modifier ou retirer un profil dans le fichier de
              configuration (sauvegarde .bak, écriture validée).

Configuration Modifier la destination (montage et sous-dossier), la
              rétention, la vérification, les instantanés, le chiffrement,
              la liste des fichiers dans le journal et le délai NFS —
              mêmes garde-fous que pour les profils.

OÙ SONT LES CHOSES
------------------
Configuration : ${cfg}
Stockage      : ${storage}
Journaux      : ~/.local/share/private-data_backup/

SÉCURITÉ
--------
Archives et journaux en 0600, dossiers en 0700, chiffrement age (clé age ou SSH)
optionnel (ENCRYPT dans la configuration), verrou pour empêcher deux
exécutions simultanées.

Toutes les opérations destructrices demandent une confirmation.
EOF
	return 0
}

# =============================================================================
# ÉCRAN : CONFIGURATION
# =============================================================================

_config_values_load() {
	local k="" v=""
	while IFS='=' read -r k v; do
		case "${k}" in
		NAS) CFG_NAS="${v}" ;;
		BACKUP_SUBDIR) CFG_SUB="${v}" ;;
		KEEP_DEFAULT) CFG_KEEP="${v}" ;;
		VERIFY_DEFAULT) CFG_VERIFY="${v}" ;;
		SNAPSHOT_DEFAULT) CFG_SNAP="${v}" ;;
		SNAPSHOT_MAX_MB) CFG_SNAP_MAX="${v}" ;;
		NAS_TIMEOUT) CFG_TIMEOUT="${v}" ;;
		LOG_FILES) CFG_LOG_FILES="${v}" ;;
		ENCRYPT) CFG_ENCRYPT="${v}" ;;
		AGE_RECIPIENT) CFG_AGE="${v}" ;;
		AGE_IDENTITY) CFG_AGE_ID="${v}" ;;
		*) ;;
		esac
	done < <(_config_dump || true)
	return 0
}

_config_apply() {
	local -a pairs=("${@}")
	gum style --border rounded --padding "0 2" "Nouvelle configuration" "" "${pairs[@]}"
	gum confirm --default=false --affirmative "Enregistrer" --negative "Annuler" \
		"Écrire ces paramètres dans la configuration ?" || return 0
	printf '\n'
	"${CLI}" config-set "${pairs[@]}"
	_pause
	return 0
}

_config_destination() {
	local nas="" sub=""
	nas="$(gum input --header "Point de montage (NAS)" --value "${CFG_NAS}")" || return 0
	[[ -n ${nas} ]] || return 0
	sub="$(gum input --header "Sous-dossier des archives" --value "${CFG_SUB}")" || return 0
	[[ -n ${sub} ]] || return 0
	_config_apply "NAS=${nas}" "BACKUP_SUBDIR=${sub}"
	return 0
}

_config_retention() {
	local keep="" verify="" v=1
	keep="$(gum input --header "Archives conservées par profil" --value "${CFG_KEEP}")" || return 0
	if [[ ! ${keep} =~ ^[0-9]+$ ]] || ((keep < 1)); then
		gum style --border rounded --padding "0 2" --foreground 1 "Nombre invalide : ${keep}"
		_pause
		return 0
	fi
	verify="$(gum choose --header "Vérifier l'intégrité après écriture" "oui" "non")" || return 0
	[[ ${verify} == "non" ]] && v=0
	_config_apply "KEEP_DEFAULT=${keep}" "VERIFY_DEFAULT=${v}"
	return 0
}

_config_snapshot() {
	local mode="" max="" val=""
	mode="$(gum choose --header "Instantané avant restauration" "auto (si ≤ 512 Mo)" "toujours" "jamais")" || return 0
	case "${mode}" in
	auto*) val="auto" ;;
	toujours*) val="yes" ;;
	*) val="no" ;;
	esac
	max="${CFG_SNAP_MAX}"
	if [[ ${val} == "auto" ]]; then
		max="$(gum input --header "Taille max en mode auto (Mo)" --value "${CFG_SNAP_MAX}")" || return 0
		if [[ ! ${max} =~ ^[0-9]+$ ]] || ((max < 1)); then
			gum style --border rounded --padding "0 2" --foreground 1 "Taille invalide : ${max}"
			_pause
			return 0
		fi
	fi
	_config_apply "SNAPSHOT_DEFAULT=${val}" "SNAPSHOT_MAX_MB=${max}"
	return 0
}

_config_encrypt() {
	local enc="" rec="" id=""
	enc="$(gum choose --header "Chiffrement des archives" "aucun" "age")" || return 0
	case "${enc}" in
	aucun)
		_config_apply "ENCRYPT=" "AGE_RECIPIENT=" "AGE_IDENTITY="
		;;
	age)
		rec="$(gum input --header "Destinataire (optionnel : déduit de la clé privée si vide)" \
			--value "${CFG_AGE}")" || return 0
		id="$(gum input --header "Clé privée pour restaurer (.ssh/id_ed25519, keys.txt…)" \
			--value "${CFG_AGE_ID}")" || return 0
		[[ -n ${id} ]] || return 0
		_config_apply "ENCRYPT=age" "AGE_RECIPIENT=${rec}" "AGE_IDENTITY=${id}"
		;;
	*) ;;
	esac
	return 0
}

_config_logging() {
	local v="" val=0
	v="$(gum choose --header "Journaliser la liste des fichiers (sauvegarde, vérification, restauration)" \
		"oui" "non")" || return 0
	if [[ ${v} == "oui" ]]; then
		val=1
	fi
	_config_apply "LOG_FILES=${val}"
	return 0
}

_config_timeout() {
	local t=""
	t="$(gum input --header "Délai des vérifications NFS (secondes)" --value "${CFG_TIMEOUT}")" || return 0
	if [[ ! ${t} =~ ^[0-9]+$ ]] || ((t < 1)); then
		gum style --border rounded --padding "0 2" --foreground 1 "Délai invalide : ${t}"
		_pause
		return 0
	fi
	_config_apply "NAS_TIMEOUT=${t}"
	return 0
}

_screen_config() {
	local action="" snap=""
	while true; do
		_clear
		_config_values_load
		case "${CFG_VERIFY}" in
		0) snap="non" ;;
		*) snap="oui" ;;
		esac
		local snap_line="instantané   : ${CFG_SNAP}"
		local keep_line=""
		keep_line="$(_count "${CFG_KEEP}" archive archives)"
		local CFG_LISTE="non"
		[[ ${CFG_LOG_FILES} == "1" ]] && CFG_LISTE="oui"
		if [[ ${CFG_SNAP} == "auto" ]]; then
			snap_line="instantané   : auto (max ${CFG_SNAP_MAX} Mo)"
		fi
		gum style --border rounded --padding "0 2" \
			"Configuration" \
			"" \
			"destination  : ${CFG_NAS}/${CFG_SUB}" \
			"rétention    : ${keep_line} par profil" \
			"vérification : ${snap} après écriture" \
			"${snap_line}" \
			"chiffrement  : ${CFG_ENCRYPT:-aucun}" \
			"fichiers     : ${CFG_LISTE} (liste dans le journal)" \
			"délai NFS    : ${CFG_TIMEOUT} s"

		action="$(gum choose --header "${ICON_CONFIG}  Configuration — que modifier ?" --cursor "❯ " \
			"Destination (montage, sous-dossier)" \
			"Rétention et vérification" \
			"Instantanés avant restauration" \
			"Chiffrement" \
			"Journalisation (liste des fichiers)" \
			"Délai NFS" \
			"Retour")" || return 0
		case "${action}" in
		Destination*) _config_destination ;;
		Rétention*) _config_retention ;;
		Instantanés*) _config_snapshot ;;
		Chiffrement*) _config_encrypt ;;
		Journalisation*) _config_logging ;;
		Délai*) _config_timeout ;;
		*) return 0 ;;
		esac
	done
}

# =============================================================================
# MENU
# =============================================================================

_menu() {
	local choice
	_clear
	choice="$(gum choose --header "Private data backup v${APP_VER}" \
		--cursor "❯ " \
		"${ICON_INFO}  Description" \
		"${ICON_SAVE}  Sauvegarder" \
		"${ICON_RESTORE}  Restaurer" \
		"${ICON_ARCHIVE}  Archives" \
		"${ICON_USERS}  Profils" \
		"${ICON_CONFIG}  Configuration" \
		"${ICON_QUIT}  Quitter")" || return 1
	# Correspondance par mot-clé : les icônes peuvent changer sans casser le menu.
	case "${choice}" in
	*Description*) _screen_about ;;
	*Sauvegarder*) _screen_backup ;;
	*Restaurer*) _screen_restore ;;
	*Archives*) _screen_archives ;;
	*Profils*) _screen_profiles ;;
	*Configuration*) _screen_config ;;
	*) return 1 ;;
	esac
	return 0
}

# =============================================================================
# POINT D'ENTRÉE
# =============================================================================

main() {
	# Version unique : celle du script principal (pas de version TUI séparée).
	APP_VER="$("${CLI}" --version 2>/dev/null | awk '{print $NF}')" || true
	[[ -n ${APP_VER} ]] || APP_VER="?"

	case "${1:-}" in
	-h|--help)
		printf '\nprivate-data_backup-tui %s — interface texte de private-data_backup\n' "${APP_VER}"
		printf '\nUsage : private-data_backup-tui.sh [--help | --version]\n'
		printf '\nÉcrans\n'
		printf '  %-16s %s\n' "Sauvegarder"   "choisir des profils et lancer une sauvegarde"
		printf '  %-16s %s\n' "Restaurer"     "restaurer la dernière archive, avec ou sans instantané"
		printf '  %-16s %s\n' "Archives"      "voir, restaurer une version, vérifier, supprimer (x pour"
		printf '  %-16s %s\n' ""              "cocher plusieurs archives), chiffrer les archives en clair,"
		printf '  %-16s %s\n' ""              "rétention, purge des profils orphelins"
		printf '  %-16s %s\n' "Profils"       "ajouter, modifier, retirer, adopter les orphelins, conflits"
		printf '  %-16s %s\n' "Configuration" "destination, rétention, instantanés, chiffrement, journaux"
		printf '  %-16s %s\n' "Description"   "présentation de l'outil"
		printf '\nSécurité : vérification, instantanés, confirmations et verrou\n'
		printf 'restent gérés par le script CLI.\n'
		printf '\nDépendances : gum, awk, et private-data_backup.sh (même dossier).\n\n'
		return 0
		;;
	--version)
		printf 'private-data_backup %s\n' "${APP_VER}"
		return 0
		;;
	*) ;;
	esac

	[[ -t 0 ]] && [[ -t 1 ]] || _die "cette interface nécessite un terminal interactif"
	command -v gum >/dev/null 2>&1 || _die "gum est requis (paquet gum)"
	command -v awk >/dev/null 2>&1 || _die "awk est requis (paquet gawk ou mawk)"
	_theme_env
	[[ -x ${CLI} ]] || _die "script principal introuvable : ${CLI}"

	local err=""
	while true; do
		if ! _load; then
			err="$(_error_text)"
			gum style --border rounded --padding "1 2" --foreground 1 \
				"${ICON_WARN}  Erreur" \
				"" \
				"Impossible de lire la configuration ou le NAS." \
				"${err}"
			return 1
		fi
		_menu || break
	done
	return 0
}

main "${@}"
