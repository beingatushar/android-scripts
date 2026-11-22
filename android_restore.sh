#!/usr/bin/env bash
# =============================================================================
#  android_restore.sh  -  restore a backup made by android_backup.sh
#
#    ./android_restore.sh                        newest complete backup, everything
#    ./android_restore.sh --list                 show available backups
#    ./android_restore.sh --choose               pick a backup from a menu
#    ./android_restore.sh --from 20261122_101500
#    ./android_restore.sh --only storage,apps    restore some components only
#
#  Components: apps, appdata (root only), storage, contacts, calllog, sms
#  Storage restore only ADDS missing files by default (never overwrites);
#  use --overwrite to also replace files that differ from the backup.
# =============================================================================
set -Eeuo pipefail
shopt -s nullglob

# ================================ settings ==================================
BACKUP_ROOT="$HOME/android_full_backups"
PHONE_ROOT="/storage/emulated/0"
COMPONENTS="apps,appdata,storage,contacts,calllog,sms"
OVERWRITE=0             # storage: also replace phone files that differ from the backup
INCLUDE_ANDROID_DATA=0  # push Android/data + Android/obb back (other apps' folders)
REINSTALL_APPS=0        # reinstall apps that are already installed
DO_LEGACY=0             # run `adb restore` for a legacy backup.ab, if present
DRY_RUN=0
ASSUME_YES=0
ADB_SERIAL="${ADB_SERIAL:-}"
# ============================================================================

FROM="" CHOOSE=0 LIST=0
usage() {
  cat <<EOF
Usage: $(basename "$0") [options]

  --list                  list backups and exit
  --choose                choose a backup from a numbered menu
  --from NAME             restore this backup (folder name, e.g. 20261122_101500)
  --only LIST             comma list of: apps,appdata,storage,contacts,calllog,sms
  --overwrite             storage: replace phone files that differ from the backup
  --include-android-data  storage: also push Android/data and Android/obb
  --reinstall-apps        reinstall apps that are already on the phone
  --legacy                also run 'adb restore' on legacy/backup.ab (tap on phone)
  --dry-run               show what would happen, change nothing
  -y, --yes               do not ask for confirmation
  --serial ID             device to use when several are connected
  -h, --help              show this help

Default: the newest complete backup in $BACKUP_ROOT, all components.
EOF
}

WARNINGS=()
log()  { printf '%s  %s\n' "$(date '+%F %T')" "$*"; }
warn() { log "WARN: $*"; WARNINGS+=("$*"); }
die()  { log "ERROR: $*"; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || die "missing '$1' (install: $2)"; }
adbc()   { if [[ -n "$ADB_SERIAL" ]]; then command adb -s "$ADB_SERIAL" "$@"; else command adb "$@"; fi; }
ashell() { { adbc shell "$@" 2>/dev/null || true; } | tr -d '\r'; }
rq()     { local s=${1//\'/\'\\\'\'}; printf "'%s'" "$s"; }
has()    { [[ ",$COMPONENTS," == *",$1,"* ]]; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --list)                 LIST=1 ;;
    --choose)               CHOOSE=1 ;;
    --from)                 FROM="${2:?--from needs a backup name}"; shift ;;
    --only)                 COMPONENTS="${2:?--only needs a list}"; shift ;;
    --overwrite)            OVERWRITE=1 ;;
    --include-android-data) INCLUDE_ANDROID_DATA=1 ;;
    --reinstall-apps)       REINSTALL_APPS=1 ;;
    --legacy)               DO_LEGACY=1 ;;
    --dry-run)              DRY_RUN=1 ;;
    -y|--yes)               ASSUME_YES=1 ;;
    --serial)               ADB_SERIAL="${2:?--serial needs a value}"; shift ;;
    -h|--help)              usage; exit 0 ;;
    *)                      usage; die "unknown option: $1" ;;
  esac
  shift
done

# ----------------------------------------------------------- pick backup ---
mapfile -t BACKUPS < <(find "$BACKUP_ROOT" -mindepth 1 -maxdepth 1 -type d -regextype posix-extended \
                         -regex '.*/[0-9]{8}_[0-9]{6}' -printf '%f\n' 2>/dev/null | sort)
info_get() { grep -m1 "^$2=" "$BACKUP_ROOT/$1/BACKUP_INFO.txt" 2>/dev/null | cut -d= -f2- || true; }
is_complete() { [[ -f "$BACKUP_ROOT/$1/.complete" ]]; }

