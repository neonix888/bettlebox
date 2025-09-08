#!/usr/bin/env bash
# bettlebox-preflight.sh
# Preflight checks + optional install/uninstall for common tooling to prep an embedded/IoT CI/CD env in WSL2 Ubuntu.
#
# TDD-friendly: includes --self-test (mocked), --hello-docker, --cleanup-docker-test.
#
# Highlights:
#   - CHECKS: Ubuntu >=20.04, WSL2, network, resources, Docker, basics, optional tools, device/KVM hints
#   - INSTALL: --install-basics, --install-qemu, --install-docker-engine (official Docker CE repo)
#   - UNINSTALL: --uninstall (basics/qemu), --purge-docker-engine (also removes repo/keyring), --nuke-docker-data
#   - WSL HELPERS: --set-wslconf-systemd (with timestamped backups), --restore-wslconf-latest,
#                  --show-wslconf-backups, --restore-wslconf=<index|filename>
#   - TESTS: --self-test (safe, mocked), --hello-docker, --cleanup-docker-test
#   - SAFETY: --dry-run (simulate), --no-group (skip docker group add)
#
# All installed/changed items are tracked in:
#   ~/.bettlebox-preflight/installed-packages.txt
#
# Exit code:
#   0 if all REQUIRED checks pass (or uninstall/purge/tests succeed), non-zero otherwise.

set -u
IFS=$'\n\t'

# ---------- Pretty-print helpers ----------
RED="\033[31m"; GREEN="\033[32m"; YELLOW="\033[33m"; BLUE="\033[34m"; BOLD="\033[1m"; RESET="\033[0m"
pass(){ printf "${GREEN}✔ PASS${RESET} %s\n" "$*"; }
warn(){ printf "${YELLOW}⚠ WARN${RESET} %s\n" "$*"; }
fail(){ printf "${RED}✖ FAIL${RESET} %s\n" "$*"; }
info(){ printf "${BLUE}ℹ${RESET} %s\n" "$*"; }

# ---------- Small utilities ----------
has_cmd(){ command -v "$1" >/dev/null 2>&1; }
timestamp(){ date +"%Y%m%d-%H%M%S"; }

# ---------- State & backup locations ----------
STATE_DIR="${HOME}/.bettlebox-preflight"
STATE_FILE="${STATE_DIR}/installed-packages.txt"
BACKUP_DIR="${STATE_DIR}/backups"
mkdir -p "$STATE_DIR" "$BACKUP_DIR"
touch "$STATE_FILE"

# Path to real WSL conf; tests can override by setting WSLCONF_PATH before calling
WSLCONF_PATH="/etc/wsl.conf"

# ---------- CLI flags ----------
REQUIRED_FAILS=0
OPTIONAL_FAILS=0
INSTALL_BASICS=0
INSTALL_QEMU=0
DO_UNINSTALL=0
DRY_RUN=0
INSTALL_DOCKER_ENGINE=0
PURGE_DOCKER_ENGINER=0
PURGE_DOCKER_ENGINE=0
NUKE_DOCKER_DATA=0
NO_GROUP=0
SET_WSLCONF_SYSTEMD=0
RESTORE_WSLCONF_LATEST=0
SHOW_WSLCONF_BACKUPS=0
RESTORE_WSLCONF_ARG=""
SELF_TEST=0
HELLO_DOCKER=0
CLEANUP_DOCKER_TEST=0

usage() {
  cat <<EOF
Usage: $0 [options]

Checks (default):
  Runs environment checks for Ubuntu on WSL2, Docker, resources, basics, optional tools, and device hints.

Installers (tracked; reversible):
  --install-basics         Install git curl build-essential python3 python3-pip
  --install-qemu           Install qemu-system
  --install-docker-engine  Install Docker CE (docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin)

Uninstall:
  --uninstall              Uninstall everything this script previously installed (basics/qemu)
  --purge-docker-engine    Purge Docker CE packages, remove Docker apt repo/keyring
  --nuke-docker-data       Also remove /var/lib/docker and /var/lib/containerd (use with --purge-docker-engine)

WSL systemd helpers (with backups):
  --set-wslconf-systemd    Backup /etc/wsl.conf, ensure [boot] systemd=true (idempotent)
  --restore-wslconf-latest Restore the most recent backup created by this script
  --show-wslconf-backups   List available backups with indices (newest first)
  --restore-wslconf=VAL    Restore a specific backup by index or full filename (must reside in backup dir)

TDD / smoke tests:
  --self-test              Run internal tests (safe; uses mocked wsl.conf area)
  --hello-docker           Pull & run 'hello-world', track image/container in state
  --cleanup-docker-test    Remove docker 'hello-world' image/container *only if this script pulled it*

Other:
  --no-group               Skip adding current user to 'docker' group during Docker install
  --dry-run                Show actions without making changes
  --help                   Show this help
EOF
}

