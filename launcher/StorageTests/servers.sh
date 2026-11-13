#!/bin/bash
# The servers of the storage tests, on 127.0.0.1 of this machine: Samba
# (SMB), MinIO (S3), pyftpdlib (FTP, one server with MLSD and one without),
# OpenSSH (SFTP) and a stand-in for Google's (drive_server.py, Google Drive),
# each with the test IPAs of make_ipas.py in its games folder, and
# DIR/servers.json, which says where each server is, its accounts and what
# it holds, for the tests (README.md).
#
#     launcher/StorageTests/servers.sh start DIR [--big-mib N]
#     launcher/StorageTests/servers.sh stop DIR
#
# With --big-mib, the games folders also hold an IPA of N MiB, past 4 GiB
# as a game's is with N = 4112, when the disk has room for it four times:
# on the server, in MinIO, installed by a test and copied back by it.
#
# It adds a user, cartouche-test, with a password it makes up, which Samba
# and OpenSSH sign in, and runs smbd and sshd as root, with sudo: only on a
# throwaway machine, as GitHub's runners are (CI=true), or with
# CARTOUCHE_STORAGE_THROWAWAY=1. stop stops the servers, removes the user
# and DIR. DIR must be where every user can go, as in /tmp: smbd reads the
# shared folders there as cartouche-test and as nobody.
#
# Needs python3, git and, on macOS, brew install samba minio minio-mc; on
# Linux, Samba, OpenSSH's server, and minio and mc in PATH. nxnative's
# pack_ipa.py, at the commit Cartouche pins (catalog/nxnative.commit), and
# pyftpdlib (requirements-ftp.txt) are fetched into DIR.

set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"

TEST_USER=cartouche-test
GAMES="Jeux"
SMALL_NAME="Essai de stockage [0100CA27C0DE0000].ipa"
BIG_NAME="Gros essai [0100CA27C0DE1000].ipa"
OLDER="Anciens jeux"
HIDDEN=".cachée.txt"
READ_ONLY="Lecture seule"
SHARE="Partage"
READ_ONLY_SHARE="Lecture seule"
GUEST_SHARE="Invités"
BUCKET=cartouche
REGION=eu-west-3
SMB_PORT=4450
S3_PORT=9000
FTP_PORT=2121
FTP_LIST_PORT=2122
SFTP_PORT=2222
DRIVE_PORT=9100
# The player's OAuth client and Google account, made up: the stand-in knows
# no other.
DRIVE_CLIENT=123456789012-cartouchetests.apps.googleusercontent.com
DRIVE_ACCOUNT=joueur@example.com

usage() {
  echo "usage: $0 start DIR [--big-mib N]" >&2
  echo "       $0 stop DIR" >&2
  exit 2
}

say() { printf '%s\n' "$*"; }
fail() { printf '%s\n' "$*" >&2; exit 1; }

as_root() {
  if [ "$(id -u)" -eq 0 ]; then "$@"; else sudo "$@"; fi
}

# Runs a command as root, in a process group of its own. smbd, when it
# stops, stops every process of its group (killkids): in this script's,
# that would be the runner's, with the job's other steps. Its own setsid
# fails when sudo has made it a group's leader, as sudo does in a terminal
# (use_pty), so smbd starts with --no-process-group, in the group this
# makes.
as_root_alone() {
  as_root "$(command -v python3)" -c 'import os, sys
if os.getpgrp() != os.getpid():
    os.setsid()
os.execv(sys.argv[1], sys.argv[1:])' "$@"
}

is_mac() { [ "$(uname -s)" = Darwin ]; }

secret() { python3 -c 'import secrets; print(secrets.token_hex(16))'; }

# Waits until something listens on PORT; otherwise shows the end of LOG.
wait_port() {
  local port="$1" name="$2" log="$3" tries=0
  until python3 -c 'import socket, sys; socket.create_connection(("127.0.0.1", int(sys.argv[1])), 1).close()' "$port" 2>/dev/null; do
    tries=$((tries + 1))
    if [ "$tries" -ge 120 ]; then
      say "$name is not listening on port $port after a minute. Its log, $log:" >&2
      as_root tail -n 80 "$log" >&2 || true
      exit 1
    fi
    sleep 0.5
  done
}

