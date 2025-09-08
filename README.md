# Bettlebox Preflight (WSL2 Ubuntu) — Quickstart

This guide walks you through saving, running, and using `bettlebox-preflight.sh` on **WSL2 Ubuntu**.  
It’s the same set of steps we discussed, formatted for Git check-in.

> **Tip:** Commands are safe to copy–paste. Anything that changes your system is clearly labeled.

---

## Table of Contents
1. [Save the script](#1-save-the-script)
2. [Run basic checks (safe)](#2-run-basic-checks-safe)
3. [Enable systemd for WSL (once)](#3-enable-systemd-for-wsl-once)
4. [Install what you need](#4-install-what-you-need)
5. [Sanity tests](#5-sanity-tests)
6. [Useful day-to-day flags](#6-useful-day-to-day-flags)
7. [Uninstall / cleanup](#7-uninstall--cleanup)
8. [Troubleshooting](#8-troubleshooting)
9. [Appendix: Flags reference](#9-appendix-flags-reference)

---

## 1) Save the script

In your **WSL2 Ubuntu** shell:
```bash
nano bettlebox-preflight.sh
# paste the whole script, save & exit (Ctrl+O, Enter, Ctrl+X)
chmod +x bettlebox-preflight.sh
```

---

## 2) Run basic checks (safe)

Runs environment checks for Ubuntu/WSL2, network, resources, Docker, basics, optional tools, and device hints.
```bash
./bettlebox-preflight.sh
```

- **PASS/WARN/FAIL** messages make it easy to see what’s good and what needs attention.
- Exit status is **0** when all required checks pass (handy for CI).

---

## 3) Enable systemd for WSL (once)

Backs up `/etc/wsl.conf` and ensures:
```ini
[boot]
systemd=true
```
Command:
```bash
./bettlebox-preflight.sh --set-wslconf-systemd
```
Now in **Windows PowerShell** (not Ubuntu), restart WSL:
```powershell
wsl --shutdown
```
Reopen your Ubuntu terminal (systemd will be active).

- See backups:
```bash
./bettlebox-preflight.sh --show-wslconf-backups
```
- Restore the latest:
```bash
./bettlebox-preflight.sh --restore-wslconf-latest
```
- Or restore by index / filename:
```bash
./bettlebox-preflight.sh --restore-wslconf=0   # 0 = newest
./bettlebox-preflight.sh --restore-wslconf="$HOME/.bettlebox-preflight/backups/wsl.conf-YYYYmmdd-HHMMSS"
```

---

## 4) Install what you need

- **Developer basics**:
```bash
./bettlebox-preflight.sh --install-basics
```
- **QEMU (optional)**:
```bash
./bettlebox-preflight.sh --install-qemu
```
- **Docker Engine (inside Ubuntu WSL2)**:
```bash
./bettlebox-preflight.sh --install-docker-engine
# (optional) avoid adding your user to the docker group:
./bettlebox-preflight.sh --install-docker-engine --no-group
```

> **Note:** If you change `/etc/wsl.conf`, remember to run `wsl --shutdown` in **Windows PowerShell** before using Docker Engine with systemd.

---

## 5) Sanity tests

- **Built-in self-test** (no real system changes; uses a mocked area):
```bash
./bettlebox-preflight.sh --self-test
```
- **Docker hello-world**:
```bash
./bettlebox-preflight.sh --hello-docker
# later, clean up only what the script pulled:
./bettlebox-preflight.sh --cleanup-docker-test
```

---

## 6) Useful day-to-day flags

- **Dry run**: see what would happen without making changes:
```bash
./bettlebox-preflight.sh --dry-run --install-docker-engine
```
- **Backups & restore helpers**:
```bash
./bettlebox-preflight.sh --show-wslconf-backups
./bettlebox-preflight.sh --restore-wslconf-latest
./bettlebox-preflight.sh --restore-wslconf=0
```
- **Docker Engine maintenance**:
```bash
./bettlebox-preflight.sh --purge-docker-engine
./bettlebox-preflight.sh --purge-docker-engine --nuke-docker-data
```

---

## 7) Uninstall / cleanup

- Remove everything the script installed **except** Docker Engine:
```bash
./bettlebox-preflight.sh --uninstall
```
- Purge Docker Engine + repo/keyring (and optionally **all** Docker data):
```bash
./bettlebox-preflight.sh --purge-docker-engine
./bettlebox-preflight.sh --purge-docker-engine --nuke-docker-data
```

---

## 8) Troubleshooting

- After changing `/etc/wsl.conf`, always do `wsl --shutdown` in **Windows PowerShell**, then reopen Ubuntu.
- If `docker info` fails, ensure systemd is active (run Step 3), then:
```bash
sudo systemctl status docker
sudo systemctl restart docker
```
- USB/HIL on WSL2: install `usbipd-win` on Windows; attach devices via:
```powershell
usbipd wsl list
usbipd wsl attach --busid <id>
```

---

## 9) Appendix: Flags reference

**Checks / info (default)**  
Runs without flags to perform checks.

**Installers (tracked; reversible)**
- `--install-basics` — `git`, `curl`, `build-essential`, `python3`, `python3-pip`
- `--install-qemu` — `qemu-system`
- `--install-docker-engine` — Docker CE (`docker-ce`, `docker-ce-cli`, `containerd.io`, `docker-buildx-plugin`, `docker-compose-plugin`)
  - `--no-group` — Skip adding current user to the `docker` group

**WSL systemd helpers (with backups)**
- `--set-wslconf-systemd` — backup `/etc/wsl.conf` and set `[boot] systemd=true`
- `--show-wslconf-backups` — list timestamped backups
- `--restore-wslconf-latest` — restore most recent backup
- `--restore-wslconf=<index|filename>` — restore by index (from list) or by full path under `~/.bettlebox-preflight/backups`

**Uninstall / purge**
- `--uninstall` — remove packages the script installed (except Docker Engine)
- `--purge-docker-engine` — purge Docker CE packages + apt repo + keyring and remove user from `docker` group if this script added it
  - `--nuke-docker-data` — also delete `/var/lib/docker` and `/var/lib/containerd`

**Tests**
- `--self-test` — runs mocked tests safely
- `--hello-docker` — pulls & runs `hello-world` and tracks it
- `--cleanup-docker-test` — deletes the tracked `hello-world` image/container

**Other**
- `--dry-run` — simulate actions without making changes
- `--help` — show usage

---

**License:** MIT 
**Maintainer:** _Hugh Nguyen_