# ---------- Parse CLI args ----------
for arg in "$@"; do
  case "$arg" in
    --install-basics)            INSTALL_BASICS=1 ;;
    --install-qemu)              INSTALL_QEMU=1 ;;
    --uninstall)                 DO_UNINSTALL=1 ;;
    --dry-run)                   DRY_RUN=1 ;;
    --install-docker-engine)     INSTALL_DOCKER_ENGINE=1 ;;
    --purge-docker-engine)       PURGE_DOCKER_ENGINE=1 ;;
    --nuke-docker-data)          NUKE_DOCKER_DATA=1 ;;
    --no-group)                  NO_GROUP=1 ;;
    --set-wslconf-systemd)       SET_WSLCONF_SYSTEMD=1 ;;
    --restore-wslconf-latest)    RESTORE_WSLCONF_LATEST=1 ;;
    --show-wslconf-backups)      SHOW_WSLCONF_BACKUPS=1 ;;
    --restore-wslconf=*)         RESTORE_WSLCONF_ARG="${arg#*=}" ;;
    --self-test)                 SELF_TEST=1 ;;
    --hello-docker)              HELLO_DOCKER=1 ;;
    --cleanup-docker-test)       CLEANUP_DOCKER_TEST=1 ;;
    --help|-h)                   usage; exit 0 ;;
    *)                           warn "Unknown option: $arg (use --help)";;
  esac
done

# ---------- State file helpers ----------
# We store lines like:
#   PKG:<name>
#   REPO:docker
#   KEYRING:/etc/apt/keyrings/docker.gpg
#   GROUPADD:docker:<user>
#   WSLCONF_BACKUP:/home/.../.bettlebox-preflight/backups/wsl.conf-YYYYmmdd-HHMMSS
#   DOCKER_TEST:hello-world:IMAGE
#   DOCKER_TEST:hello-world:CONTAINER
append_state() {
  local line
  for line in "$@"; do
    grep -qxF "$line" "$STATE_FILE" || echo "$line" >> "$STATE_FILE"
  done
}
remove_state_entries_exact() {
  local tmp; tmp="$(mktemp)"
  awk 'NR>0{print $0}' "$STATE_FILE" > "$tmp"
  local pattern
  for pattern in "$@"; do
    sed -i "\|^${pattern}\$|d" "$tmp"
  done
  mv "$tmp" "$STATE_FILE"
}
grep_state_prefix() { awk -v pfx="$1" 'index($0,pfx)==1{print $0}' "$STATE_FILE"; }
list_installed_by_script_pkgs(){ grep_state_prefix "PKG:" | cut -d: -f2- | awk 'NF{print $0}'; }

