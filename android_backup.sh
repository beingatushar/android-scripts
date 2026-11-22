#!/usr/bin/env bash
# =============================================================================
#  android_backup.sh
#
#  Step 1  Fix the date of every photo/video on the phone, in place (same path).
#          Candidates: embedded EXIF/QuickTime date, date in the filename,
#          file modified time, and mtimes from older untouched copies (REF_MAPS).
#          Rule: the OLDEST calendar day wins; on that day a real time beats a
#          date-only value (12:00:00 placeholder, e.g. WhatsApp IMG-YYYYMMDD-WA).
#          The date is written INTO the file and set as the file's mtime.
#
#  Step 2  Back up the phone to  $BACKUP_ROOT/<timestamp>/
#            storage/   internal shared storage (DCIM, Pictures, WhatsApp, ...)
#            apps/      APKs of user-installed apps (incl. split APKs)
#            messages/  SMS, call log, contacts (.vcf), calendar, dictionary
#            device/    build props, settings, package lists, Wi-Fi names, accounts
#            root/      app data + system databases (only when rooted)
#
#  Storage is copied once; the date fixes are applied to that copy and only the
#  files that changed are pushed back, so nothing is transferred twice.
#
#  Needs: adb, python3, exiftool, tar   (optional: pv for a progress bar)
#  Usage: ./android_backup.sh [--dry-run] [--serial ID] [--help]
# =============================================================================
set -Eeuo pipefail
shopt -s nullglob

# ================================ settings ==================================
BACKUP_ROOT="$HOME/android_full_backups"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
BACKUP_DIR="${BACKUP_ROOT}/${TIMESTAMP}"

DO_STORAGE=1          # internal shared storage (/sdcard); needed by DO_METADATA
DO_METADATA=1         # fix photo/video dates on the phone (in place)
DO_APPS=1             # APKs of user-installed apps
DO_MESSAGES=1         # SMS, call log, contacts, calendar, user dictionary
DO_DEVICE_INFO=1      # props, settings, package lists, saved Wi-Fi names, accounts
DO_ROOT=auto          # auto | 1 | 0  -> app data + system databases when su works
DO_ADB_LEGACY=0       # legacy `adb backup` (tap needed on phone; nearly empty on Android 12+)

INCLUDE_ANDROID_DATA=1   # /sdcard/Android/data: often unreadable on Android 11+, tried anyway
INCLUDE_ANDROID_OBB=0    # /sdcard/Android/obb: large, re-downloadable game data
TAR_EXCLUDES=( '*/.thumbnails' )

# Older, untouched copies whose file times are trusted as real timestamps
# (only used by the date fix).  Format: "<folder on phone, relative to /sdcard>|<folder on PC>"
REF_MAPS=( "Android/media/com.whatsapp/WhatsApp/Media|$HOME/phone-backup" )

WORKERS=$(nproc)
PHONE_ROOT="/storage/emulated/0"
ADB_SERIAL="${ADB_SERIAL:-}"
DRY_RUN=0
FORCE=0
# ============================================================================

usage() {
  cat <<EOF
Usage: $(basename "$0") [options]

  --dry-run            never change the phone: back up as-is, only report the date fixes
  --serial ID          device to use when several are connected (see 'adb devices')
  --no-metadata        skip the date fix
  --no-storage         skip internal storage (also skips the date fix)
  --no-apps            skip APKs
  --no-messages        skip SMS / call log / contacts
  --root | --no-root   force / disable the root-only extras (default: auto-detect)
  --with-obb           include /sdcard/Android/obb
  --legacy-adb-backup  also run the old 'adb backup' (needs a tap on the phone)
  --force              continue even if the PC looks short on free space
  -h, --help           show this help

Backups go to: $BACKUP_ROOT/<timestamp>/
EOF
}

WARNINGS=()
log()  { printf '%s  %s\n' "$(date '+%F %T')" "$*"; }
warn() { log "WARN: $*"; WARNINGS+=("$*"); }
die()  { log "ERROR: $*"; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || die "missing '$1' (install: $2)"; }

adbc()   { if [[ -n "$ADB_SERIAL" ]]; then command adb -s "$ADB_SERIAL" "$@"; else command adb "$@"; fi; }
ashell() { { adbc shell "$@" 2>/dev/null || true; } | tr -d '\r'; }   # never fails
rq()     { local s=${1//\'/\'\\\'\'}; printf "'%s'" "$s"; }            # quote for the phone's sh

# ------------------------------------------------------------------ options --
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)           DRY_RUN=1 ;;
    --serial)            ADB_SERIAL="${2:?--serial needs a value}"; shift ;;
    --no-metadata)       DO_METADATA=0 ;;
    --no-storage)        DO_STORAGE=0; DO_METADATA=0 ;;
    --no-apps)           DO_APPS=0 ;;
    --no-messages)       DO_MESSAGES=0 ;;
    --root)              DO_ROOT=1 ;;
    --no-root)           DO_ROOT=0 ;;
    --with-obb)          INCLUDE_ANDROID_OBB=1 ;;
    --legacy-adb-backup) DO_ADB_LEGACY=1 ;;
    --force)             FORCE=1 ;;
    -h|--help)           usage; exit 0 ;;
    *)                   usage; die "unknown option: $1" ;;
  esac
  shift
done

need adb "sudo apt install adb"
need python3 "sudo apt install python3"
need tar "sudo apt install tar"
if (( DO_METADATA )); then need exiftool "sudo apt install libimage-exiftool-perl"; fi

mkdir -p "$BACKUP_DIR/logs"
LOG="$BACKUP_DIR/logs/backup.log"
exec > >(tee -a "$LOG") 2>&1
trap 'log "ERROR at line $LINENO: $BASH_COMMAND"' ERR

PROGRESS_TTY=/dev/null
if { : >/dev/tty; } 2>/dev/null; then PROGRESS_TTY=/dev/tty; fi

HELPER=$(mktemp /tmp/android_backup_helper.XXXXXX.py)
COMPLETED=0
STAY_ON_ORIG=""
STORAGE_FILES=0
HAS_ROOT=0