# Copies SOURCE to TARGET, as a clone of it where the disk can (APFS, Btrfs).
clone() {
  if is_mac; then
    cp -c "$1" "$2" 2>/dev/null || cp "$1" "$2"
  else
    cp --reflink=auto "$1" "$2"
  fi
}

# A server's root, as the user running this script: the games folder with
# the test IPAs, a folder of older ones and a hidden file, and the folder
# the player's account will only read, with the small IPA.
seed() {
  local root="$1"
  mkdir -p "$root/$GAMES/$OLDER" "$root/$READ_ONLY"
  clone "$IPAS/small.ipa" "$root/$GAMES/$SMALL_NAME"
  if [ -f "$IPAS/big.ipa" ]; then
    clone "$IPAS/big.ipa" "$root/$GAMES/$BIG_NAME"
  fi
  clone "$IPAS/small.ipa" "$root/$GAMES/$OLDER/$SMALL_NAME"
  printf 'Un fichier caché, que Cartouche ne montre pas.\n' > "$root/$GAMES/$HIDDEN"
  clone "$IPAS/small.ipa" "$root/$READ_ONLY/$SMALL_NAME"
}

# Hands PATH to root, readable by everyone and writable by root only.
root_only() {
  as_root chown -R 0:0 "$1"
  as_root chmod -R u=rwX,go=rX "$1"
}

home_of() {
  if is_mac; then
    dscl . -read "/Users/$1" NFSHomeDirectory 2>/dev/null | awk '{print $2}'
  else
    getent passwd "$1" | cut -d: -f6
  fi
}

# MARK: The pieces

fetch_tools() {
  local commit
  commit="$(tr -d '[:space:]' < "$REPO/catalog/nxnative.commit")"
  rm -rf "$DIR/nxnative"
  git init -q "$DIR/nxnative"
  git -C "$DIR/nxnative" remote add origin https://github.com/seedds/nxnative.git
  git -C "$DIR/nxnative" sparse-checkout set --no-cone /dm/ios/tools/pack_ipa.py /dm/tools/shader_lib.py /dm/tools/romfs.py
  git -C "$DIR/nxnative" fetch -q --depth 1 --filter=blob:none origin "$commit"
  git -C "$DIR/nxnative" checkout -q FETCH_HEAD
  say "nxnative $commit: pack_ipa.py"

  python3 -m venv "$DIR/venv"
  "$DIR/venv/bin/pip" install --quiet --disable-pip-version-check --require-hashes -r "$HERE/requirements-ftp.txt"
}

make_ipas() {
  local big=()
  if [ "$BIG_MIB" -gt 0 ]; then
    # The IPA and MinIO's copy of it, then a test's install and its copy
    # back, and 3 GiB for the rest.
    local free_kib needed_kib
    free_kib="$(df -Pk "$DIR" | awk 'NR == 2 {print $4}')"
    needed_kib=$(( (BIG_MIB * 4 + 3072) * 1024 ))
    if [ "$free_kib" -ge "$needed_kib" ]; then
      big=(--big-mib "$BIG_MIB")
    else
      say "Not enough room for an IPA of $BIG_MIB MiB: $((free_kib / 1024)) MiB free, $((needed_kib / 1024)) needed. The tests of a game past 4 GiB will be skipped."
    fi
  fi
  python3 "$HERE/make_ipas.py" "$DIR/nxnative/dm/ios/tools/pack_ipa.py" "$DIR/fixtures" ${big[@]+"${big[@]}"}
  IPAS="$DIR/fixtures/ipas"
}

