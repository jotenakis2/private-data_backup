#!/usr/bin/env bash
# shellcheck enable=all
# shellcheck disable=SC2312 # Captures de sortie intentionnelles dans le harnais de test.
set -euo pipefail
umask 077

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
PTY="${ROOT}/tests/pty_drive.py"
TUI_SRC="${ROOT}/private-data_backup-tui.sh"

fail() {
	printf 'FAIL: %s\n' "$*" >&2
	exit 1
}

file_content() {
	local file="${1}"
	cat -- "${file}" 2>/dev/null || true
}

command -v gum >/dev/null 2>&1 || fail "gum est requis pour les tests TUI"
command -v python3 >/dev/null 2>&1 || fail "python3 est requis pour les tests TUI"

workdir="$(mktemp -d "${TMPDIR:-/tmp}/pdb-tui.XXXXXX")"
cleanup() {
	rm -rf -- "${workdir}"
}
trap cleanup EXIT

setup_env() {
	local dir="${1}"
	mkdir -p "${dir}"
	cp -- "${TUI_SRC}" "${dir}/private-data_backup-tui.sh"
	chmod +x "${dir}/private-data_backup-tui.sh"

	cat >"${dir}/private-data_backup.sh" <<'EOF'
#!/usr/bin/env bash
# shellcheck enable=all
set -euo pipefail
log="${FAKE_CLI_LOG:?}"
case "${1:-}" in
--version)
	printf 'private-data_backup 0.0-test\n'
	;;
show)
	if [[ "${2:-}" == "--porcelain" ]]; then
		printf 'ALPHA\tdocs/a\t-\t-\t-\t0\t-\n'
		printf 'BETA\tdocs/b\t-\t-\t-\t0\t-\n'
		printf 'GAMMA\tdocs/c\t-\t-\t-\t0\t-\n'
	fi
	;;
backup)
	shift
	printf 'BACKUP:%s\n' "$*" >>"${log}"
	;;
*)
	;;
esac
exit 0
EOF
	chmod +x "${dir}/private-data_backup.sh"
}

run_case() {
	local name="${1}" scenario="${2}"
	local dir="${workdir}/${name}"
	local cli_log="${dir}/cli.log"
	local out_log="${dir}/pty.log"
	setup_env "${dir}"
	: >"${cli_log}"
	FAKE_CLI_LOG="${cli_log}" TERM=xterm-256color python3 "${PTY}" "${dir}" "./private-data_backup-tui.sh" "${out_log}" "${scenario}"
	printf '%s' "${cli_log}"
}

assert_eq() {
	local got="${1}" want="${2}" msg="${3}"
	[[ ${got} == "${want}" ]] || fail "${msg} (attendu: [${want}], obtenu: [${got}])"
}

assert_file_empty() {
	local file="${1}" msg="${2}" content=""
	if [[ -s ${file} ]]; then
		content="$(file_content "${file}")"
		fail "${msg} (contenu: ${content})"
	fi
}

# a) Entrée sur le premier profil -> backup appelé avec exactement ce nom
cli_log="$(run_case single single_enter)"
got="$(file_content "${cli_log}")"
assert_eq "${got}" "BACKUP:ALPHA" "Entrée sur le premier profil doit sauvegarder ALPHA"

# b) Cocher plusieurs profils + x sur deux profils + Entrée -> deux noms dans l'ordre
cli_log="$(run_case multi multi_check)"
got="$(file_content "${cli_log}")"
assert_eq "${got}" "BACKUP:ALPHA BETA" "La sélection multiple doit sauvegarder ALPHA puis BETA"

# c) Échap sur la liste -> aucun appel à backup, message d'annulation
cli_log="$(run_case escape escape)"
assert_file_empty "${cli_log}" "Échap ne doit déclencher aucune sauvegarde"
out_log="${workdir}/escape/pty.log"
grep -aFq 'Sauvegarde annulée' "${out_log}" || fail "Échap doit afficher le message d'annulation"

gum_ver="$(gum --version 2>/dev/null || true)"
gum_ver="${gum_ver%%$'\n'*}"
[[ -n ${gum_ver} ]] || gum_ver="gum"
printf 'OK: tests TUI (%s)\n' "${gum_ver}"