on_exit() {
  local rc=$?
  if [[ -n "$STAY_ON_ORIG" && "$STAY_ON_ORIG" != "null" ]]; then
    ashell "settings put global stay_on_while_plugged_in $STAY_ON_ORIG" >/dev/null || true
  fi
  rm -f "$HELPER"
  rm -rf "$BACKUP_DIR/.push_stage"
  if (( COMPLETED == 0 )); then
    log "Backup did NOT finish (exit code $rc). Partial data in $BACKUP_DIR is not marked complete."
  fi
}
trap on_exit EXIT

# =========================== embedded python helper ==========================
cat >"$HELPER" <<'PY'
"""Helper for android_backup.sh: photo/video date fixing and message export."""
import argparse
import csv
import datetime as dt
import json
import os
import re
import shlex
import shutil
import subprocess
import sys
import tempfile
import time
from collections import Counter
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
from xml.sax.saxutils import quoteattr

q = shlex.quote


_LOG_TZ = dt.datetime.now().astimezone().tzinfo   # PC time for log lines


def log(msg):
    print(f"{dt.datetime.now(_LOG_TZ):%Y-%m-%d %H:%M:%S}  {msg}", flush=True)


def adb(*args):
    cmd = ["adb"]
    if os.environ.get("ADB_SERIAL"):
        cmd += ["-s", os.environ["ADB_SERIAL"]]
    return subprocess.run(cmd + list(args), capture_output=True, text=True, errors="replace")


def shell(command):
    r = adb("shell", command)
    return r.returncode, r.stdout.replace("\r", ""), r.stderr.replace("\r", "")


def run_on_phone(lines, name):
    """Copy a small shell script to the phone, run it, return (stdout, stderr)."""
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


# ------------------------------------------------------------ date logic ----
IMAGE_EXTS = {".jpg", ".jpeg", ".png", ".gif", ".webp", ".heic", ".heif", ".bmp",
              ".tif", ".tiff", ".dng", ".arw", ".cr2", ".nef"}
VIDEO_EXTS = {".mp4", ".mov", ".m4v", ".3gp", ".3g2", ".mkv", ".webm", ".avi", ".mpg", ".mts"}
MEDIA_EXTS = IMAGE_EXTS | VIDEO_EXTS
# exiftool can safely write dates into these; the rest only get their file time fixed
WRITABLE_EXTS = {".jpg", ".jpeg", ".png", ".gif", ".webp", ".heic", ".heif", ".tif",
                 ".tiff", ".dng", ".mp4", ".mov", ".m4v", ".3gp", ".3g2"}
TAGS = ("DateTimeOriginal", "CreateDate", "MediaCreateDate")

MIN_TS = dt.datetime(2000, 1, 1).timestamp()
MAX_TS = time.time() + 86400


def valid(ts):
    if ts is None or not (MIN_TS <= ts <= MAX_TS):
        return False
    t = dt.datetime.fromtimestamp(ts)
    # Jan 1 00:00:00 is what reset camera clocks produce
    return not (t.month == 1 and t.day == 1 and (t.hour, t.minute, t.second) == (0, 0, 0))


def precision(ts):
    """12:00:00 exactly is treated as a date-only placeholder."""
    t = dt.datetime.fromtimestamp(ts)
    return "day" if (t.hour, t.minute, t.second) == (12, 0, 0) else "real"


def iso(ts):
    return dt.datetime.fromtimestamp(ts).strftime("%Y-%m-%d %H:%M:%S") if ts else ""


_Y = r"(20\d{2})"
_M = r"(0[1-9]|1[0-2])"
_D = r"(0[1-9]|[12]\d|3[01])"
_h = r"([01]\d|2[0-3])"
_mi = r"([0-5]\d)"
_s = r"([0-5]\d)"


def _ymd(m):
    g = [int(x) for x in m.groups()]
    try:
        if len(g) == 6:
            return dt.datetime(*g).timestamp()
        return dt.datetime(g[0], g[1], g[2], 12, 0, 0).timestamp()
    except ValueError:
        return None


def _ms(m):
    return int(m.group(1)) / 1000.0


# most specific first; "day" = the filename carries only a date
_RULES = [
    ("pixel",        rf"PXL_{_Y}{_M}{_D}_{_h}{_mi}{_s}",                 _ymd, "real"),
    ("burst",        rf"BURST{_Y}{_M}{_D}{_h}{_mi}{_s}",                 _ymd, "real"),
    ("camera",       rf"(?<!\d){_Y}{_M}{_D}[_-]{_h}{_mi}{_s}",           _ymd, "real"),
    ("screenshot",   rf"Screenshot[_-]?{_Y}-{_M}-{_D}-{_h}-{_mi}-{_s}",  _ymd, "real"),
    ("dated_time",   rf"{_Y}-{_M}-{_D}[ _T]{_h}[-.:]{_mi}[-.:]{_s}",     _ymd, "real"),
    ("signal",       rf"signal-{_Y}-{_M}-{_D}-{_h}{_mi}{_s}",            _ymd, "real"),
    ("facebook",     r"FB_IMG_(1\d{12})(?!\d)",                          _ms,  "real"),
    ("xiaoying",     r"XiaoYing_Video_(1\d{12})(?!\d)",                  _ms,  "real"),
    ("whatsapp",     rf"(?:IMG|VID|AUD|PTT|STK|DOC)-{_Y}{_M}{_D}-WA",    _ymd, "day"),
    ("dashed_date",  rf"(?<!\d){_Y}-{_M}-{_D}(?!\d)",                    _ymd, "day"),
    ("compact_date", rf"(?<!\d){_Y}{_M}{_D}(?!\d)",                      _ymd, "day"),
]
RULES = [(n, re.compile(p, re.I), f, prec) for n, p, f, prec in _RULES]


def filename_date(name):
    """-> (epoch, 'filename:<rule>', precision) or None"""
    for label, rx, build, prec in RULES:
        m = rx.search(name)
        if m:
            ts = build(m)
            if valid(ts):
                return (ts, f"filename:{label}", prec)
    return None