make_user() {
  if is_mac; then
    if id "$TEST_USER" >/dev/null 2>&1; then
      as_root dscl . -passwd "/Users/$TEST_USER" "$ACCOUNT_PASSWORD"
    else
      as_root sysadminctl -addUser "$TEST_USER" -fullName "Cartouche storage tests" \
        -password "$ACCOUNT_PASSWORD" -home "/Users/$TEST_USER" -shell /bin/zsh
    fi
    as_root createhomedir -c -u "$TEST_USER" >/dev/null 2>&1 || true
    # When Remote Login lets only some users in, cartouche-test is one.
    if dscl . -read /Groups/com.apple.access_ssh >/dev/null 2>&1; then
      as_root dseditgroup -o edit -a "$TEST_USER" -t user com.apple.access_ssh
    fi
  else
    if ! id "$TEST_USER" >/dev/null 2>&1; then
      as_root useradd --create-home --shell /bin/bash "$TEST_USER"
    fi
    printf '%s:%s\n' "$TEST_USER" "$ACCOUNT_PASSWORD" | as_root chpasswd
  fi
  id "$TEST_USER" >/dev/null || fail "Could not add the user $TEST_USER."
  TEST_HOME="$(home_of "$TEST_USER")"
  case "$TEST_HOME" in
    */"$TEST_USER") ;;
    *) fail "$TEST_USER's home is $TEST_HOME, not a folder of its own." ;;
  esac
  as_root mkdir -p "$TEST_HOME"
  as_root chown "$TEST_USER" "$TEST_HOME"
  # For the tests to look in it.
  as_root chmod 755 "$TEST_HOME"
}

start_smb() {
  local smb="$DIR/smb" smbd smbpasswd
  if is_mac; then
    smbd="$(command -v samba-dot-org-smbd || true)"
    if [ -z "$smbd" ] && command -v brew >/dev/null; then
      smbd="$(brew --prefix samba)/sbin/samba-dot-org-smbd"
    fi
  else
    smbd="$(command -v smbd || echo /usr/sbin/smbd)"
  fi
  [ -x "$smbd" ] || fail "Samba's smbd is missing (brew install samba)."
  smbpasswd="$(command -v smbpasswd || echo "$(dirname "$smbd")/../bin/smbpasswd")"
  [ -x "$smbpasswd" ] || fail "Samba's smbpasswd is missing."

  mkdir -p "$smb"
  # Samba's own folders, as smbd wants them: root's.
  as_root mkdir -p -m 755 "$smb/lock" "$smb/state" "$smb/cache" "$smb/pid" "$smb/ncalrpc" "$smb/log"
  as_root mkdir -p -m 700 "$smb/private"
  cat > "$smb/smb.conf" <<EOF
[global]
	server role = standalone server
	workgroup = WORKGROUP
	netbios name = CARTOUCHETEST
	server string = Cartouche storage tests
	interfaces = 127.0.0.1
	bind interfaces only = yes
	smb ports = $SMB_PORT
	disable netbios = yes
	private dir = $smb/private
	passdb backend = tdbsam:$smb/private/passdb.tdb
	lock directory = $smb/lock
	state directory = $smb/state
	cache directory = $smb/cache
	pid directory = $smb/pid
	ncalrpc dir = $smb/ncalrpc
	log file = $smb/log/%m.log
	max log size = 0
	log level = 1
	load printers = no
	printing = bsd
	printcap name = /dev/null
	disable spoolss = yes
	usershare max shares = 0
	# Each new folder made under its own name. Made under a temporary one,
	# it is renamed over an empty, locked folder of its name, as macOS has
	# no renameat2(RENAME_NOREPLACE), and macOS, as OpenBSD, refuses that
	# (Samba's bug 15801). A NAS, on Linux, has renameat2.
	vfs mkdir use tmp name = no
	map to guest = Bad User
	guest account = nobody

# The player's: their account reads and writes it, but for its folder
# $READ_ONLY, which is root's.
[$SHARE]
	path = $smb/share
	valid users = $TEST_USER
	read only = no

# Their account's files, which the shared folder lets it only read.
[$READ_ONLY_SHARE]
	path = $smb/readonly
	valid users = $TEST_USER
	read only = yes

# Root's files, which guests read.
[$GUEST_SHARE]
	path = $smb/guest
	guest ok = yes
	read only = yes
EOF

  seed "$smb/share"
  mkdir -p "$smb/readonly/$GAMES" "$smb/guest/$GAMES"
  clone "$IPAS/small.ipa" "$smb/readonly/$GAMES/$SMALL_NAME"
  clone "$IPAS/small.ipa" "$smb/guest/$GAMES/$SMALL_NAME"
  as_root chown -R "$TEST_USER" "$smb/share" "$smb/readonly"
  root_only "$smb/share/$READ_ONLY"
  root_only "$smb/guest"

  printf '%s\n%s\n' "$ACCOUNT_PASSWORD" "$ACCOUNT_PASSWORD" |
    as_root "$smbpasswd" -c "$smb/smb.conf" -a -s "$TEST_USER" >/dev/null
  as_root_alone "$smbd" --foreground --no-process-group --debug-stdout --configfile="$smb/smb.conf" < /dev/null > "$smb/smbd.log" 2>&1 &
  echo $! > "$smb/smbd.pid"
  wait_port "$SMB_PORT" smbd "$smb/smbd.log"
  say "SMB: Samba, $("$smbd" --version), on port $SMB_PORT"
}