# ---------- APT helpers ----------
apt_is_installed(){ dpkg -s "$1" >/dev/null 2>&1; }
apt_install_if_missing() {
  local to_install=() pkg
  for pkg in "$@"; do apt_is_installed "$pkg" && info "Already installed: $pkg" || to_install+=("$pkg"); done
  [[ ${#to_install[@]} -eq 0 ]] && { info "No new packages to install."; return 0; }
  if [[ $DRY_RUN -eq 1 ]]; then
    info "[DRY-RUN] Would: sudo apt-get update -y && sudo apt-get install -y ${to_install[*]}"
    info "[DRY-RUN] Would record: ${to_install[*]}"
    return 0
  fi
  info "Installing: ${to_install[*]}"
  sudo apt-get update -y && sudo apt-get install -y "${to_install[@]}" || return 1
  local p; for p in "${to_install[@]}"; do append_state "PKG:${p}"; done
}
apt_purge_pkgs_tracked(){
  local pkgs=("$@"); [[ ${#pkgs[@]} -eq 0 ]] && { info "No tracked packages to uninstall."; return 0; }
  if [[ $DRY_RUN -eq 1 ]]; then
    info "[DRY-RUN] Would purge: ${pkgs[*]}"; info "[DRY-RUN] Would run: sudo apt-get autoremove -y"; return 0; fi
  local actually_installed=() p
  for p in "${pkgs[@]}"; do apt_is_installed "$p" && actually_installed+=("$p") || { info "Skipping (not installed): $p"; remove_state_entries_exact "PKG:${p}"; }; done
  if [[ ${#actually_installed[@]} -gt 0 ]]; then
    sudo apt-get purge -y "${actually_installed[@]}" || warn "Purge completed with some errors."
    sudo apt-get autoremove -y || true
    for p in "${actually_installed[@]}"; do remove_state_entries_exact "PKG:${p}"; done
  fi
}

# ---------- Checks (each prints PASS/WARN/FAIL) ----------
check_distro(){
  local id=""; local version_id=""; [[ -r /etc/os-release ]] && . /etc/os-release
  id="${ID:-}"; version_id="${VERSION_ID:-}"
  if [[ "$id" != "ubuntu" ]]; then fail "Not running Ubuntu (detected: ${id:-unknown}). Ubuntu 20.04+ is recommended."; REQUIRED_FAILS=$((REQUIRED_FAILS+1)); return; fi
  local major="${version_id%%.*}"
  [[ -z "$major" || "$major" -lt 20 ]] && { fail "Ubuntu $version_id detected; need Ubuntu 20.04+."; REQUIRED_FAILS=$((REQUIRED_FAILS+1)); } \
                                        || pass "Ubuntu $version_id detected."
}
check_wsl2(){
  local osrel; osrel="$(uname -r 2>/dev/null || true)"
  if grep -qi "microsoft" /proc/version 2>/dev/null || echo "$osrel" | grep -qi "microsoft"; then
    echo "$osrel" | grep -q "WSL2" && pass "WSL2 kernel detected ($osrel)." || warn "WSL detected; kernel not explicitly WSL2 ($osrel)."
  else warn "Not running under WSL (fine if native/VM Linux)."; fi
  [[ -d /run/systemd/system ]] && pass "systemd appears active." || warn "systemd not active. Use --set-wslconf-systemd then 'wsl --shutdown' in Windows."
}
check_network(){
  getent hosts beetlebox.org >/dev/null 2>&1 && pass "DNS OK (beetlebox.org)." || { fail "DNS cannot resolve beetlebox.org."; REQUIRED_FAILS=$((REQUIRED_FAILS+1)); }
  has_cmd curl && curl -sS --max-time 10 -I https://beetlebox.org >/dev/null 2>&1 && pass "HTTPS reachability OK (beetlebox.org)." \
               || { fail "Cannot reach https://beetlebox.org via curl."; REQUIRED_FAILS=$((REQUIRED_FAILS+1)); }
}
check_resources(){
  local cpus mem_kb mem_gb avail_gb
  cpus="$(nproc 2>/dev/null || echo 1)"
  mem_kb="$(grep -i '^MemTotal:' /proc/meminfo | awk '{print $2}')"
  mem_gb=$(( (mem_kb + 1024*1024 - 1) / (1024*1024) ))
  avail_gb="$(df -Pm / | awk 'NR==2 {print int($4/1024)}')"
  local min_cpus=2 min_mem=4 min_disk=15
  [[ "$cpus" -ge "$min_cpus" ]] && pass "CPU cores: $cpus (>= $min_cpus)." || { fail "CPU cores: $cpus (< $min_cpus)."; REQUIRED_FAILS=$((REQUIRED_FAILS+1)); }
  [[ "$mem_gb" -ge "$min_mem" ]] && pass "RAM: ~${mem_gb}GB (>= ${min_mem}GB)." || { fail "RAM: ~${mem_gb}GB (< ${min_mem}GB)."; REQUIRED_FAILS=$((REQUIRED_FAILS+1)); }
  [[ "$avail_gb" -ge "$min_disk" ]] && pass "Disk free on /: ${avail_gb}GB (>= ${min_disk}GB)." || { fail "Disk free on /: ${avail_gb}GB (< ${min_disk}GB)."; REQUIRED_FAILS=$((REQUIRED_FAILS+1)); }
}
check_docker(){
  has_cmd docker || { warn "docker CLI not found."; return; }
  pass "docker CLI found: $(docker --version 2>/dev/null | head -n1)"
  docker info >/dev/null 2>&1 && pass "Docker daemon reachable." || warn "Docker daemon not reachable (enable Desktop or start Engine)."
  id -nG "$USER" | grep -qw docker && pass "User '$USER' is in 'docker' group." || warn "User '$USER' not in 'docker' group (you may need sudo)."
}
check_basics(){
  local missing=0
  for c in git curl python3; do has_cmd "$c" && pass "$c present ($( "$c" --version 2>/dev/null | head -n1 ))" || { fail "$c not found."; missing=1; REQUIRED_FAILS=$((REQUIRED_FAILS+1)); }; done
  has_cmd gcc && has_cmd make && pass "build-essential present (gcc/make found)." || { fail "build-essential not fully present (gcc/make missing)."; REQUIRED_FAILS=$((REQUIRED_FAILS+1)); }
}
check_optional_tools(){
  has_cmd kubectl && pass "kubectl present ($(kubectl version --client --short 2>/dev/null | tr -d '\n'))" || { warn "kubectl not found (optional)."; OPTIONAL_FAILS=$((OPTIONAL_FAILS+1)); }
  has_cmd helm && pass "helm present ($(helm version --short 2>/dev/null | tr -d '\n'))" || { warn "helm not found (optional)."; OPTIONAL_FAILS=$((OPTIONAL_FAILS+1)); }
  (has_cmd qemu-system-x86_64 || has_cmd qemu-system-aarch64) && pass "QEMU present (system targets available)." || { warn "QEMU not found (optional)."; OPTIONAL_FAILS=$((OPTIONAL_FAILS+1)); }
}
check_devices(){
  ls /dev/tty* >/dev/null 2>&1 && pass "/dev/tty* present (serial interfaces)." || { warn "No /dev/tty* visible. For HIL in WSL2, use usbipd-win."; OPTIONAL_FAILS=$((OPTIONAL_FAILS+1)); }
  [[ -e /dev/kvm ]] && pass "/dev/kvm present (KVM accel)." || { warn "/dev/kvm not present (normal in WSL2). QEMU will use software emulation."; OPTIONAL_FAILS=$((OPTIONAL_FAILS+1)); }
}
run_checks(){
  echo -e "${BOLD}Beetlebox/Embedded CI Preflight for Ubuntu (WSL2)${RESET}"
  echo "-----------------------------------------------------------------"
  check_distro; check_wsl2; check_network; check_resources; check_docker; check_basics; check_optional_tools; check_devices
  echo "-----------------------------------------------------------------"
  [[ $REQUIRED_FAILS -eq 0 ]] && pass "All REQUIRED checks passed." || fail "There were $REQUIRED_FAILS REQUIRED failures."
  [[ $OPTIONAL_FAILS -gt 0 ]] && warn "$OPTIONAL_FAILS OPTIONAL items missing (consider installing)."
  echo; info "Tips:"; echo " - After changing /etc/wsl.conf: in Windows PowerShell run:  wsl --shutdown"
  echo " - Docker Desktop: Settings → Resources → WSL Integration → enable for this distro."
  echo " - Docker Engine: ensure systemd is enabled (see --set-wslconf-systemd)."
  echo " - USB/HIL: 'usbipd wsl list' / 'usbipd wsl attach --busid <id>' on Windows."
  echo
}

# ---------- WSL conf helpers (with backups) ----------
backup_wslconf(){
  local src="$WSLCONF_PATH"; local ts; ts="$(timestamp)"; local dest="${BACKUP_DIR}/wsl.conf-${ts}"
  if [[ $DRY_RUN -eq 1 ]]; then info "[DRY-RUN] Would back up ${src} to ${dest}"; return 0; fi
  if [[ -f "$src" ]]; then sudo cp -a "$src" "$dest"; else sudo bash -c "touch '$dest'"; fi
  append_state "WSLCONF_BACKUP:${dest}"; info "Backed up ${src} to ${dest}"
}
set_wslconf_systemd(){
  backup_wslconf || { fail "Backup failed; aborting edit."; return 1; }
  local src="$WSLCONF_PATH"; local tmp; tmp="$(mktemp)"
  if [[ $DRY_RUN -eq 1 ]]; then info "[DRY-RUN] Would ensure [boot] systemd=true in ${src}"; return 0; fi
  sudo bash -c "cat '${src}' 2>/dev/null" | awk '
    BEGIN{inboot=0; seenboot=0; seensystemd=0}
    { if ($0 ~ /^\[boot\]/) {inboot=1; seenboot=1; print; next}
      if ($0 ~ /^\[/ && $0 !~ /^\[boot\]/) { if (inboot && !seensystemd) print "systemd=true"; inboot=0; print; next }
      if (inboot && $0 ~ /^[[:space:]]*systemd[[:space:]]*=/) { print "systemd=true"; seensystemd=1; next }
      print
    }
    END{ if (seenboot==0) {print "[boot]"; print "systemd=true"} else if (inboot && seensystemd==0) print "systemd=true" }
  ' > "$tmp"
  has_cmd diff && sudo bash -c "diff -u '${src}' '${tmp}' || true" | sed 's/^/    /' || true
  sudo install -m 0644 "$tmp" "$src"; rm -f "$tmp"
  pass "${src} updated with [boot] systemd=true"; info "In Windows PowerShell:  wsl --shutdown"
}
show_wslconf_backups(){
  local list; list="$(ls -1t "${BACKUP_DIR}"/wsl.conf-* 2>/dev/null || true)"
  [[ -z "$list" ]] && { info "No backups found in ${BACKUP_DIR}"; return 0; }
  local i=0; echo "Available backups (newest first):"
  while IFS= read -r f; do echo "  [$i] $f"; i=$((i+1)); done <<< "$list"
}
restore_wslconf_latest(){
  local latest; latest="$(ls -1t "${BACKUP_DIR}"/wsl.conf-* 2>/dev/null | head -n1 || true)"
  [[ -z "$latest" ]] && { warn "No backups found in ${BACKUP_DIR}"; return 0; }
  if [[ $DRY_RUN -eq 1 ]]; then info "[DRY-RUN] Would restore ${latest} -> ${WSLCONF_PATH}"; return 0; fi
  sudo install -m 0644 "$latest" "${WSLCONF_PATH}"; pass "Restored ${WSLCONF_PATH} from ${latest}"; info "Then:  wsl --shutdown"
}
restore_wslconf_specific(){
  local val="$1" target=""
  [[ -z "$val" ]] && { fail "--restore-wslconf requires a value"; return 1; }
  if [[ "$val" =~ ^[0-9]+$ ]]; then
    local list; mapfile -t list < <(ls -1t "${BACKUP_DIR}"/wsl.conf-* 2>/dev/null || true)
    [[ ${#list[@]} -eq 0 ]] && { warn "No backups found in ${BACKUP_DIR}"; return 0; }
    (( val < 0 || val >= ${#list[@]} )) && { fail "Index $val out of range (0..$(( ${#list[@]}-1 )))"; return 1; }
    target="${list[$val]}"
  else
    target="$val"
    case "$target" in "${BACKUP_DIR}"/wsl.conf-*) : ;; *) fail "Backup must be under ${BACKUP_DIR}"; return 1 ;; esac
    [[ -f "$target" ]] || { fail "Backup not found: $target"; return 1; }
  fi
  if [[ $DRY_RUN -eq 1 ]]; then info "[DRY-RUN] Would restore ${target} -> ${WSLCONF_PATH}"; return 0; fi
  sudo install -m 0644 "$target" "${WSLCONF_PATH}"; pass "Restored ${WSLCONF_PATH} from ${target}"; info "Then:  wsl --shutdown"
}

# ---------- Docker Engine (CE) helpers ----------
ubuntu_codename(){
  local codename=""; [[ -r /etc/os-release ]] && . /etc/os-release && codename="${VERSION_CODENAME:-}"
  if [[ -z "$codename" && $(has_cmd lsb_release && echo yes) == "yes" ]]; then codename="$(lsb_release -cs 2>/dev/null || true)"; fi
  echo "${codename}"
}
ensure_systemd_hint(){
  [[ -d /run/systemd/system ]] && return 0
  warn "systemd is NOT active. Use --set-wslconf-systemd, then in Windows PowerShell:  wsl --shutdown"
}
install_docker_engine(){
  ensure_systemd_hint
  local prereq=(ca-certificates curl gnupg)
  apt_install_if_missing "${prereq[@]}" || { fail "Failed to install prerequisites."; return 1; }
  local keyring="/etc/apt/keyrings/docker.gpg" repofile="/etc/apt/sources.list.d/docker.list" codename; codename="$(ubuntu_codename)"
  [[ -z "$codename" ]] && { fail "Unable to determine Ubuntu codename."; return 1; }
  if [[ $DRY_RUN -eq 1 ]]; then info "[DRY-RUN] Would add Docker apt repo/key for '${codename}'"
  else
    sudo install -m 0755 -d /etc/apt/keyrings
    if [[ ! -f "$keyring" ]]; then curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o "$keyring"; sudo chmod a+r "$keyring"; append_state "KEYRING:${keyring}"; fi
    if [[ ! -f "$repofile" ]]; then echo "deb [arch=$(dpkg --print-architecture) signed-by=${keyring}] https://download.docker.com/linux/ubuntu ${codename} stable" | sudo tee "$repofile" >/dev/null; append_state "REPO:docker"; fi
  fi
  local pkgs=(docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin)
  apt_install_if_missing "${pkgs[@]}" || { fail "Failed to install Docker packages."; return 1; }
  if [[ $DRY_RUN -eq 1 ]]; then info "[DRY-RUN] Would enable/start docker service"
  else
    if has_cmd systemctl && [[ -d /run/systemd/system ]]; then sudo systemctl enable --now docker || warn "systemctl enable/start failed."
    else has_cmd service && sudo service docker start || warn "Could not start docker service (no systemd)."; fi
  fi
  if [[ $NO_GROUP -eq 0 ]]; then
    id -nG "$USER" | grep -qw docker && info "User '$USER' already in docker group." || {
      if [[ $DRY_RUN -eq 1 ]]; then info "[DRY-RUN] Would add $USER to docker group"
      else sudo usermod -aG docker "$USER" && append_state "GROUPADD:docker:${USER}" || warn "Failed to add user to docker group."; info "Use 'newgrp docker' or restart shell."; fi
    }
  else info "Skipping docker group modification (--no-group)."; fi
  has_cmd docker && { [[ $DRY_RUN -eq 1 ]] && info "[DRY-RUN] Would run 'docker version'" || docker version >/dev/null 2>&1 && pass "Docker CLI/daemon appears functional."; }
}
purge_docker_engine(){
  if [[ $DRY_RUN -eq 1 ]]; then info "[DRY-RUN] Would stop docker/containerd services"
  else
    if has_cmd systemctl && [[ -d /run/systemd/system ]]; then sudo systemctl stop docker 2>/dev/null || true; sudo systemctl stop containerd 2>/dev/null || true
    else has_cmd service && sudo service docker stop 2>/dev/null || true; fi
  fi
  local dpkg_list; mapfile -t dpkg_list < <(list_installed_by_script_pkgs | grep -E '^(docker-ce|docker-ce-cli|containerd\.io|docker-buildx-plugin|docker-compose-plugin)$' || true)
  local known_pkgs=(docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin)
  declare -A want_purge=(); local p; for p in "${dpkg_list[@]}"; do want_purge["$p"]=1; done; for p in "${known_pkgs[@]}"; do want_purge["$p"]=1; done
  local purge_list=("${!want_purge[@]}"); apt_purge_pkgs_tracked "${purge_list[@]}"
  local keyring_lines; mapfile -t keyring_lines < <(grep_state_prefix "KEYRING:"); local repo_lines; mapfile -t repo_lines < <(grep_state_prefix "REPO:")
  if [[ $DRY_RUN -eq 1 ]]; then
    [[ ${#keyring_lines[@]} -gt 0 ]] && info "[DRY-RUN] Would remove keyrings"
    [[ ${#repo_lines[@]} -gt 0 ]] && info "[DRY-RUN] Would remove Docker apt repo file"
  else
    local line path
    for line in "${keyring_lines[@]}"; do path="${line#KEYRING:}"; [[ -f "$path" ]] && { sudo rm -f "$path"; remove_state_entries_exact "$line"; info "Removed keyring: $path"; }; done
    if [[ ${#repo_lines[@]} -gt 0 && -f /etc/apt/sources.list.d/docker.list ]]; then sudo rm -f /etc/apt/sources.list.d/docker.list && remove_state_entries_exact "REPO:docker"; info "Removed Docker apt repo." ; fi
    sudo apt-get update -y || true
  fi
  local group_lines; mapfile -t group_lines < <(grep_state_prefix "GROUPADD:")
  if [[ ${#group_lines[@]} -gt 0 ]]; then
    local gl g_user
    for gl in "${group_lines[@]}"; do g_user="$(echo "$gl" | cut -d: -f3)"
      if [[ $DRY_RUN -eq 1 ]]; then info "[DRY-RUN] Would: sudo gpasswd -d $g_user docker"
      else has_cmd gpasswd && sudo gpasswd -d "$g_user" docker || warn "Run manually: sudo gpasswd -d $g_user docker"; remove_state_entries_exact "$gl"; fi
    done
  fi
  if [[ $NUKE_DOCKER_DATA -eq 1 ]]; then [[ $DRY_RUN -eq 1 ]] && info "[DRY-RUN] Would remove /var/lib/docker /var/lib/containerd" || { sudo rm -rf /var/lib/docker /var/lib/containerd || true; info "Removed Docker data directories."; }
  else info "Docker data preserved. Use --nuke-docker-data to remove it."; fi
}

# ---------- Docker smoke test helpers ----------
docker_hello(){
  if ! has_cmd docker; then fail "docker CLI not found."; return 1; fi
  if ! docker info >/dev/null 2>&1; then fail "Docker daemon not reachable."; return 1; fi
  local img="hello-world"; local pulled=0
  if ! docker image inspect "$img" >/dev/null 2>&1; then
    info "Pulling $img ..."
    docker pull "$img" >/dev/null || { fail "Failed to pull $img"; return 1; }
    append_state "DOCKER_TEST:${img}:IMAGE"; pulled=1
  else
    info "Image already present: $img"
  fi
  info "Running $img ..."
  local cname="bettlebox-preflight-hello"
  docker rm -f "$cname" >/dev/null 2>&1 || true
  if docker run --name "$cname" --rm "$img" >/dev/null 2>&1; then
    pass "hello-world ran successfully."
    append_state "DOCKER_TEST:${img}:CONTAINER"
    return 0
  else
    fail "hello-world run failed."
    [[ $pulled -eq 0 ]] || true
    return 1
  fi
}
docker_cleanup_hello(){
  local img="hello-world" cname="bettlebox-preflight-hello"
  grep -qxF "DOCKER_TEST:${img}:IMAGE" "$STATE_FILE" || { info "No recorded test image to clean."; return 0; }
  has_cmd docker || { warn "docker CLI not found; cannot clean."; return 0; }
  docker rm -f "$cname" >/dev/null 2>&1 || true
  docker rmi "$img" >/dev/null 2>&1 && info "Removed image: $img" || warn "Failed to remove image: $img"
  remove_state_entries_exact "DOCKER_TEST:${img}:IMAGE" "DOCKER_TEST:${img}:CONTAINER"
  return 0
}

# ---------- Original installers ----------
perform_installs(){
  local basics=(git curl build-essential python3 python3-pip)
  local qemu=(qemu-system)
  [[ $INSTALL_BASICS -eq 1 ]] && apt_install_if_missing "${basics[@]}" || true
  [[ $INSTALL_QEMU -eq 1   ]] && apt_install_if_missing "${qemu[@]}"   || true
  [[ $INSTALL_DOCKER_ENGINE -eq 1 ]] && install_docker_engine || true
}
perform_uninstall(){
  local pkgs; mapfile -t pkgs < <(list_installed_by_script_pkgs)
  apt_purge_pkgs_tracked "${pkgs[@]}"
  if [[ ! -s "$STATE_FILE" ]]; then rm -f "$STATE_FILE"; info "All tracked packages removed. State cleared."
  else info "Remaining tracked entries in ${STATE_FILE}:"; nl -ba "$STATE_FILE"; fi
}

# ---------- Self-test (safe; mocked) ----------
self_test(){
  local tmpdir; tmpdir="$(mktemp -d)"
  trap "rm -rf '$tmpdir'" EXIT

  local ok=0 failc=0
  local mock="$tmpdir/etc"; mkdir -p "$mock"
  local orig_wsl="$WSLCONF_PATH"; WSLCONF_PATH="${mock}/wsl.conf"

  backup_wslconf && ((ok++)) || ((failc++))
  set_wslconf_systemd && ((ok++)) || ((failc++))
  grep -q "^\[boot\]" "$WSLCONF_PATH" && grep -q "^systemd=true" "$WSLCONF_PATH" && ((ok++)) || ((failc++))

  local before after
  before="$(sha1sum "$WSLCONF_PATH" | awk '{print $1}')"
  set_wslconf_systemd && ((ok++)) || ((failc++))
  after="$(sha1sum "$WSLCONF_PATH" | awk '{print $1}')"
  [[ "$before" == "$after" ]] && ((ok++)) || ((failc++))

  show_wslconf_backups && ((ok++)) || ((failc++))
  restore_wslconf_latest && ((ok++)) || ((failc++))
  local after_restore; after_restore="$(sha1sum "$WSLCONF_PATH" | awk '{print $1}')"
  [[ "$after_restore" == "$after" ]] && ((ok++)) || ((failc++))

  append_state "PKG:unit-test" "PKG:unit-test" "REPO:docker"
  local count_pkg; count_pkg="$(grep -c '^PKG:unit-test$' "$STATE_FILE" || true)"
  [[ "$count_pkg" -eq 1 ]] && ((ok++)) || ((failc++))

  apt_purge_pkgs_tracked "unit-test" && ((ok++)) || ((failc++))
  ! grep -q '^PKG:unit-test$' "$STATE_FILE" && ((ok++)) || ((failc++))

  echo "---- SELF-TEST SUMMARY ----"
  echo "Passed: $ok  Failed: $failc"

  WSLCONF_PATH="$orig_wsl"
  [[ $failc -eq 0 ]]
}

# ---------- Entry point ----------
main(){
  [[ $SELF_TEST -eq 1            ]] && { self_test; exit $?; }
  [[ $SET_WSLCONF_SYSTEMD -eq 1  ]] && { set_wslconf_systemd; exit $?; }
  [[ $RESTORE_WSLCONF_LATEST -eq 1 ]] && { restore_wslconf_latest; exit $?; }
  [[ $SHOW_WSLCONF_BACKUPS -eq 1 ]] && { show_wslconf_backups; exit $?; }
  [[ -n "$RESTORE_WSLCONF_ARG"   ]] && { restore_wslconf_specific "$RESTORE_WSLCONF_ARG"; exit $?; }
  [[ $PURGE_DOCKER_ENGINE -eq 1  ]] && { purge_docker_engine; exit $?; }
  [[ $HELLO_DOCKER -eq 1         ]] && { docker_hello; exit $?; }
  [[ $CLEANUP_DOCKER_TEST -eq 1  ]] && { docker_cleanup_hello; exit $?; }
  [[ $DO_UNINSTALL -eq 1         ]] && { perform_uninstall; exit $?; }

  run_checks
  perform_installs
  [[ $REQUIRED_FAILS -eq 0 ]]
}

main "$@"