def choose(cands):
    """cands: [(epoch, source, precision)].
    Oldest calendar day wins; on that day the earliest REAL time wins,
    a date-only (noon) value is used only when nothing real exists that day."""
    cands = [c for c in cands if valid(c[0])]
    if not cands:
        return None
    day = lambda ts: dt.datetime.fromtimestamp(ts).date()
    oldest = min(day(c[0]) for c in cands)
    same_day = [c for c in cands if day(c[0]) == oldest]
    real = [c for c in same_day if c[2] == "real"]
    return min(real or same_day, key=lambda c: c[0])


# --------------------------------------------------------------- exiftool ---
def exif_read(paths, workers):
    """-> {path: {tag: epoch}}; a path maps to None when exiftool could not read it."""
    result = {p: None for p in paths}
    if not paths:
        return result
    n = max(1, min(workers, len(paths) // 200 + 1))

    def run(chunk):
        fd, argfile = tempfile.mkstemp(suffix=".args")
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            f.write("\n".join(chunk) + "\n")
        try:
            r = subprocess.run(["exiftool", "-json", "-q", "-q", "-m", "-api", "QuickTimeUTC=1",
                                "-d", "%s", *(f"-{t}" for t in TAGS), "-@", argfile],
                               capture_output=True, text=True, errors="replace")
            try:
                return json.loads(r.stdout) if r.stdout.strip() else []
            except json.JSONDecodeError:
                return []
        finally:
            os.unlink(argfile)

    with ThreadPoolExecutor(n) as ex:
        for rows in ex.map(run, [paths[i::n] for i in range(n)]):
            for row in rows:
                src = row.get("SourceFile")
                if src not in result or "Error" in row:
                    continue
                vals = {}
                for t in TAGS:
                    try:
                        vals[t] = int(float(row.get(t)))
                    except (TypeError, ValueError):
                        pass
                result[src] = vals
    return result


def exif_write(jobs, workers):
    """jobs: [(path, epoch, is_video)]; one exiftool process per chunk, chunks in parallel."""
    if not jobs:
        return
    n = max(1, min(workers, len(jobs) // 50 + 1))

    def run(chunk):
        args = []
        for path, ts, is_video in chunk:
            stamp = dt.datetime.fromtimestamp(ts).strftime("%Y:%m:%d %H:%M:%S")
            args += ["-overwrite_original", "-P", "-m", "-q", "-q",
                     "-api", "QuickTimeUTC=1", f"-AllDates={stamp}"]
            if is_video:
                args += [f"-TrackCreateDate={stamp}", f"-TrackModifyDate={stamp}",
                         f"-MediaCreateDate={stamp}", f"-MediaModifyDate={stamp}"]
            args += [path, "-execute"]
        fd, argfile = tempfile.mkstemp(suffix=".args")
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            f.write("\n".join(args) + "\n")
        try:
            subprocess.run(["exiftool", "-@", argfile], capture_output=True, text=True, errors="replace")
        finally:
            os.unlink(argfile)

    with ThreadPoolExecutor(n) as ex:
        list(ex.map(run, [jobs[i::n] for i in range(n)]))


# ---------------------------------------------------------- phone writes ----
def push_to_phone(root, rels, stage, phone_root):
    """Push only the given files back to their own paths (hard-linked staging tree)."""
    if not rels:
        return True
    stage = Path(stage)
    shutil.rmtree(stage, ignore_errors=True)
    for rel in rels:
        dst = stage / rel
        dst.parent.mkdir(parents=True, exist_ok=True)
        try:
            os.link(root / rel, dst)
        except OSError:
            shutil.copy2(root / rel, dst)
    ok = True
    for entry in sorted(stage.iterdir()):
        log(f"dates: pushing corrected files in {entry.name}/ ...")
        r = adb("push", str(entry), phone_root + "/")
        if r.returncode != 0:
            ok = False
            log(f"dates: push failed for {entry.name}: {(r.stderr or r.stdout).strip()[-400:]}")
    shutil.rmtree(stage, ignore_errors=True)
    return ok


def touch_on_phone(items, phone_root):
    """items: [(rel, epoch)] -> set the real file time on the phone."""
    if not items:
        return
    out, _ = run_on_phone(["f=/data/local/tmp/.abk_probe",
                           "touch $f && touch -d @1500000000 $f && stat -c %Y $f",
                           "rm -f $f"], "abk_probe.sh")
    epoch_ok = out.strip().endswith("1500000000")
    lines = []
    for rel, ts in items:
        target = q(f"{phone_root}/{rel}")
        if epoch_ok:
            lines.append(f"touch -d @{int(ts)} {target}")
        else:   # older toybox: local time in the phone's timezone (TZ is set to it)
            lines.append(f"touch -t {dt.datetime.fromtimestamp(ts):%Y%m%d%H%M.%S} {target}")
    for i in range(0, len(lines), 5000):
        _, err = run_on_phone(lines[i:i + 5000], "abk_touch.sh")
        if err.strip():
            log(f"dates: touch reported: {err.strip().splitlines()[0][:200]}")


def phone_stat(rels, phone_root):
    """-> {rel: (size, mtime)} as the phone reports them."""
    res = {}
    for i in range(0, len(rels), 5000):
        chunk = rels[i:i + 5000]
        lines = [f"stat -c '%s|%Y|%n' {q(phone_root + '/' + r)} 2>/dev/null" for r in chunk]
        out, _ = run_on_phone(lines, "abk_stat.sh")
        prefix = phone_root + "/"
        for line in out.splitlines():
            parts = line.split("|", 2)
            if len(parts) == 3 and parts[0].isdigit() and parts[2].startswith(prefix):
                res[parts[2][len(prefix):]] = (int(parts[0]), int(parts[1]))
    return res


# --------------------------------------------------------------- meta cmd ---
def iter_media(root):
    """Photos/videos, skipping hidden folders/files and app-private Android/data, obb."""
    for dirpath, dirnames, filenames in os.walk(root):
        rel_dir = os.path.relpath(dirpath, root).replace(os.sep, "/")
        rel_dir = "" if rel_dir == "." else rel_dir
        keep = []
        for d in dirnames:
            rp = f"{rel_dir}/{d}" if rel_dir else d
            if d.startswith(".") or rp in ("Android/data", "Android/obb"):
                continue
            keep.append(d)
        dirnames[:] = keep
        for fn in filenames:
            if not fn.startswith(".") and os.path.splitext(fn)[1].lower() in MEDIA_EXTS:
                yield f"{rel_dir}/{fn}" if rel_dir else fn


def reference_mtime(rel, refs):
    for prefix, folder in refs:
        if rel.startswith(prefix + "/"):
            p = folder / rel[len(prefix) + 1:]
            if p.is_file():
                return int(p.stat().st_mtime)
    return None


def cmd_meta(a):
    root = Path(a.storage)
    refs = []
    for spec in a.ref or []:
        prefix, _, folder = spec.partition("|")
        folder = folder.strip()
        if not folder:
            continue
        if Path(folder).is_dir():
            refs.append((prefix.strip().strip("/"), Path(folder)))
            log(f"dates: using untouched reference copy {folder}")
        else:
            log(f"dates: reference folder not found, ignored: {folder}")

    rels = sorted(iter_media(root))
    log(f"dates: {len(rels)} photos/videos to check")
    paths = [str(root / r) for r in rels]
    log("dates: reading embedded dates ...")
    emb = exif_read(paths, a.workers)

    rows, writes, touches = [], [], []
    stats = Counter()
    for rel, path in zip(rels, paths):
        ext = os.path.splitext(rel)[1].lower()
        is_video = ext in VIDEO_EXTS
        mtime = int(os.stat(path).st_mtime)
        tags = emb.get(path)
        fn = filename_date(os.path.basename(rel))
        ref = reference_mtime(rel, refs)
        row = {"file": rel, "embedded": "", "filename_date": iso(fn[0]) if fn else "",
               "file_mtime": iso(mtime), "reference_mtime": iso(ref),
               "chosen": "", "chosen_from": "", "precision": "", "action": ""}
        rows.append(row)
        if tags is None:   # unreadable: never guess over data we could not see
            row["action"] = "skipped_unreadable"
            stats[row["action"]] += 1
            continue
        cands = [(v, f"embedded:{t}", precision(v)) for t, v in tags.items() if valid(v)]
        if cands:
            row["embedded"] = iso(min(c[0] for c in cands))
        if fn:
            cands.append(fn)
        if valid(mtime):
            cands.append((mtime, "file_mtime", precision(mtime)))
        if ref and valid(ref):
            cands.append((ref, "reference_mtime", precision(ref)))
        pick = choose(cands)
        if not pick:
            row["action"] = "no_date"
            stats[row["action"]] += 1
            continue
        chosen = int(pick[0])
        row.update(chosen=iso(chosen), chosen_from=pick[1], precision=pick[2])
        current = tags.get("CreateDate" if is_video else "DateTimeOriginal")
        need_write = ext in WRITABLE_EXTS and current != chosen
        need_touch = mtime != chosen
        if need_write:
            writes.append((path, chosen, is_video, rel))
        if need_write or need_touch:
            touches.append((rel, path, chosen))
        row["action"] = ("write+touch" if need_write and need_touch else
                         "write" if need_write else "touch" if need_touch else "ok")
        stats[row["action"]] += 1

    log("dates: plan: " + ", ".join(f"{k}={v}" for k, v in sorted(stats.items())))
    failed_verify = 0
    if a.dry_run:
        log("dates: dry run, nothing changed (see the report)")
    else:
        log(f"dates: writing dates into {len(writes)} files ...")
        exif_write([(p, t, v) for p, t, v, _ in writes], a.workers)
        for _, path, ts in touches:
            os.utime(path, (ts, ts))
        check = exif_read([w[0] for w in writes], a.workers)
        pushed = []
        by_rel = {r["file"]: r for r in rows}
        for path, ts, is_video, rel in writes:
            got = (check.get(path) or {}).get("CreateDate" if is_video else "DateTimeOriginal")
            if got == ts:
                pushed.append(rel)
            else:
                by_rel[rel]["action"] += " (write failed: file time only)"
        if len(pushed) < len(writes):
            log(f"dates: {len(writes) - len(pushed)} files could not take an embedded date; "
                "only their file time is fixed")
        if not push_to_phone(root, pushed, a.stage, a.phone_root):
            log("dates: some corrected files could not be pushed (see above)")
        touch_on_phone([(rel, ts) for rel, _, ts in touches], a.phone_root)
        log("dates: verifying on the phone ...")
        targets = [rel for rel, _, _ in touches]
        seen = phone_stat(targets, a.phone_root)
        want = {rel: ts for rel, _, ts in touches}
        pushed_set = set(pushed)
        bad = []
        for rel in targets:
            got = seen.get(rel)
            local_size = os.path.getsize(root / rel)
            if got is None:
                bad.append(f"{rel}\tmissing on phone")
            elif got[1] != want[rel]:
                bad.append(f"{rel}\tphone mtime {iso(got[1])}, wanted {iso(want[rel])}")
            elif rel in pushed_set and got[0] != local_size:
                bad.append(f"{rel}\tphone size {got[0]}, backup size {local_size}")
        failed_verify = len(bad)
        if bad:
            Path(a.report).with_name("metadata_phone_mismatches.txt").write_text("\n".join(bad) + "\n")
            log(f"dates: {len(bad)} files do not match on the phone (metadata_phone_mismatches.txt)")
        else:
            log(f"dates: verified {len(targets)} changed files on the phone")

    with open(a.report, "w", newline="", encoding="utf-8") as f:
        w = csv.DictWriter(f, fieldnames=list(rows[0].keys()) if rows else ["file"])
        w.writeheader()
        w.writerows(rows)
    log(f"dates: report -> {a.report}")
    return 1 if failed_verify else 0


# ---------------------------------------------------------- message export --
def parse_rows(text, cols):
    """Parse `content query` output.  The last column may contain commas/newlines."""
    raws, cur = [], None
    for line in text.rstrip("\n").split("\n"):
        m = re.match(r"^Row: \d+ ", line)
        if m:
            if cur is not None:
                raws.append(cur)
            cur = line[m.end():]
        elif cur is not None:
            cur += "\n" + line
    if cur is not None:
        raws.append(cur)
    out = []
    for raw in raws:
        rec, pos = {}, 0
        for i, c in enumerate(cols):
            key = f"{c}="
            if not raw.startswith(key, pos):
                break
            start = pos + len(key)
            if i + 1 < len(cols):
                end = raw.find(f", {cols[i + 1]}=", start)
                if end < 0:
                    break
                val, pos = raw[start:end], end + 2
            else:
                val = raw[start:]
            rec[c] = None if val == "NULL" else val
        if rec:
            out.append(rec)
    return out


def content_query(uri, cols):
    """-> (rows or None, raw_text, error)"""
    _, out, err = shell(f"content query --uri {uri} --projection {':'.join(cols)}")
    text = out + err
    if "Permission Denial" in text or "SecurityException" in text:
        return None, text, "permission denied"
    if ("Error while accessing provider" in text or "Unknown URL" in text
            or "no such column" in text.lower() or "IllegalArgumentException" in text):
        return None, text, (text.strip().splitlines() or ["error"])[0][:200]
    if "No result found" in out:
        return [], text, ""
    return parse_rows(out, cols), text, ""


def query_any(uri, *col_sets):
    last = (None, "", "not tried")
    for cols in col_sets:
        last = content_query(uri, cols)
        if last[0] is not None:
            return last
    return last


_BAD_XML = re.compile(r"[\x00-\x08\x0b\x0c\x0e-\x1f]")


def xa(v):
    return quoteattr(_BAD_XML.sub("", str(v)))


def readable(ms):
    try:
        return dt.datetime.fromtimestamp(int(ms) / 1000).strftime("%b %d, %Y %I:%M:%S %p")
    except (TypeError, ValueError, OverflowError, OSError):
        return ""


def write_sms_xml(rows, path):
    """SMS Backup & Restore compatible file (the only practical non-root SMS restore)."""
    with open(path, "w", encoding="utf-8") as f:
        f.write("<?xml version='1.0' encoding='UTF-8' standalone='yes' ?>\n")
        f.write(f'<smses count="{len(rows)}">\n')
        for r in rows:
            date = r.get("date") or "0"
            attrs = [("protocol", "0"), ("address", r.get("address") or ""), ("date", date),
                     ("type", r.get("type") or "1"), ("subject", r.get("subject") or "null"),
                     ("body", r.get("body") or ""), ("toa", "null"), ("sc_toa", "null"),
                     ("service_center", r.get("service_center") or "null"),
                     ("read", r.get("read") or "1"), ("status", r.get("status") or "-1"),
                     ("locked", r.get("locked") or "0"), ("date_sent", r.get("date_sent") or "0"),
                     ("readable_date", readable(date)), ("contact_name", "(Unknown)")]
            f.write("  <sms " + " ".join(f"{k}={xa(v)}" for k, v in attrs) + " />\n")
        f.write("</smses>\n")


def write_calls_xml(rows, path):
    with open(path, "w", encoding="utf-8") as f:
        f.write("<?xml version='1.0' encoding='UTF-8' standalone='yes' ?>\n")
        f.write(f'<calls count="{len(rows)}">\n')
        for r in rows:
            date = r.get("date") or "0"
            attrs = [("number", r.get("number") or ""), ("duration", r.get("duration") or "0"),
                     ("date", date), ("type", r.get("type") or "1"),
                     ("presentation", r.get("presentation") or "1"),
                     ("readable_date", readable(date)),
                     ("contact_name", r.get("name") or "(Unknown)")]
            f.write("  <call " + " ".join(f"{k}={xa(v)}" for k, v in attrs) + " />\n")
        f.write("</calls>\n")


def vesc(s):
    return (s or "").replace("\\", "\\\\").replace(";", "\\;").replace(",", "\\,").replace("\n", "\\n")


PHONE_TYPES = {"1": "HOME", "2": "CELL", "3": "WORK", "4": "WORK,FAX", "5": "HOME,FAX",
               "6": "PAGER", "7": "OTHER", "12": "MAIN"}
MT = "vnd.android.cursor.item/"


def write_vcf(rows, path):
    contacts = {}
    for r in rows:
        cid = r.get("contact_id")
        if cid:
            contacts.setdefault(cid, []).append(r)
    count = 0
    with open(path, "w", encoding="utf-8", newline="\r\n") as f:
        for cid, items in contacts.items():
            name = next((i for i in items if i.get("mimetype") == MT + "name"), None)
            phones = [i for i in items if i.get("mimetype") == MT + "phone_v2" and i.get("data1")]
            emails = [i for i in items if i.get("mimetype") == MT + "email_v2" and i.get("data1")]
            fn = (name or {}).get("data1") or (phones[0]["data1"] if phones else
                                               emails[0]["data1"] if emails else "")
            if not fn:
                continue
            lines = ["BEGIN:VCARD", "VERSION:3.0", f"FN:{vesc(fn)}",
                     f"N:{vesc((name or {}).get('data3'))};{vesc((name or {}).get('data2'))};;;"]
            for p in phones:
                lines.append(f"TEL;TYPE={PHONE_TYPES.get(p.get('data2') or '', 'VOICE')}:{p['data1']}")
            for e in emails:
                lines.append(f"EMAIL;TYPE=INTERNET:{vesc(e['data1'])}")
            for i in items:
                m, d1 = i.get("mimetype"), i.get("data1")
                if not d1:
                    continue
                if m == MT + "organization":
                    lines.append(f"ORG:{vesc(d1)}")
                elif m == MT + "postal-address_v2":
                    lines.append(f"ADR;TYPE=HOME:;;{vesc(d1)};;;;")
                elif m == MT + "note":
                    lines.append(f"NOTE:{vesc(d1)}")
                elif m == MT + "nickname":
                    lines.append(f"NICKNAME:{vesc(d1)}")
                elif m == MT + "website":
                    lines.append(f"URL:{d1}")
                elif m == MT + "contact_event" and i.get("data2") == "3":
                    lines.append(f"BDAY:{d1}")
            lines.append("END:VCARD")
            f.write("\n".join(lines) + "\n")
            count += 1
    return count


def cmd_messages(a):
    out = Path(a.out)
    out.mkdir(parents=True, exist_ok=True)
    summary = {}

    def note(key, rows, err, what):
        if rows is None:
            summary[key] = "unavailable"
            log(f"messages: {what}: could not be read ({err})")
        else:
            summary[key] = len(rows)
            log(f"messages: {what}: {len(rows)}")

    rows, raw, err = query_any("content://sms",
                               ["address", "date", "date_sent", "type", "read", "status", "locked",
                                "service_center", "subject", "body"],
                               ["address", "date", "type", "read", "body"])
    (out / "sms_raw.txt").write_text(raw, encoding="utf-8")
    if rows is not None:
        write_sms_xml(rows, out / "sms.xml")
    note("sms", rows, err, "SMS")

    mms, _, _ = content_query("content://mms", ["_id"])
    summary["mms_not_exported"] = len(mms) if mms is not None else "unknown"

    rows, raw, err = query_any("content://call_log/calls",
                               ["number", "date", "duration", "type", "presentation", "name"],
                               ["number", "date", "duration", "type"])
    (out / "calllog_raw.txt").write_text(raw, encoding="utf-8")
    if rows is not None:
        write_calls_xml(rows, out / "calls.xml")
        (out / "calllog.json").write_text(json.dumps(rows, indent=1, ensure_ascii=False), encoding="utf-8")
    note("calls", rows, err, "call log")

    rows, raw, err = content_query("content://com.android.contacts/data",
                                   ["contact_id", "mimetype", "data2", "data3", "data1"])
    (out / "contacts_raw.txt").write_text(raw, encoding="utf-8")
    if rows is not None:
        summary["contacts"] = write_vcf(rows, out / "contacts.vcf")
        log(f"messages: contacts: {summary['contacts']}")
    else:
        note("contacts", rows, err, "contacts")

    for key, uri, cols in [
        ("calendar_events", "content://com.android.calendar/events",
         ["calendar_id", "dtstart", "dtend", "eventLocation", "title", "description"]),
        ("dictionary_words", "content://user_dictionary/words", ["locale", "frequency", "word"]),
    ]:
        rows, raw, err = content_query(uri, cols)
        (out / f"{key}_raw.txt").write_text(raw, encoding="utf-8")
        summary[key] = len(rows) if rows is not None else "unavailable"

    (out / "summary.txt").write_text("".join(f"{k}={v}\n" for k, v in summary.items()))
    return 0


def cmd_dedupe(a):
    """Hard-link files unchanged since the previous backup (same path, size, mtime)."""
    new, old = Path(a.new), Path(a.old)
    linked = saved = 0
    for dirpath, _, files in os.walk(new):
        for fn in files:
            p = Path(dirpath) / fn
            o = old / p.relative_to(new)
            try:
                sp, so = p.stat(), o.stat()
            except OSError:
                continue
            if (sp.st_size == so.st_size and int(sp.st_mtime) == int(so.st_mtime)
                    and sp.st_dev == so.st_dev and sp.st_ino != so.st_ino):
                tmp = p.with_name(p.name + ".abk_link")
                try:
                    os.link(o, tmp)
                    os.replace(tmp, p)
                    linked += 1
                    saved += sp.st_size
                except OSError:
                    tmp.unlink(missing_ok=True)
    log(f"storage: {linked} unchanged files shared with the previous backup "
        f"({saved / 1073741824:.1f} GB not stored twice)")
    return 0


def main():
    p = argparse.ArgumentParser()
    sub = p.add_subparsers(dest="cmd", required=True)
    d = sub.add_parser("dedupe")
    d.add_argument("--new", required=True)
    d.add_argument("--old", required=True)
    m = sub.add_parser("meta")
    m.add_argument("--storage", required=True)
    m.add_argument("--phone-root", required=True)
    m.add_argument("--report", required=True)
    m.add_argument("--stage", required=True)
    m.add_argument("--workers", type=int, default=4)
    m.add_argument("--ref", action="append")
    m.add_argument("--dry-run", action="store_true")
    m.add_argument("--tz", default="", help="phone timezone used for all date math")
    s = sub.add_parser("messages")
    s.add_argument("--out", required=True)
    a = p.parse_args()
    if getattr(a, "tz", ""):
        os.environ["TZ"] = a.tz      # EXIF times are local: interpret them in the phone's zone
        time.tzset()
    return {"meta": cmd_meta, "messages": cmd_messages, "dedupe": cmd_dedupe}[a.cmd](a)


if __name__ == "__main__":
    sys.exit(main())
PY

# ================================== steps ===================================
check_device() {
  local list
  list=$(command adb devices 2>/dev/null | awk 'NR>1 && NF')
  if [[ -z "$ADB_SERIAL" ]]; then
    local n
    n=$(awk '$2=="device"' <<<"$list" | wc -l)
    if (( n == 0 )); then
      if grep -q unauthorized <<<"$list"; then
        die "phone is 'unauthorized': unlock it and accept the USB debugging prompt"
      fi
      die "no phone found: plug it in and enable USB debugging"
    fi
    if (( n > 1 )); then die "several devices connected: pass --serial <id> (see 'adb devices')"; fi
    ADB_SERIAL=$(awk '$2=="device"{print $1; exit}' <<<"$list")
  fi
  export ADB_SERIAL
  BRAND=$(ashell getprop ro.product.brand)
  MODEL=$(ashell getprop ro.product.model)
  ANDROID_REL=$(ashell getprop ro.build.version.release)
  SDK=$(ashell getprop ro.build.version.sdk)
  PHONE_TZ=$(ashell getprop persist.sys.timezone)
  log "phone: $BRAND $MODEL, Android $ANDROID_REL (sdk $SDK), serial $ADB_SERIAL, timezone ${PHONE_TZ:-unknown}"
}

detect_root() {
  if [[ "$DO_ROOT" == 0 ]]; then return 0; fi
  log "checking for root (accept the su prompt on the phone if one appears) ..."
  local out
  out=$(timeout 30 adbc shell 'su -c id' 2>/dev/null || true)
  if [[ "$out" == *"uid=0"* ]]; then
    HAS_ROOT=1
    log "root: available"
  else
    log "root: not available (that's fine; root-only extras are skipped)"
    if [[ "$DO_ROOT" == 1 ]]; then warn "--root was given but su does not work on this phone"; fi
  fi
}

keep_awake() {
  STAY_ON_ORIG=$(ashell "settings get global stay_on_while_plugged_in")
  ashell "svc power stayon usb" >/dev/null
}

backup_storage() {
  local dest="$BACKUP_DIR/storage" tmp=/data/local/tmp
  mkdir -p "$dest"
  local paths=() name
  while IFS= read -r name; do
    if [[ -n "$name" && "$name" != "Android" ]]; then paths+=("$name"); fi
  done < <(ashell "ls -A $(rq "$PHONE_ROOT")")
  paths+=("Android/media")
  if (( INCLUDE_ANDROID_DATA )); then paths+=("Android/data"); fi
  if (( INCLUDE_ANDROID_OBB )); then paths+=("Android/obb"); fi

  local qpaths="" excl="" prune="" p
  for p in "${paths[@]}"; do qpaths+=" $(rq "$p")"; done
  for p in "${TAR_EXCLUDES[@]}"; do
    excl+=" --exclude=$(rq "$p")"
    prune+=" -path $(rq "$p") -prune -o"
  done
  local cdroot
  cdroot="cd $(rq "$PHONE_ROOT")"

  log "storage: measuring ${#paths[@]} top-level folders ..."
  local kb free_kb
  kb=$(ashell "$cdroot && du -sk$qpaths 2>/dev/null" | awk '{s+=$1} END{print s+0}')
  free_kb=$(df -Pk "$BACKUP_ROOT" | awk 'NR==2{print $4}')
  log "storage: about $(( kb / 1024 )) MB to copy; $(( free_kb / 1024 )) MB free on this PC"
  if (( kb + kb / 10 > free_kb )); then
    if (( FORCE )); then warn "the PC may run out of space (continuing because of --force)"
    else die "not enough free space on the PC for this backup (use --force to try anyway)"; fi
  fi

  local remote="$cdroot && tar -cf -$excl$qpaths 2>$tmp/abk_tar.err; echo \$? >$tmp/abk_tar.rc"
  local meter=(cat)
  if command -v pv >/dev/null 2>&1; then meter=(pv -s "$(( kb * 1024 ))"); fi
  log "storage: copying (the long part; keep the phone connected) ..."
  if ! adbc exec-out "$remote" | "${meter[@]}" 2>"$PROGRESS_TTY" | tar -xpf - -C "$dest"; then
    warn "storage: the copy stream ended with an error"
  fi

  local rc errfile="$BACKUP_DIR/logs/phone_unreadable_files.txt"
  rc=$(ashell "cat $tmp/abk_tar.rc 2>/dev/null")
  adbc pull "$tmp/abk_tar.err" "$errfile" >/dev/null 2>&1 || true
  ashell "rm -f $tmp/abk_tar.err $tmp/abk_tar.rc" >/dev/null
  if [[ "$rc" != "0" && -s "$errfile" ]]; then
    warn "storage: $(wc -l <"$errfile") item(s) could not be read on the phone (usually Android/data on Android 11+); see logs/$(basename "$errfile")"
  fi
  local dev_n
  dev_n=$(ashell "$cdroot && find$qpaths$prune -type f -print 2>/dev/null | wc -l" | tr -d ' ')
  STORAGE_FILES=$(find "$dest" -type f | wc -l)
  log "storage: $STORAGE_FILES files copied (phone reports ${dev_n:-?} readable files)"
}

fix_metadata() {
  local args=(meta --storage "$BACKUP_DIR/storage" --phone-root "$PHONE_ROOT"
              --report "$BACKUP_DIR/logs/metadata_report.csv"
              --stage "$BACKUP_DIR/.push_stage" --workers "$WORKERS")
  local r
  for r in "${REF_MAPS[@]}"; do args+=(--ref "$r"); done
  if (( DRY_RUN )); then args+=(--dry-run); fi
  if [[ -n "$PHONE_TZ" ]]; then args+=(--tz "$PHONE_TZ"); fi
  if ! python3 "$HELPER" "${args[@]}"; then
    warn "date fix finished with problems (see logs/metadata_report.csv and the log above)"
  fi
}

PREV_BACKUP=""
find_previous() {
  local cand
  cand=$(readlink "$BACKUP_ROOT/latest" 2>/dev/null || true)
  if [[ -n "$cand" && "$cand" != "$TIMESTAMP" && -f "$BACKUP_ROOT/$cand/.complete" && -d "$BACKUP_ROOT/$cand/storage" ]]; then
    PREV_BACKUP="$BACKUP_ROOT/$cand"
  fi
}

share_with_previous() {
  if [[ -z "$PREV_BACKUP" ]]; then return 0; fi
  python3 "$HELPER" dedupe --new "$BACKUP_DIR/storage" --old "$PREV_BACKUP/storage" \
    || warn "could not link unchanged files to the previous backup (backup is still complete)"
}

write_manifest() {
  find "$BACKUP_DIR/storage" -type f -printf '%P\t%s\t%T@\n' | sort >"$BACKUP_DIR/storage_manifest.tsv"
}

backup_apps() {
  local d="$BACKUP_DIR/apps" pkgs=() pkg
  mkdir -p "$d"
  mapfile -t pkgs < <(ashell "pm list packages -3" | sed -n 's/^package://p' | sort)
  log "apps: ${#pkgs[@]} user-installed apps"
  printf 'package\tversion_name\tversion_code\tapk_files\n' >"$d/apps.tsv"
  local done_n=0 fail=0
  for pkg in "${pkgs[@]}"; do
    local apks=() a good=1 info vn vc
    mapfile -t apks < <(ashell "pm path $pkg" | sed -n 's/^package://p')
    if (( ${#apks[@]} == 0 )); then warn "apps: no APK found for $pkg"; fail=$((fail + 1)); continue; fi
    mkdir -p "$d/$pkg"
    for a in "${apks[@]}"; do
      adbc pull "$a" "$d/$pkg/$(basename "$a")" >/dev/null 2>&1 || good=0
    done
    info=$(ashell "dumpsys package $pkg")
    vn=$(grep -m1 -oP 'versionName=\K\S+' <<<"$info" || true)
    vc=$(grep -m1 -oP 'versionCode=\K[0-9]+' <<<"$info" || true)
    printf '%s\t%s\t%s\t%s\n' "$pkg" "$vn" "$vc" "${#apks[@]}" >>"$d/apps.tsv"
    if (( good )); then done_n=$((done_n + 1)); else fail=$((fail + 1)); warn "apps: could not copy every APK of $pkg"; fi
    if (( (done_n + fail) % 25 == 0 )); then log "apps: $((done_n + fail))/${#pkgs[@]} ..."; fi
  done
  log "apps: saved $done_n apps ($fail with problems)"
}

backup_messages() {
  if ! python3 "$HELPER" messages --out "$BACKUP_DIR/messages"; then
    warn "messages: export finished with errors"
  fi
}

backup_device_info() {
  local d="$BACKUP_DIR/device" ns
  mkdir -p "$d"
  ashell getprop >"$d/getprop.txt"
  for ns in system secure global; do ashell "settings list $ns" >"$d/settings_$ns.txt"; done
  ashell "pm list packages -f -U" >"$d/packages_all.txt"
  ashell "pm list packages -3"    >"$d/packages_user.txt"
  ashell "pm list packages -s"    >"$d/packages_system.txt"
  ashell "pm list packages -d"    >"$d/packages_disabled.txt"
  ashell "df -h"                  >"$d/df.txt"
  ashell "cmd wifi list-networks" >"$d/wifi_saved_networks.txt"   # names only, no passwords
  ashell "dumpsys account" | grep -oE 'Account \{name=[^}]*\}' | sort -u >"$d/accounts.txt" || true
  log "device info saved"
}

backup_root_extras() {
  local d="$BACKUP_DIR/root" pkgs=() pkg n=0
  mkdir -p "$d/appdata"
  mapfile -t pkgs < <(ashell "pm list packages -3" | sed -n 's/^package://p' | sort)
  log "root: saving private data of ${#pkgs[@]} apps ..."
  for pkg in "${pkgs[@]}"; do
    local f="$d/appdata/$pkg.tar"
    adbc exec-out "su -c 'cd /data && tar -cf - --exclude=data/$pkg/cache --exclude=data/$pkg/code_cache data/$pkg user_de/0/$pkg 2>/dev/null'" >"$f" 2>/dev/null || true
    if [[ -s "$f" ]]; then n=$((n + 1)); else rm -f "$f"; warn "root: no data captured for $pkg"; fi
  done
  log "root: app data saved for $n apps"
  adbc exec-out "su -c 'cd /data && tar -cf - data/com.android.providers.telephony/databases data/com.android.providers.contacts/databases misc/apexdata/com.android.wifi misc/wifi misc/bluedroid misc/bluetooth 2>/dev/null'" >"$d/system_data.tar" 2>/dev/null || true
  if [[ -s "$d/system_data.tar" ]]; then
    log "root: SMS/call/contacts databases, Wi-Fi and Bluetooth config archived (reference copy)"
  else
    rm -f "$d/system_data.tar"
    warn "root: system databases could not be archived"
  fi
}

backup_legacy() {
  mkdir -p "$BACKUP_DIR/legacy"
  log "legacy adb backup: unlock the phone and tap 'Back up my data' ..."
  adbc backup -f "$BACKUP_DIR/legacy/backup.ab" -all -nosystem -noapk || warn "legacy adb backup failed"
}

finish() {
  {
    echo "timestamp=$TIMESTAMP"
    echo "device=$BRAND $MODEL"
    echo "serial=$ADB_SERIAL"
    echo "android=$ANDROID_REL (sdk $SDK)"
    echo "timezone=$PHONE_TZ"
    echo "root=$HAS_ROOT"
    echo "dry_run=$DRY_RUN"
    echo "storage_files=$STORAGE_FILES"
    if [[ -d "$BACKUP_DIR/storage" ]]; then echo "storage_size=$(du -sh "$BACKUP_DIR/storage" | cut -f1)"; fi
    if [[ -f "$BACKUP_DIR/apps/apps.tsv" ]]; then echo "apps=$(( $(wc -l <"$BACKUP_DIR/apps/apps.tsv") - 1 ))"; fi
    if [[ -f "$BACKUP_DIR/messages/summary.txt" ]]; then cat "$BACKUP_DIR/messages/summary.txt"; fi
    echo "total_size=$(du -sh "$BACKUP_DIR" | cut -f1)"
  } >"$BACKUP_DIR/BACKUP_INFO.txt"
  touch "$BACKUP_DIR/.complete"
  ln -sfn "$TIMESTAMP" "$BACKUP_ROOT/latest"
  COMPLETED=1
  log "------------------------------------------------------------"
  log "Backup complete: $BACKUP_DIR"
  sed 's/^/    /' "$BACKUP_DIR/BACKUP_INFO.txt"
  if (( ${#WARNINGS[@]} )); then
    log "Warnings (${#WARNINGS[@]}):"
    printf '    - %s\n' "${WARNINGS[@]}"
  fi
}

# =================================== run ====================================
log "android_backup.sh -> $BACKUP_DIR"
if (( DRY_RUN )); then log "DRY RUN: the phone will not be modified"; fi
check_device
detect_root
keep_awake
find_previous

if (( DO_STORAGE ));     then backup_storage; fi
if (( DO_METADATA ));    then fix_metadata; fi
if (( DO_STORAGE ));     then share_with_previous; write_manifest; fi
if (( DO_APPS ));        then backup_apps; fi
if (( DO_MESSAGES ));    then backup_messages; fi
if (( DO_DEVICE_INFO )); then backup_device_info; fi
if (( HAS_ROOT ));       then backup_root_extras; fi
if (( DO_ADB_LEGACY ));  then backup_legacy; fi
finish