start_sftp() {
  local ssh="$DIR/ssh" sshd=/usr/sbin/sshd
  [ -x "$sshd" ] || fail "OpenSSH's sshd is missing."
  mkdir -p "$ssh"
  rm -f "$ssh"/*_ed25519 "$ssh"/*_ed25519.pub
  ssh-keygen -q -t ed25519 -N "" -C "Cartouche storage tests" -f "$ssh/host_ed25519"
  ssh-keygen -q -t ed25519 -N "" -C "another server" -f "$ssh/other_ed25519"
  as_root chown 0:0 "$ssh/host_ed25519"
  cat > "$ssh/sshd_config" <<EOF
Port $SFTP_PORT
ListenAddress 127.0.0.1
HostKey $ssh/host_ed25519
PidFile $ssh/sshd.pid
AuthorizedKeysFile none
PubkeyAuthentication no
PasswordAuthentication yes
KbdInteractiveAuthentication no
PermitRootLogin no
AllowUsers $TEST_USER
UsePAM yes
Subsystem sftp internal-sftp
LogLevel VERBOSE
EOF
  # Made by this user, for the tests to read what sshd adds.
  : > "$ssh/sshd.log"
  chmod 644 "$ssh/sshd.log"

  as_root rm -rf "${TEST_HOME:?}/$GAMES" "${TEST_HOME:?}/$READ_ONLY" "${TEST_HOME:?}/Essais"
  rm -rf "$ssh/seed"
  seed "$ssh/seed"
  as_root mv "$ssh/seed/$GAMES" "$ssh/seed/$READ_ONLY" "$TEST_HOME/"
  as_root chown -R "$TEST_USER" "$TEST_HOME/$GAMES"
  as_root chmod -R a+rX "$TEST_HOME/$GAMES"
  root_only "$TEST_HOME/$READ_ONLY"

  if ! is_mac; then
    as_root mkdir -p /run/sshd
  fi
  as_root "$sshd" -t -f "$ssh/sshd_config"
  as_root "$sshd" -D -f "$ssh/sshd_config" -E "$ssh/sshd.log" < /dev/null > "$ssh/sshd.out" 2>&1 &
  echo $! > "$ssh/sshd.sudo.pid"
  wait_port "$SFTP_PORT" sshd "$ssh/sshd.log"
  say "SFTP: $(ssh -V 2>&1), on port $SFTP_PORT"
}

# FTP: NAME, PORT, the first of 50 passive ports, and --no-mlsd or nothing.
start_ftp() {
  local name="$1" port="$2" passive="$3"
  local ftp="$DIR/$name"
  shift 3
  mkdir -p "$ftp"
  rm -rf "$ftp/root"
  seed "$ftp/root"
  ( umask 077; printf '%s\n' "$FTP_PASSWORD" > "$ftp/password"; printf '%s\n' "$FTP_READER_PASSWORD" > "$ftp/reader-password" )
  "$DIR/venv/bin/python" "$HERE/ftp_server.py" --port "$port" --root "$ftp/root" \
    --user joueur --password-file "$ftp/password" \
    --reader lecteur --reader-password-file "$ftp/reader-password" \
    --read-only "$READ_ONLY" --passive "$passive-$((passive + 49))" "$@" < /dev/null >> "$ftp/ftp.log" 2>&1 &
  echo $! > "$ftp/ftp.pid"
  wait_port "$port" "pyftpdlib ($name)" "$ftp/ftp.log"
  say "FTP: pyftpdlib $("$DIR/venv/bin/python" -c 'import pyftpdlib; print(pyftpdlib.__ver__)'), on port $port${*:+, $*}"
}

# Google Drive: the stand-in for Google's sign-in and Drive API, with the
# player's My Drive in DIR/drive/root, and a sign-in the player made once,
# whose refresh token servers.json gives the tests.
start_drive() {
  local drive="$DIR/drive"
  mkdir -p "$drive"
  rm -rf "$drive/root" "$drive/data"
  seed "$drive/root"
  ( umask 077; printf '%s\n' "$DRIVE_REFRESH_TOKEN" > "$drive/refresh-token" )
  python3 "$HERE/drive_server.py" --port "$DRIVE_PORT" --root "$drive/root" --data "$drive/data" \
    --client-id "$DRIVE_CLIENT" --account "$DRIVE_ACCOUNT" --refresh-token-file "$drive/refresh-token" \
    --read-only "$READ_ONLY" --games "$GAMES" --small "$SMALL_NAME" < /dev/null >> "$drive/drive.log" 2>&1 &
  echo $! > "$drive/drive.pid"
  wait_port "$DRIVE_PORT" "Google's stand-in" "$drive/drive.log"
  say "Google Drive: a stand-in for Google's servers, $(python3 --version), on port $DRIVE_PORT"
}

start_s3() {
  local s3="$DIR/s3" minio mc tries=0
  minio="$(command -v minio || true)"
  mc="$(command -v mc || command -v mcli || true)"
  [ -n "$minio" ] || fail "MinIO is missing (brew install minio)."
  [ -n "$mc" ] || fail "MinIO's client, mc, is missing (brew install minio-mc)."
  mkdir -p "$s3/data" "$s3/mc"
  MINIO_ROOT_USER=cartouche-admin MINIO_ROOT_PASSWORD="$S3_ADMIN_SECRET" MINIO_SITE_REGION="$REGION" \
    MINIO_BROWSER=off MINIO_UPDATE=off \
    "$minio" server "$s3/data" --address "127.0.0.1:$S3_PORT" --console-address "127.0.0.1:$((S3_PORT + 1))" \
    < /dev/null >> "$s3/minio.log" 2>&1 &
  echo $! > "$s3/minio.pid"
  wait_port "$S3_PORT" MinIO "$s3/minio.log"
  until curl -fsS -o /dev/null "http://127.0.0.1:$S3_PORT/minio/health/ready"; do
    tries=$((tries + 1))
    [ "$tries" -lt 120 ] || fail "MinIO is not ready after a minute: $(tail -n 40 "$s3/minio.log")"
    sleep 0.5
  done

  export MC_CONFIG_DIR="$s3/mc"
  local m=("$mc" --quiet --no-color)
  "${m[@]}" alias set local "http://127.0.0.1:$S3_PORT" cartouche-admin "$S3_ADMIN_SECRET" >/dev/null
  "${m[@]}" mb --region "$REGION" "local/$BUCKET" >/dev/null
  "${m[@]}" cp "$IPAS/small.ipa" "local/$BUCKET/$GAMES/$SMALL_NAME" >/dev/null
  "${m[@]}" cp "$IPAS/small.ipa" "local/$BUCKET/$GAMES/$OLDER/$SMALL_NAME" >/dev/null
  if [ -f "$IPAS/big.ipa" ]; then
    "${m[@]}" cp "$IPAS/big.ipa" "local/$BUCKET/$GAMES/$BIG_NAME" >/dev/null
  fi
  printf 'Un fichier caché, que Cartouche ne montre pas.\n' > "$s3/hidden.txt"
  "${m[@]}" cp "$s3/hidden.txt" "local/$BUCKET/$GAMES/$HIDDEN" >/dev/null

  # The player's keys, and keys that only list and read the bucket.
  cat > "$s3/reader.json" <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {"Effect": "Allow", "Action": ["s3:ListBucket", "s3:GetBucketLocation"], "Resource": ["arn:aws:s3:::$BUCKET"]},
    {"Effect": "Allow", "Action": ["s3:GetObject"], "Resource": ["arn:aws:s3:::$BUCKET/*"]}
  ]
}
EOF
  "${m[@]}" admin user add local "$S3_PLAYER_KEY" "$S3_PLAYER_SECRET" >/dev/null
  "${m[@]}" admin policy attach local readwrite --user "$S3_PLAYER_KEY" >/dev/null
  "${m[@]}" admin policy create local cartouche-reader "$s3/reader.json" >/dev/null
  "${m[@]}" admin user add local "$S3_READER_KEY" "$S3_READER_SECRET" >/dev/null
  "${m[@]}" admin policy attach local cartouche-reader --user "$S3_READER_KEY" >/dev/null
  say "S3: $("$minio" --version | head -n 1), on port $S3_PORT, region $REGION"
}

write_servers() {
  local big_name=""
  if [ -f "$IPAS/big.ipa" ]; then big_name="$BIG_NAME"; fi
  DIR="$DIR" TEST_USER="$TEST_USER" TEST_HOME="$TEST_HOME" ACCOUNT_PASSWORD="$ACCOUNT_PASSWORD" \
  FTP_PASSWORD="$FTP_PASSWORD" FTP_READER_PASSWORD="$FTP_READER_PASSWORD" \
  S3_PLAYER_KEY="$S3_PLAYER_KEY" S3_PLAYER_SECRET="$S3_PLAYER_SECRET" \
  S3_READER_KEY="$S3_READER_KEY" S3_READER_SECRET="$S3_READER_SECRET" \
  DRIVE_PORT="$DRIVE_PORT" DRIVE_CLIENT="$DRIVE_CLIENT" DRIVE_ACCOUNT="$DRIVE_ACCOUNT" \
  DRIVE_REFRESH_TOKEN="$DRIVE_REFRESH_TOKEN" \
  GAMES="$GAMES" SMALL_NAME="$SMALL_NAME" BIG_NAME="$big_name" OLDER="$OLDER" HIDDEN="$HIDDEN" READ_ONLY="$READ_ONLY" \
  SHARE="$SHARE" READ_ONLY_SHARE="$READ_ONLY_SHARE" GUEST_SHARE="$GUEST_SHARE" BUCKET="$BUCKET" REGION="$REGION" \
  SMB_PORT="$SMB_PORT" S3_PORT="$S3_PORT" FTP_PORT="$FTP_PORT" FTP_LIST_PORT="$FTP_LIST_PORT" SFTP_PORT="$SFTP_PORT" \
  python3 - <<'PY'
import json
import os
from pathlib import Path

e = os.environ
d = Path(e["DIR"])


def account(port, user, password):
    return {"host": "127.0.0.1", "port": int(port), "user": user, "password": password}


def ftp(name, port, mlsd):
    return {
        "account": account(port, "joueur", e["FTP_PASSWORD"]),
        "reader": "lecteur",
        "readerPassword": e["FTP_READER_PASSWORD"],
        "mlsd": mlsd,
        "rootPath": str(d / name / "root"),
        "log": str(d / name / "ftp.log"),
    }


servers = {
    "games": e["GAMES"],
    "readOnlyFolder": e["READ_ONLY"],
    "smallName": e["SMALL_NAME"],
    "bigName": e["BIG_NAME"] or None,
    "olderFolder": e["OLDER"],
    "hiddenName": e["HIDDEN"],
    "fixtures": str(d / "fixtures" / "fixtures.json"),
    "smb": {
        "account": account(e["SMB_PORT"], e["TEST_USER"], e["ACCOUNT_PASSWORD"]),
        "share": e["SHARE"],
        "readOnlyShare": e["READ_ONLY_SHARE"],
        "guestShare": e["GUEST_SHARE"],
        "sharePath": str(d / "smb" / "share"),
    },
    "s3": {
        "address": f"http://127.0.0.1:{e['S3_PORT']}",
        "bucket": e["BUCKET"],
        "region": e["REGION"],
        "accessKey": e["S3_PLAYER_KEY"],
        "secretKey": e["S3_PLAYER_SECRET"],
        "readerAccessKey": e["S3_READER_KEY"],
        "readerSecretKey": e["S3_READER_SECRET"],
    },
    "ftp": ftp("ftp", e["FTP_PORT"], True),
    "ftpList": ftp("ftp-list", e["FTP_LIST_PORT"], False),
    "sftp": {
        "account": account(e["SFTP_PORT"], e["TEST_USER"], e["ACCOUNT_PASSWORD"]),
        "hostKey": (d / "ssh" / "host_ed25519.pub").read_text().strip(),
        "otherKey": (d / "ssh" / "other_ed25519.pub").read_text().strip(),
        "home": e["TEST_HOME"],
        "log": str(d / "ssh" / "sshd.log"),
    },
    "drive": {
        "address": f"http://127.0.0.1:{e['DRIVE_PORT']}",
        "clientID": e["DRIVE_CLIENT"],
        "account": e["DRIVE_ACCOUNT"],
        "refreshToken": e["DRIVE_REFRESH_TOKEN"],
        "log": str(d / "drive" / "drive.log"),
    },
}
path = d / "servers.json"
path.touch(mode=0o600)
path.write_text(json.dumps(servers, indent=2, ensure_ascii=False) + "\n")
PY
}

# MARK: Start and stop

start() {
  if [ "${CI:-}" != true ] && [ "${CARTOUCHE_STORAGE_THROWAWAY:-}" != 1 ]; then
    fail "This adds the user $TEST_USER and runs smbd and sshd as root: run it on a throwaway machine, with CARTOUCHE_STORAGE_THROWAWAY=1."
  fi
  for tool in python3 git curl ssh-keygen; do
    command -v "$tool" >/dev/null || fail "$tool is missing."
  done
  mkdir -p "$DIR"
  DIR="$(cd "$DIR" && pwd -P)"
  chmod 755 "$DIR"
  touch "$DIR/.cartouche-storage-servers"

  ACCOUNT_PASSWORD="$(secret)"
  FTP_PASSWORD="$(secret)"
  FTP_READER_PASSWORD="$(secret)"
  S3_ADMIN_SECRET="$(secret)"
  S3_PLAYER_KEY="CARTOUCHE$(secret | cut -c1-11 | tr '[:lower:]' '[:upper:]')"
  S3_PLAYER_SECRET="$(secret)"
  S3_READER_KEY="READER$(secret | cut -c1-14 | tr '[:lower:]' '[:upper:]')"
  S3_READER_SECRET="$(secret)"
  DRIVE_REFRESH_TOKEN="1//0$(secret)"

  fetch_tools
  make_ipas
  make_user
  start_smb
  start_sftp
  start_ftp ftp "$FTP_PORT" 30000
  start_ftp ftp-list "$FTP_LIST_PORT" 30050 --no-mlsd
  start_s3
  start_drive
  write_servers
  say "The servers are up: $DIR/servers.json"
}

stop() {
  [ -f "$DIR/.cartouche-storage-servers" ] || fail "$DIR holds no servers of this script."
  DIR="$(cd "$DIR" && pwd -P)"
  local pidfile
  for pidfile in "$DIR/ftp/ftp.pid" "$DIR/ftp-list/ftp.pid" "$DIR/s3/minio.pid" "$DIR/drive/drive.pid"; do
    if [ -f "$pidfile" ]; then kill "$(cat "$pidfile")" 2>/dev/null || true; fi
  done
  for pidfile in "$DIR/smb/smbd.pid" "$DIR/ssh/sshd.sudo.pid"; do
    if [ -f "$pidfile" ]; then as_root kill "$(cat "$pidfile")" 2>/dev/null || true; fi
  done
  as_root pkill -f -- "--configfile=$DIR/smb/smb.conf" 2>/dev/null || true
  as_root pkill -f -- "-f $DIR/ssh/sshd_config" 2>/dev/null || true
  if id "$TEST_USER" >/dev/null 2>&1; then
    if is_mac; then
      as_root sysadminctl -deleteUser "$TEST_USER" 2>/dev/null || true
    else
      as_root userdel -r "$TEST_USER" 2>/dev/null || true
    fi
  fi
  as_root rm -rf "$DIR"
  say "Stopped, and removed $DIR and the user $TEST_USER."
}

[ $# -ge 2 ] || usage
COMMAND="$1"
DIR="$2"
shift 2
BIG_MIB=0
while [ $# -gt 0 ]; do
  case "$1" in
    --big-mib) [ $# -ge 2 ] || usage; BIG_MIB="$2"; shift 2 ;;
    *) usage ;;
  esac
done
case "$COMMAND" in
  start) start ;;
  stop) stop ;;
  *) usage ;;
esac