show_list() {
  printf '%4s  %-16s  %-9s  %-24s  %s\n' "#" "BACKUP" "STATUS" "DEVICE" "SIZE"
  local i=0 b st
  for b in "${BACKUPS[@]}"; do
    i=$((i + 1))
    if is_complete "$b"; then st="complete"; else st="partial"; fi
    printf '%4d  %-16s  %-9s  %-24s  %s\n' "$i" "$b" "$st" "$(info_get "$b" device)" "$(info_get "$b" total_size)"
  done
}

(( ${#BACKUPS[@]} )) || die "no backups found in $BACKUP_ROOT"
if (( LIST )); then show_list; exit 0; fi

NAME=""
if [[ -n "$FROM" ]]; then
  [[ -d "$BACKUP_ROOT/$FROM" ]] || die "no such backup: $FROM (use --list)"
  NAME="$FROM"
elif (( CHOOSE )); then
  show_list
  read -rp "Backup number to restore [Enter = newest complete]: " pick
  if [[ -n "$pick" ]]; then
    [[ "$pick" =~ ^[0-9]+$ ]] && (( pick >= 1 && pick <= ${#BACKUPS[@]} )) || die "invalid choice: $pick"
    NAME="${BACKUPS[$((pick - 1))]}"
  fi
fi
if [[ -z "$NAME" ]]; then
  for (( i = ${#BACKUPS[@]} - 1; i >= 0; i-- )); do
    if is_complete "${BACKUPS[$i]}"; then NAME="${BACKUPS[$i]}"; break; fi
  done
  [[ -n "$NAME" ]] || die "no complete backup found (use --from to force a partial one)"
fi
SRC="$BACKUP_ROOT/$NAME"

need adb "sudo apt install adb"
need python3 "sudo apt install python3"

LOGDIR="$BACKUP_ROOT/restore_logs/$(date +%Y%m%d_%H%M%S)"
mkdir -p "$LOGDIR"
exec > >(tee -a "$LOGDIR/restore.log") 2>&1
trap 'log "ERROR at line $LINENO: $BASH_COMMAND"' ERR

HELPER=$(mktemp /tmp/android_restore_helper.XXXXXX.py)
STAY_ON_ORIG=""
on_exit() {
  if [[ -n "$STAY_ON_ORIG" && "$STAY_ON_ORIG" != "null" ]]; then
    ashell "settings put global stay_on_while_plugged_in $STAY_ON_ORIG" >/dev/null || true
  fi
  rm -f "$HELPER"
  rm -rf "$BACKUP_ROOT/.restore_stage"
}
trap on_exit EXIT

# =========================== embedded python helper ==========================
cat >"$HELPER" <<'PY'
"""Helper for android_restore.sh: storage sync and call-log insert."""
import argparse
import csv
import datetime as dt
import json
import os
import shlex
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

q = shlex.quote


def log(msg):
    print(f"{dt.datetime.now():%Y-%m-%d %H:%M:%S}  {msg}", flush=True)


def adb(*args):
    cmd = ["adb"]
    if os.environ.get("ADB_SERIAL"):
        cmd += ["-s", os.environ["ADB_SERIAL"]]
    return subprocess.run(cmd + list(args), capture_output=True, text=True, errors="replace")


def shell(command):
    r = adb("shell", command)
    return r.returncode, r.stdout.replace("\r", ""), r.stderr.replace("\r", "")


def run_on_phone(lines, name):
    fd, local = tempfile.mkstemp(suffix=".sh")
    with os.fdopen(fd, "w", encoding="utf-8") as f:
        f.write("\n".join(lines) + "\n")
    remote = f"/data/local/tmp/{name}"
    try:
        r = adb("push", local, remote)
        if r.returncode != 0:
            raise RuntimeError(f"could not copy {name} to the phone: {r.stderr.strip()[-300:]}")
        _, out, err = shell(f"sh {remote}; rm -f {remote}")
        return out, err
    finally:
        os.unlink(local)


def iso(ts):
    return dt.datetime.fromtimestamp(ts).strftime("%Y-%m-%d %H:%M:%S") if ts else ""


# ------------------------------------------------------------------ storage --
def phone_listing(phone_root):
    out, _ = run_on_phone([f"cd {q(phone_root)} || exit 1",
                           "find . -type f -exec stat -c '%s|%Y|%n' {} + 2>/dev/null"], "abk_list.sh")
    res = {}
    for line in out.splitlines():
        parts = line.split("|", 2)
        if len(parts) == 3 and parts[0].isdigit():
            rel = parts[2][2:] if parts[2].startswith("./") else parts[2]
            res[rel] = (int(parts[0]), int(parts[1]))
    return res


def touch_on_phone(items, phone_root):
    if not items:
        return
    out, _ = run_on_phone(["f=/data/local/tmp/.abk_probe",
                           "touch $f && touch -d @1500000000 $f && stat -c %Y $f",
                           "rm -f $f"], "abk_probe.sh")
    epoch_ok = out.strip().endswith("1500000000")
    lines = []
    for rel, ts in items:
        target = q(f"{phone_root}/{rel}")
        lines.append(f"touch -d @{int(ts)} {target}" if epoch_ok
                     else f"touch -t {dt.datetime.fromtimestamp(ts):%Y%m%d%H%M.%S} {target}")
    for i in range(0, len(lines), 5000):
        _, err = run_on_phone(lines[i:i + 5000], "abk_touch.sh")
        if err.strip():
            log(f"storage: touch reported: {err.strip().splitlines()[0][:200]}")


def cmd_storage(a):
    src, root = Path(a.storage), a.phone_root
    if not src.is_dir():
        log("storage: this backup has no storage folder")
        return 0
    local = {}
    for dirpath, dirnames, filenames in os.walk(src):
        rel_dir = os.path.relpath(dirpath, src).replace(os.sep, "/")
        rel_dir = "" if rel_dir == "." else rel_dir
        if not a.include_android_data:
            dirnames[:] = [d for d in dirnames
                           if (f"{rel_dir}/{d}" if rel_dir else d) not in ("Android/data", "Android/obb")]
        for fn in filenames:
            rel = f"{rel_dir}/{fn}" if rel_dir else fn
            st = os.stat(os.path.join(dirpath, fn))
            local[rel] = (st.st_size, int(st.st_mtime))
    log(f"storage: backup holds {len(local)} files; reading what the phone has ...")
    phone = phone_listing(root)
    log(f"storage: phone has {len(phone)} files")

    todo = []
    for rel, (size, mt) in sorted(local.items()):
        cur = phone.get(rel)
        if cur is None:
            todo.append((rel, "missing"))
        elif a.overwrite and (cur[0] != size or cur[1] != mt):
            todo.append((rel, "differs"))
    total = sum(local[r][0] for r, _ in todo)
    log(f"storage: {len(todo)} files to push ({total / 1048576:.0f} MB)")
    with open(a.report, "w", newline="", encoding="utf-8") as f:
        w = csv.writer(f)
        w.writerow(["file", "reason", "backup_size", "backup_mtime", "phone_size", "phone_mtime"])
        for rel, why in todo:
            cur = phone.get(rel, (None, None))
            w.writerow([rel, why, local[rel][0], iso(local[rel][1]), cur[0], iso(cur[1])])
    if a.dry_run or not todo:
        return 0

    stage = Path(a.stage)
    shutil.rmtree(stage, ignore_errors=True)
    for rel, _ in todo:
        dst = stage / rel
        dst.parent.mkdir(parents=True, exist_ok=True)
        try:
            os.link(src / rel, dst)
        except OSError:
            shutil.copy2(src / rel, dst)
    ok = True
    for entry in sorted(stage.iterdir()):
        log(f"storage: pushing {entry.name} ...")
        r = adb("push", str(entry), root + "/")
        if r.returncode != 0:
            ok = False
            log(f"storage: push problem in {entry.name}: {(r.stderr or r.stdout).strip()[-400:]}")
    shutil.rmtree(stage, ignore_errors=True)

    touch_on_phone([(rel, local[rel][1]) for rel, _ in todo], root)
    log("storage: verifying ...")
    after = phone_listing(root)
    bad = [rel for rel, _ in todo if after.get(rel) != local[rel]]
    if bad:
        Path(a.report).with_name("storage_mismatches.txt").write_text("\n".join(bad) + "\n")
        log(f"storage: {len(bad)} files differ after restore (storage_mismatches.txt)")
        return 1
    log(f"storage: {len(todo)} files restored with their original dates")
    return 0 if ok else 1


# ------------------------------------------------------------------ calllog --
def parse_rows(text, cols):
    raws, cur = [], None
    for line in text.rstrip("\n").split("\n"):
        if line.startswith("Row: "):
            if cur is not None:
                raws.append(cur)
            cur = line.split(" ", 2)[2] if line.count(" ") >= 2 else ""
        elif cur is not None:
            cur += "\n" + line
    if cur is not None:
        raws.append(cur)
    out = []
    for raw in raws:
        rec, pos = {}, 0
        for i, c in enumerate(cols):
            if not raw.startswith(f"{c}=", pos):
                break
            start = pos + len(c) + 1
            if i + 1 < len(cols):
                end = raw.find(f", {cols[i + 1]}=", start)
                if end < 0:
                    break
                val, pos = raw[start:end], end + 2
            else:
                val = raw[start:]
            rec[c] = None if val == "NULL" else val
        out.append(rec)
    return out


def denied(text):
    return "Permission Denial" in text or "SecurityException" in text


def cmd_calllog(a):
    calls = json.loads(Path(a.json).read_text(encoding="utf-8"))
    _, out, err = shell("content query --uri content://call_log/calls --projection number:date")
    if denied(out + err):
        log("call log: adb is not allowed to read the call history on this phone")
        return 3
    have = set()
    if "No result found" not in out:
        have = {(r.get("number") or "", r.get("date") or "") for r in parse_rows(out, ["number", "date"])}
    todo = [c for c in calls if ((c.get("number") or ""), str(c.get("date") or "")) not in have]
    log(f"call log: {len(calls)} in backup, {len(calls) - len(todo)} already on phone, {len(todo)} to add")
    if a.dry_run or not todo:
        return 0

    def line(c):
        binds = [f"number:s:{c.get('number') or ''}", f"date:l:{c.get('date') or 0}",
                 f"duration:l:{c.get('duration') or 0}", f"type:i:{c.get('type') or 1}", "new:i:0"]
        if c.get("presentation"):
            binds.append(f"presentation:i:{c['presentation']}")
        if c.get("name"):
            binds.append(f"name:s:{c['name']}")
        return "content insert --uri content://call_log/calls " + " ".join(f"--bind {q(b)}" for b in binds)

    _, out, err = shell(line(todo[0]))
    if denied(out + err) or "Error" in out + err:
        log(f"call log: adb may not write call history here ({(out + err).strip()[:160]})")
        return 3
    lines = [line(c) for c in todo[1:]]
    for i in range(0, len(lines), 2000):
        run_on_phone(lines[i:i + 2000], "abk_calls.sh")
    log(f"call log: added {len(todo)} entries")
    return 0


def main():
    p = argparse.ArgumentParser()
    sub = p.add_subparsers(dest="cmd", required=True)
    s = sub.add_parser("storage")
    s.add_argument("--storage", required=True)
    s.add_argument("--phone-root", required=True)
    s.add_argument("--stage", required=True)
    s.add_argument("--report", required=True)
    s.add_argument("--overwrite", action="store_true")
    s.add_argument("--include-android-data", action="store_true")
    s.add_argument("--dry-run", action="store_true")
    c = sub.add_parser("calllog")
    c.add_argument("--json", required=True)
    c.add_argument("--dry-run", action="store_true")
    a = p.parse_args()
    return cmd_storage(a) if a.cmd == "storage" else cmd_calllog(a)


if __name__ == "__main__":
    sys.exit(main())
PY

# ================================== steps ===================================
check_device() {
  local list n
  list=$(command adb devices 2>/dev/null | awk 'NR>1 && NF')
  if [[ -z "$ADB_SERIAL" ]]; then
    n=$(awk '$2=="device"' <<<"$list" | wc -l)
    if (( n == 0 )); then
      if grep -q unauthorized <<<"$list"; then die "phone is 'unauthorized': unlock it and accept the USB debugging prompt"; fi
      die "no phone found: plug it in and enable USB debugging"
    fi
    if (( n > 1 )); then die "several devices connected: pass --serial <id>"; fi
    ADB_SERIAL=$(awk '$2=="device"{print $1; exit}' <<<"$list")
  fi
  export ADB_SERIAL
  BRAND=$(ashell getprop ro.product.brand)
  MODEL=$(ashell getprop ro.product.model)
  log "phone: $BRAND $MODEL (serial $ADB_SERIAL)"
  local was
  was=$(info_get "$NAME" serial)
  if [[ -n "$was" && "$was" != "$ADB_SERIAL" ]]; then
    warn "this backup was made on a different phone ($(info_get "$NAME" device), serial $was)"
  fi
}

HAS_ROOT=0
detect_root() {
  local out
  out=$(timeout 30 adbc shell 'su -c id' 2>/dev/null || true)
  if [[ "$out" == *"uid=0"* ]]; then HAS_ROOT=1; log "root: available"; else log "root: not available"; fi
}

installed_packages() { ashell "pm list packages" | sed -n 's/^package://p'; }

restore_apps() {
  local d="$SRC/apps"
  if [[ ! -d "$d" ]]; then warn "apps: not in this backup"; return 0; fi
  local installed ok=0 skip=0 fail=0 pdir pkg
  installed=$(installed_packages)
  for pdir in "$d"/*/; do
    pkg=$(basename "$pdir")
    local apks=("$pdir"*.apk)
    if (( ${#apks[@]} == 0 )); then continue; fi
    if (( ! REINSTALL_APPS )) && grep -qxF "$pkg" <<<"$installed"; then skip=$((skip + 1)); continue; fi
    if (( DRY_RUN )); then log "apps: would install $pkg (${#apks[@]} APK files)"; ok=$((ok + 1)); continue; fi
    if adbc install-multiple -r -i com.android.vending "${apks[@]}" >>"$LOGDIR/apps_install.log" 2>&1 \
       || adbc install-multiple -r "${apks[@]}" >>"$LOGDIR/apps_install.log" 2>&1; then
      ok=$((ok + 1))
    else
      fail=$((fail + 1))
      warn "apps: could not install $pkg (see apps_install.log)"
    fi
  done
  log "apps: installed $ok, already present $skip, failed $fail"
  if (( fail )); then
    log "      realme/OPPO: enable 'Install via USB' and 'Disable permission monitoring' in Developer options"
  fi
}

restore_appdata() {
  local d="$SRC/root/appdata"
  if [[ ! -d "$d" ]]; then return 0; fi
  if (( ! HAS_ROOT )); then warn "appdata: backup has app data but this phone is not rooted; skipped"; return 0; fi
  local installed tarf pkg uid ok=0
  installed=$(installed_packages)
  for tarf in "$d"/*.tar; do
    pkg=$(basename "$tarf" .tar)
    if ! grep -qxF "$pkg" <<<"$installed"; then warn "appdata: $pkg is not installed; skipped"; continue; fi
    uid=$(ashell "su -c 'stat -c %u /data/data/$pkg'")
    if [[ ! "$uid" =~ ^[0-9]+$ ]]; then warn "appdata: no data folder for $pkg; skipped"; continue; fi
    if (( DRY_RUN )); then log "appdata: would restore $pkg (uid $uid)"; continue; fi
    ashell "am force-stop $pkg" >/dev/null
    adbc push "$tarf" /data/local/tmp/abk_app.tar >/dev/null
    local res
    res=$(ashell "su -c 'cd /data && tar -xf /data/local/tmp/abk_app.tar && for d in /data/data/$pkg /data/user_de/0/$pkg; do [ -d \$d ] && find \$d -path \$d/cache -prune -o -path \$d/code_cache -prune -o -exec chown $uid:$uid {} + ; done; restorecon -RF /data/data/$pkg /data/user_de/0/$pkg 2>/dev/null; rm -f /data/local/tmp/abk_app.tar; echo ABK_OK'")
    if [[ "$res" == *ABK_OK* ]]; then ok=$((ok + 1)); else warn "appdata: restore of $pkg may have failed"; fi
  done
  log "appdata: restored $ok apps (reboot the phone afterwards)"
}

restore_storage() {
  local args=(storage --storage "$SRC/storage" --phone-root "$PHONE_ROOT"
              --stage "$BACKUP_ROOT/.restore_stage" --report "$LOGDIR/storage_plan.csv")
  if (( OVERWRITE )); then args+=(--overwrite); fi
  if (( INCLUDE_ANDROID_DATA )); then args+=(--include-android-data); fi
  if (( DRY_RUN )); then args+=(--dry-run); fi
  if ! python3 "$HELPER" "${args[@]}"; then warn "storage: finished with problems (see log)"; fi
  if (( ! DRY_RUN )); then
    ashell "content call --uri content://media/ --method scan_volume --arg external_primary" >/dev/null
  fi
}

restore_contacts() {
  local vcf="$SRC/messages/contacts.vcf"
  if [[ ! -s "$vcf" ]]; then warn "contacts: no contacts.vcf in this backup"; return 0; fi
  local dst="$PHONE_ROOT/Download/restored_contacts_$NAME.vcf"
  if (( DRY_RUN )); then log "contacts: would copy contacts.vcf to $dst"; return 0; fi
  adbc push "$vcf" "$dst" >/dev/null || { warn "contacts: could not copy the .vcf"; return 0; }
  ashell "am start -a android.intent.action.VIEW -t text/x-vcard -d $(rq "file://$dst")" >/dev/null
  log "contacts: copied to Download/$(basename "$dst")"
  log "          if no import screen opened: Contacts app > Settings > Import > .vcf file"
  log "          (skip this if your contacts already sync from Google, or you'll get duplicates)"
}

restore_calllog() {
  local j="$SRC/messages/calllog.json"
  if [[ ! -s "$j" ]]; then warn "call log: not in this backup"; return 0; fi
  local args=(calllog --json "$j") rc=0
  if (( DRY_RUN )); then args+=(--dry-run); fi
  python3 "$HELPER" "${args[@]}" || rc=$?
  if (( rc == 3 )); then
    warn "call log: adb cannot write call history here; restore calls.xml with SMS Backup & Restore (see SMS step)"
  elif (( rc != 0 )); then
    warn "call log: restore finished with errors"
  fi
}

restore_sms() {
  local m="$SRC/messages" files=() f
  if [[ -s "$m/sms.xml" ]]; then files+=("$m/sms.xml"); fi
  if [[ -s "$m/calls.xml" ]]; then files+=("$m/calls.xml"); fi
  if (( ${#files[@]} == 0 )); then warn "SMS: no sms.xml / calls.xml in this backup"; return 0; fi
  local dst="$PHONE_ROOT/Download/SMSBackupRestore_$NAME"
  if (( DRY_RUN )); then log "SMS: would copy sms.xml/calls.xml to $dst"; return 0; fi
  ashell "mkdir -p $(rq "$dst")" >/dev/null
  for f in "${files[@]}"; do adbc push "$f" "$dst/" >/dev/null || warn "SMS: could not copy $(basename "$f")"; done
  log "SMS: files copied to Download/SMSBackupRestore_$NAME/"
  log "     Android lets only the default SMS app write messages, so finish on the phone:"
  log "     install 'SMS Backup & Restore' (SyncTech) > Restore > pick the files in that folder."
  log "     It asks to be the default SMS app for the restore; switch back afterwards."
}

restore_legacy() {
  local ab="$SRC/legacy/backup.ab"
  if [[ ! -s "$ab" ]]; then warn "legacy: no backup.ab in this backup"; return 0; fi
  if (( DRY_RUN )); then log "legacy: would run adb restore"; return 0; fi
  log "legacy: unlock the phone and tap 'Restore my data' ..."
  adbc restore "$ab" || warn "legacy: adb restore failed"
}

# =================================== run ====================================
log "android_restore.sh: backup $NAME ($(info_get "$NAME" device), $(info_get "$NAME" total_size))"
if ! is_complete "$NAME"; then warn "this backup is PARTIAL (the backup run did not finish)"; fi
if (( DRY_RUN )); then log "DRY RUN: nothing will be changed"; fi
check_device
if has appdata && [[ -d "$SRC/root/appdata" ]]; then detect_root; fi

log "components: $COMPONENTS"
if (( OVERWRITE )); then log "storage mode: overwrite phone files that differ from the backup"; fi
if (( ! ASSUME_YES && ! DRY_RUN )); then
  read -rp "Restore '$NAME' to $BRAND $MODEL? Type YES to continue: " answer
  [[ "$answer" == "YES" ]] || die "cancelled"
fi

STAY_ON_ORIG=$(ashell "settings get global stay_on_while_plugged_in")
ashell "svc power stayon usb" >/dev/null

if has apps;     then restore_apps; fi
if has appdata;  then restore_appdata; fi
if has storage;  then restore_storage; fi
if has contacts; then restore_contacts; fi
if has calllog;  then restore_calllog; fi
if has sms;      then restore_sms; fi
if (( DO_LEGACY )); then restore_legacy; fi

log "------------------------------------------------------------"
log "Restore finished. Log: $LOGDIR/restore.log"
if (( ${#WARNINGS[@]} )); then
  log "Warnings (${#WARNINGS[@]}):"
  printf '    - %s\n' "${WARNINGS[@]}"
fi
