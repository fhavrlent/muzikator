#!/usr/bin/env bash
set -euo pipefail

# ── Config ──────────────────────────────────────────────────────────
# Set these to your own upload target, or override via environment.
# Leave REMOTE_HOST empty to force --no-upload mode.
REMOTE_HOST="${MUZIKATOR_REMOTE_HOST:-user@example.com}"
REMOTE_BASE="${MUZIKATOR_REMOTE_BASE:-/path/to/music/library}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BEETS_CONFIG_TEMPLATE="$SCRIPT_DIR/config/beets-config.yaml"

WORKSPACE=""
CLEANUP_ON_EXIT=true
CURRENT_STAGE=""
PARANOIA=""  # resolved in check_deps: cd-paranoia or cdparanoia

# ── CLI defaults ────────────────────────────────────────────────────
CD_DEVICE=""
NO_UPLOAD=false
OUTPUT_DIR=""
RELEASE_ID=""  # MusicBrainz release ID — bypasses search
NO_LYRICS=false
TRACKS_FILE=""  # text file with one track title per line (for manual tagging)

# ── Usage ───────────────────────────────────────────────────────────
usage() {
  cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Rip an audio CD, tag via MusicBrainz, upload to server.

Options:
  --device PATH       CD device path (auto-detected if omitted)
  --release-id ID     MusicBrainz release ID (skips search, tags directly)
  --no-upload         Skip rsync upload (pair with --output-dir to keep files,
                      otherwise the temp workspace is wiped on exit)
  --no-lyrics         Skip lyrics fetching
  --tracks-file FILE  Track titles (one per line) for manual tagging fallback
  --output-dir DIR    Copy final files here instead of temp workspace
  -h, --help          Show this help

Environment:
  MUZIKATOR_REMOTE_HOST   rsync destination host (default: user@example.com)
  MUZIKATOR_REMOTE_BASE   remote library path (default: /path/to/music/library)

  If MUZIKATOR_REMOTE_HOST is unset or left at the default placeholder,
  --no-upload is enabled automatically and the library stays local.

Required tools:
  cd-paranoia (or cdparanoia), fpcalc (chromaprint), flac, metaflac,
  beet (beets[chroma,fetchart]), rsync, python3

Optional tools (used only for CD-Extra discs — the pipeline still works
without them, CD-Extra auto-trim is just skipped):
  cd-info (libcdio-utils)   detect CD-Extra disc layout
  ffmpeg                    trim inter-session noise from last track

Examples:
  $(basename "$0")                                          # auto-detect everything
  $(basename "$0") --device /dev/sr0                        # specify device
  $(basename "$0") --release-id 12345678-abcd-efgh-ijkl     # known release
  $(basename "$0") --no-upload --output-dir ~/Music         # local-only, keep files
  $(basename "$0") --tracks-file titles.txt                 # prepare manual fallback
EOF
}

# ── Helpers ─────────────────────────────────────────────────────────
log_stage() {
  CURRENT_STAGE="$1"
  echo ""
  echo "═══════════════════════════════════════════"
  echo "  $1"
  echo "═══════════════════════════════════════════"
  echo ""
}

die() {
  echo "ERROR: $*" >&2
  exit 1
}

os_type() {
  uname -s
}

# ── Cleanup & error handling ────────────────────────────────────────
on_exit() {
  local code=$?
  if [[ $code -ne 0 && -n "$WORKSPACE" && -d "$WORKSPACE" ]]; then
    echo "" >&2
    echo "Pipeline failed at: $CURRENT_STAGE" >&2
    echo "Workspace preserved for debugging: $WORKSPACE" >&2
    return
  fi
  if [[ "$CLEANUP_ON_EXIT" == "true" && -n "$WORKSPACE" && -d "$WORKSPACE" ]]; then
    rm -rf "$WORKSPACE"
  fi
}
trap on_exit EXIT

# ── Dependency check ────────────────────────────────────────────────
check_deps() {
  local missing=() os
  os="$(os_type)"

  # cd-paranoia (libcdio, maintained) preferred over cdparanoia (dead since 2008)
  if command -v cd-paranoia &>/dev/null; then
    PARANOIA="cd-paranoia"
  elif command -v cdparanoia &>/dev/null; then
    PARANOIA="cdparanoia"
  else
    missing+=("cd-paranoia")
  fi

  # fpcalc is essential for CD rips — files have zero metadata, fingerprinting
  # is the only way beets can identify them automatically
  if ! command -v fpcalc &>/dev/null; then
    missing+=("fpcalc")
  fi

  for cmd in flac beet metaflac rsync python3; do
    command -v "$cmd" &>/dev/null && continue
    missing+=("$cmd")
  done

  if [[ ${#missing[@]} -gt 0 ]]; then
    echo "Missing required tools:" >&2
    for cmd in "${missing[@]}"; do
      echo -n "  - $cmd  " >&2
      case "$os:$cmd" in
        Darwin:cd-paranoia) echo "(brew install libcdio-paranoia)" >&2 ;;
        Darwin:fpcalc) echo "(brew install chromaprint)" >&2 ;;
        Darwin:flac|Darwin:metaflac) echo "(brew install flac)" >&2 ;;
        Darwin:beet)  echo "(pipx install 'beets[chroma,fetchart]'  — install pipx first: brew install pipx)" >&2 ;;
        Darwin:rsync) echo "(brew install rsync)" >&2 ;;
        Linux:cd-paranoia) echo "(apt install libcdio-paranoia  OR  apt install cdparanoia)" >&2 ;;
        Linux:fpcalc) echo "(apt install libchromaprint-tools)" >&2 ;;
        Linux:flac|Linux:metaflac) echo "(apt install flac)" >&2 ;;
        Linux:beet)  echo "(pip3 install 'beets[chroma,fetchart]')" >&2 ;;
        Linux:rsync) echo "(apt install rsync)" >&2 ;;
        *) echo "" >&2 ;;
      esac
    done
    return 1
  fi

  # Optional tools — used only for CD-Extra discs. Warn but don't fail.
  local optional_missing=()
  for cmd in ffmpeg cd-info; do
    command -v "$cmd" &>/dev/null || optional_missing+=("$cmd")
  done

  if [[ ${#optional_missing[@]} -gt 0 ]]; then
    echo "Optional tools not found (CD-Extra auto-trim will be skipped):" >&2
    for cmd in "${optional_missing[@]}"; do
      echo -n "  - $cmd  " >&2
      case "$os:$cmd" in
        Darwin:ffmpeg)  echo "(brew install ffmpeg)" >&2 ;;
        Darwin:cd-info) echo "(brew install libcdio)" >&2 ;;
        Linux:ffmpeg)   echo "(apt install ffmpeg)" >&2 ;;
        Linux:cd-info)  echo "(apt install libcdio-utils)" >&2 ;;
        *) echo "" >&2 ;;
      esac
    done
  fi

  echo "Using ripper: $PARANOIA"
}

# ── CD device detection ─────────────────────────────────────────────
detect_device() {
  local dev=""

  case "$(os_type)" in
    Darwin)
      # drutil tells us about the optical drive
      if command -v drutil &>/dev/null; then
        local status
        status="$(drutil status 2>/dev/null || true)"
        if echo "$status" | grep -q "No Media Inserted"; then
          die "No disc in drive. Insert an audio CD and retry."
        fi
        # On macOS cd-paranoia can usually auto-detect; return empty to let it
        dev=""
      fi
      ;;
    Linux)
      for d in /dev/cdrom /dev/sr0 /dev/sr1; do
        if [[ -e "$d" ]]; then
          dev="$d"
          break
        fi
      done
      if [[ -z "$dev" ]] && command -v lsblk &>/dev/null; then
        dev="$(lsblk -npo NAME,TYPE 2>/dev/null | awk '$2=="rom"{print $1; exit}')"
      fi
      if [[ -z "$dev" ]]; then
        die "No CD drive found. Specify with --device /dev/..."
      fi
      ;;
    *)
      die "Unsupported OS: $(os_type)"
      ;;
  esac

  echo "$dev"
}

# ── Verify disc & show TOC ──────────────────────────────────────────
verify_disc() {
  local dev_flag=""
  [[ -n "${1:-}" ]] && dev_flag="-d $1"

  echo "Querying disc table of contents..."
  # shellcheck disable=SC2086
  if ! $PARANOIA $dev_flag -Q 2>&1; then
    die "Cannot read disc. Is an audio CD inserted?"
  fi
}

# ── Stage: Rip ──────────────────────────────────────────────────────
rip_cd() {
  local wav_dir="$1" dev_flag=""
  [[ -n "${2:-}" ]] && dev_flag="-d $2"

  mkdir -p "$wav_dir"
  pushd "$wav_dir" >/dev/null

  echo "Ripping all tracks..."
  # shellcheck disable=SC2086
  $PARANOIA $dev_flag -B || die "CD ripping failed"

  local count
  count="$(find . -maxdepth 1 -name '*.wav' | wc -l | tr -d ' ')"
  echo "Ripped $count track(s)."
  [[ "$count" -gt 0 ]] || die "No WAV files produced"

  popd >/dev/null
}

# ── Stage: Trim CD-Extra inter-session noise ────────────────────────
# CD-Extra discs have a data session after audio. cd-paranoia reads
# the inter-session gap (~11400 sectors ≈ 2.5 min) as part of the
# last audio track, producing static noise at the end.
trim_cdextra_last_track() {
  local wav_dir="$1"

  # cd-info (from libcdio) detects disc layout; ffmpeg does the actual trim.
  # Both are optional — skip silently if either is missing.
  if ! command -v cd-info &>/dev/null || ! command -v ffmpeg &>/dev/null; then
    return 0
  fi

  local cd_info
  cd_info="$(cd-info --no-header 2>&1)"

  if ! echo "$cd_info" | grep -qE "CD-Plus/Extra|CD-ROM Mixed"; then
    return 0
  fi

  echo "CD-Extra disc detected — checking for inter-session gap..."

  # Find last audio track start and first non-audio track start
  local last_audio_lsn="" first_data_lsn="" last_audio_num=""
  while IFS= read -r line; do
    local num lsn ttype
    num="$(echo "$line" | awk -F: '{print $1}' | tr -d ' ')"
    [[ "$num" =~ ^[0-9]+$ ]] || continue
    [[ "$num" -ge 170 ]] && continue  # skip leadout marker

    lsn="$(echo "$line" | awk '{print $3}')"
    ttype="$(echo "$line" | awk '{print $4}')"
    [[ "$lsn" =~ ^[0-9]+$ ]] || continue

    if [[ "$ttype" == "audio" ]]; then
      last_audio_lsn="$lsn"
      last_audio_num="$num"
    elif [[ -z "$first_data_lsn" ]]; then
      first_data_lsn="$lsn"
    fi
  done < <(echo "$cd_info" | grep -E '^\s+[0-9]+:')

  if [[ -z "$last_audio_lsn" || -z "$first_data_lsn" ]]; then
    return 0
  fi

  # Standard inter-session overhead:
  #   6750 (session 1 lead-out) + 4500 (session 2 lead-in) + 150 (pregap)
  local gap=11400
  local raw_sectors=$(( first_data_lsn - last_audio_lsn ))
  local real_sectors=$(( raw_sectors - gap ))

  if [[ "$real_sectors" -le 0 ]]; then
    echo "  Gap calculation out of range, skipping trim"
    return 0
  fi

  # 75 sectors = 1 second of CD audio
  local real_secs raw_secs
  real_secs="$(awk "BEGIN {printf \"%.2f\", $real_sectors / 75.0}")"
  raw_secs="$(awk "BEGIN {printf \"%.2f\", $raw_sectors / 75.0}")"

  echo "  Track $last_audio_num: TOC says ${raw_secs}s, estimated audio ${real_secs}s"

  # Find last WAV (cd-paranoia names them track01.cdda.wav, track02.cdda.wav, ...)
  local last_wav=""
  for f in "$wav_dir"/track*.cdda.wav; do
    [[ -f "$f" ]] && last_wav="$f"
  done

  if [[ -z "$last_wav" ]]; then
    echo "  Could not find last WAV to trim"
    return 0
  fi

  echo "  Trimming $(basename "$last_wav") to ${real_secs}s..."
  local tmp="${last_wav%.wav}_trimmed.wav"
  if ffmpeg -y -i "$last_wav" -t "$real_secs" "$tmp" -loglevel error; then
    mv "$tmp" "$last_wav"
    echo "  ✂  Trimmed inter-session noise from last track"
  else
    echo "  ⚠  Trim failed (non-fatal, keeping original)"
    rm -f "$tmp"
  fi
}

# ── Stage: Encode ───────────────────────────────────────────────────
encode_flac() {
  local wav_dir="$1" flac_dir="$2"
  mkdir -p "$flac_dir"

  local count=0
  for wav in "$wav_dir"/*.wav; do
    [[ -f "$wav" ]] || continue
    local base
    base="$(basename "$wav" .wav)"
    local out="$flac_dir/${base}.flac"

    flac --best --verify --silent -o "$out" "$wav" || die "flac encode failed: $wav"
    count=$((count + 1))
    echo "  Encoded: ${base}.flac"
  done

  echo "Encoded $count track(s) to FLAC."
  [[ "$count" -gt 0 ]] || die "No FLAC files produced"

  # Remove WAVs
  rm -f "$wav_dir"/*.wav
  echo "  Cleaned up WAV files."
}

# ── Stage: Set track numbers ─────────────────────────────────────
set_track_numbers() {
  local flac_dir="$1"

  # Count total tracks
  local total=0
  for f in "$flac_dir"/*.flac; do
    [[ -f "$f" ]] && total=$((total + 1))
  done

  echo "Setting track numbers on $total file(s)..."
  for f in "$flac_dir"/*.flac; do
    [[ -f "$f" ]] || continue
    local base
    base="$(basename "$f")"
    # Extract track number from filename: track01.cdda.flac -> 1
    local num
    num="$(echo "$base" | sed -n 's/^track\([0-9]*\)\.cdda\.flac$/\1/p')"
    if [[ -z "$num" ]]; then
      echo "  Warning: cannot parse track number from $base, skipping"
      continue
    fi
    # Strip leading zeros for the tag value
    local tracknum=$((10#$num))
    metaflac --set-tag="TRACKNUMBER=$tracknum" --set-tag="TRACKTOTAL=$total" "$f"
    echo "  Set: $base → track $tracknum/$total"
  done
}

# ── Stage: Tag with beets ──────────────────────────────────────────
tag_with_beets() {
  local flac_dir="$1" library_dir="$2"
  local beets_dir="$WORKSPACE/beets"
  mkdir -p "$beets_dir" "$library_dir"

  # Build runtime beets config from template
  local runtime_config="$beets_dir/config.yaml"
  sed \
    -e "s|^directory:.*|directory: $library_dir|" \
    -e "s|^library:.*|library: $beets_dir/library.db|" \
    "$BEETS_CONFIG_TEMPLATE" > "$runtime_config"

  # If no release ID from CLI, offer to enter one now
  if [[ -z "$RELEASE_ID" ]]; then
    echo "Tip: if you know the MusicBrainz release, enter its ID or URL now."
    echo "     Or press Enter to let beets search via fingerprinting."
    echo ""
    read -rp "MusicBrainz release ID/URL (or Enter to skip): " user_input
    if [[ -n "$user_input" ]]; then
      # Accept full URLs like https://musicbrainz.org/release/XXXX — extract the UUID
      RELEASE_ID="${user_input##*/}"
    fi
  fi

  local search_id_flag=""
  if [[ -n "$RELEASE_ID" ]]; then
    search_id_flag="--search-id $RELEASE_ID"
    echo "Using MusicBrainz release: $RELEASE_ID"
  else
    echo "Searching via acoustic fingerprinting..."
  fi
  echo ""

  # BEETSDIR makes beets ignore any user-level config
  # shellcheck disable=SC2086
  BEETSDIR="$beets_dir" beet -c "$runtime_config" import $search_id_flag "$flac_dir"

  local tagged
  tagged="$(find "$library_dir" -name '*.flac' | wc -l | tr -d ' ')"
  if [[ "$tagged" -eq 0 ]]; then
    echo "No files after beets import (skipped all matches)."
    return 1
  fi
  echo ""
  echo "Tagged and organized $tagged track(s)."
}

# ── Stage: Manual tagging fallback ──────────────────────────────────
# When beets can't find a MusicBrainz match, prompt for metadata and
# organize files into the same Artist/Album/NN Title.flac structure.
manual_tag() {
  local flac_dir="$1" library_dir="$2"

  echo ""
  echo "No MusicBrainz match. Entering manual tagging..."
  echo ""

  # ── Collect artist, album, year ──
  local artist="" album="" year=""
  read -rp "Artist: " artist
  [[ -n "$artist" ]] || die "Artist is required"
  read -rp "Album: " album
  [[ -n "$album" ]] || die "Album is required"
  read -rp "Year (Enter to skip): " year

  # ── Collect track titles ──
  local -a titles=()
  local flac_files=()
  for f in "$flac_dir"/*.flac; do
    [[ -f "$f" ]] && flac_files+=("$f")
  done
  local total=${#flac_files[@]}

  if [[ -n "$TRACKS_FILE" ]]; then
    if [[ ! -f "$TRACKS_FILE" ]]; then
      die "Tracks file not found: $TRACKS_FILE"
    fi
    while IFS= read -r line || [[ -n "$line" ]]; do
      [[ -n "$line" ]] && titles+=("$line")
    done < "$TRACKS_FILE"
    if [[ ${#titles[@]} -ne "$total" ]]; then
      die "Tracks file has ${#titles[@]} titles but disc has $total tracks"
    fi
    echo ""
    echo "Track titles from $TRACKS_FILE:"
    for i in "${!titles[@]}"; do
      echo "  $((i + 1)). ${titles[$i]}"
    done
  else
    echo ""
    echo "Enter title for each track ($total tracks):"
    for (( i = 0; i < total; i++ )); do
      local title=""
      read -rp "  Track $((i + 1)): " title
      [[ -n "$title" ]] || die "Title required for track $((i + 1))"
      titles+=("$title")
    done
  fi

  # ── Sanitize for filesystem ──
  sanitize() {
    echo "$1" | sed 's|[/\\<>:\"?*|]|_|g; s/^[. ]*//; s/[. ]*$//'
  }
  local safe_artist safe_album
  safe_artist="$(sanitize "$artist")"
  safe_album="$(sanitize "$album")"

  # ── Tag and organize ──
  local dest_dir="$library_dir/$safe_artist/$safe_album"
  mkdir -p "$dest_dir"

  echo ""
  echo "Tagging and organizing..."
  for (( i = 0; i < total; i++ )); do
    local f="${flac_files[$i]}"
    local title="${titles[$i]}"
    local tracknum=$((i + 1))
    local padded
    padded="$(printf "%02d" "$tracknum")"

    # Set tags
    metaflac --remove-all-tags "$f"
    metaflac \
      --set-tag="ARTIST=$artist" \
      --set-tag="ALBUMARTIST=$artist" \
      --set-tag="ALBUM=$album" \
      --set-tag="TITLE=$title" \
      --set-tag="TRACKNUMBER=$tracknum" \
      --set-tag="TRACKTOTAL=$total" \
      "$f"
    if [[ -n "$year" ]]; then
      metaflac --set-tag="DATE=$year" "$f"
    fi

    # Move to library structure: Artist/Album/NN Title.flac
    local safe_title
    safe_title="$(sanitize "$title")"
    local dest="$dest_dir/${padded} ${safe_title}.flac"
    mv "$f" "$dest"
    echo "  $padded $title"
  done

  echo ""
  echo "Manually tagged and organized $total track(s)."
}

# ── Stage: Fetch Lyrics (LRCLIB) ─────────────────────────────────────
fetch_lyrics() {
  local library_dir="$1"
  local lyrics_tmp="$WORKSPACE/lyrics"
  mkdir -p "$lyrics_tmp"

  echo "Fetching lyrics from LRCLIB..."
  echo ""

  python3 - "$library_dir" "$lyrics_tmp" <<'PYEOF'
import sys, os, json, subprocess, time
from urllib.request import Request, urlopen
from urllib.parse import urlencode
from urllib.error import URLError, HTTPError

library_dir = sys.argv[1]
lyrics_tmp = sys.argv[2]

USER_AGENT = "muzikator/1.0 (https://github.com/muzikator)"
API_BASE = "https://lrclib.net/api"
DELAY = 0.2  # polite delay between requests


def metaflac_tag(filepath, tag):
    try:
        out = subprocess.run(
            ["metaflac", f"--show-tag={tag}", filepath],
            capture_output=True, text=True, timeout=5,
        )
        for line in out.stdout.strip().split("\n"):
            if "=" in line:
                return line.split("=", 1)[1].strip()
    except Exception:
        pass
    return ""


def metaflac_duration(filepath):
    try:
        samples = subprocess.run(
            ["metaflac", "--show-total-samples", filepath],
            capture_output=True, text=True, timeout=5,
        ).stdout.strip()
        rate = subprocess.run(
            ["metaflac", "--show-sample-rate", filepath],
            capture_output=True, text=True, timeout=5,
        ).stdout.strip()
        if samples and rate and int(rate) > 0:
            return int(int(samples) / int(rate))
    except Exception:
        pass
    return 0


def api_get(params):
    url = f"{API_BASE}/get?{urlencode(params)}"
    req = Request(url, headers={"User-Agent": USER_AGENT})
    try:
        with urlopen(req, timeout=10) as resp:
            if resp.status == 200:
                return json.loads(resp.read().decode("utf-8"))
    except HTTPError as e:
        if e.code != 404:
            print(f"    LRCLIB HTTP error: {e.code}", file=sys.stderr)
    except (URLError, OSError, json.JSONDecodeError) as e:
        print(f"    LRCLIB request error: {e}", file=sys.stderr)
    return None


def api_search(params):
    url = f"{API_BASE}/search?{urlencode(params)}"
    req = Request(url, headers={"User-Agent": USER_AGENT})
    try:
        with urlopen(req, timeout=10) as resp:
            if resp.status == 200:
                results = json.loads(resp.read().decode("utf-8"))
                if isinstance(results, list) and len(results) > 0:
                    return results[0]
    except (HTTPError, URLError, OSError, json.JSONDecodeError) as e:
        print(f"    LRCLIB search error: {e}", file=sys.stderr)
    return None


# Collect FLAC files
flac_files = []
for root, dirs, files in os.walk(library_dir):
    for f in sorted(files):
        if f.lower().endswith(".flac"):
            flac_files.append(os.path.join(root, f))

total = len(flac_files)
found = 0
synced_count = 0

for i, fpath in enumerate(flac_files, 1):
    fname = os.path.basename(fpath)
    title = metaflac_tag(fpath, "TITLE")
    artist = metaflac_tag(fpath, "ARTIST")
    album = metaflac_tag(fpath, "ALBUM")
    duration = metaflac_duration(fpath)

    if not title or not artist:
        print(f"  [{i}/{total}] {fname}: missing TITLE/ARTIST, skipping")
        continue

    if i > 1:
        time.sleep(DELAY)

    # Try exact match first (needs duration + album)
    result = None
    if duration > 0 and album:
        result = api_get({
            "track_name": title,
            "artist_name": artist,
            "album_name": album,
            "duration": duration,
        })

    # Fallback: fuzzy search
    if not result or (not result.get("syncedLyrics") and not result.get("plainLyrics")):
        result = api_search({"track_name": title, "artist_name": artist})

    # Extract lyrics — prefer synced
    lyrics_text = None
    is_synced = False
    if result:
        if result.get("syncedLyrics"):
            lyrics_text = result["syncedLyrics"]
            is_synced = True
        elif result.get("plainLyrics"):
            lyrics_text = result["plainLyrics"]

    if not lyrics_text:
        if result and result.get("instrumental"):
            print(f"  [{i}/{total}] {fname}: instrumental")
        else:
            print(f"  [{i}/{total}] {fname}: not found")
        continue

    # Embed via metaflac
    tag_type = "synced" if is_synced else "plain"
    tmp_file = os.path.join(lyrics_tmp, f"track_{i:03d}.lrc")
    try:
        with open(tmp_file, "w", encoding="utf-8") as tf:
            tf.write(lyrics_text)
        subprocess.run(
            ["metaflac", "--remove-tag=LYRICS", "--remove-tag=UNSYNCEDLYRICS", fpath],
            capture_output=True, timeout=5, check=True,
        )
        subprocess.run(
            ["metaflac", f"--set-tag-from-file=LYRICS={tmp_file}", fpath],
            capture_output=True, timeout=5, check=True,
        )
        found += 1
        if is_synced:
            synced_count += 1
        print(f"  [{i}/{total}] {fname}: {tag_type}")
    except Exception as e:
        print(f"  [{i}/{total}] {fname}: embed failed: {e}", file=sys.stderr)
    finally:
        try:
            os.unlink(tmp_file)
        except OSError:
            pass

print(f"\nLyrics: {found}/{total} tracks ({synced_count} synced, {found - synced_count} plain)")
PYEOF

  local rc=$?
  if [[ $rc -ne 0 ]]; then
    echo "  Warning: lyrics fetch encountered errors (non-fatal)"
  fi
  rm -rf "$lyrics_tmp"
}

# ── Stage: Upload ───────────────────────────────────────────────────
upload() {
  local library_dir="$1"

  echo "Uploading to $REMOTE_HOST:$REMOTE_BASE ..."
  if ! rsync -avz --progress "$library_dir/" "$REMOTE_HOST:$REMOTE_BASE/"; then
    die "rsync failed. Files preserved in: $library_dir"
  fi
  echo ""
  echo "Upload complete."
}

# ── Stage: Eject ────────────────────────────────────────────────────
eject_cd() {
  local device="${1:-}"
  echo "Ejecting disc..."
  case "$(os_type)" in
    Darwin) drutil eject 2>/dev/null || true ;;
    Linux)
      if [[ -n "$device" ]]; then
        eject "$device" 2>/dev/null || true
      else
        eject 2>/dev/null || true
      fi
      ;;
  esac
}

# ── Summary ─────────────────────────────────────────────────────────
print_summary() {
  local library_dir="$1"
  echo ""
  echo "═══════════════════════════════════════════"
  echo "  Done!"
  echo "═══════════════════════════════════════════"

  # Show what was imported
  if [[ -d "$library_dir" ]]; then
    echo ""
    echo "Albums:"
    find "$library_dir" -mindepth 2 -maxdepth 2 -type d | while read -r d; do
      local rel="${d#"$library_dir"/}"
      local tracks
      tracks="$(find "$d" -name '*.flac' | wc -l | tr -d ' ')"
      echo "  $rel ($tracks tracks)"
    done
  fi

  if [[ "$NO_UPLOAD" == "false" ]]; then
    echo ""
    echo "Uploaded to: $REMOTE_HOST:$REMOTE_BASE"
  fi
}

# ── Main ────────────────────────────────────────────────────────────
main() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --device)   CD_DEVICE="${2:?--device requires a path}"; shift 2 ;;
      --release-id) RELEASE_ID="${2:?--release-id requires a MusicBrainz ID}"; shift 2 ;;
      --no-upload) NO_UPLOAD=true; shift ;;
      --no-lyrics) NO_LYRICS=true; shift ;;
      --tracks-file) TRACKS_FILE="${2:?--tracks-file requires a path}"; shift 2 ;;
      --output-dir) OUTPUT_DIR="${2:?--output-dir requires a path}"; shift 2 ;;
      -h|--help)  usage; exit 0 ;;
      *) die "Unknown option: $1. See --help." ;;
    esac
  done

  # If the remote wasn't configured, don't try to upload — keep the rip local.
  if [[ "$NO_UPLOAD" == "false" && "$REMOTE_HOST" == "user@example.com" ]]; then
    echo "Note: MUZIKATOR_REMOTE_HOST not set — forcing --no-upload (library stays local)."
    NO_UPLOAD=true
  fi

  # ── Stage 0: Setup ──
  log_stage "Setup"
  check_deps || exit 1

  WORKSPACE="$(mktemp -d "${TMPDIR:-/tmp}/muzikator-XXXXXX")"
  echo "Workspace: $WORKSPACE"

  local wav_dir="$WORKSPACE/wav"
  local flac_dir="$WORKSPACE/flac"
  local library_dir="$WORKSPACE/library"

  # ── Stage 1: Detect ──
  log_stage "Detect CD"

  if [[ -z "$CD_DEVICE" ]]; then
    CD_DEVICE="$(detect_device)"
  fi
  if [[ -n "$CD_DEVICE" ]]; then
    echo "Device: $CD_DEVICE"
  else
    echo "Device: auto-detect (macOS)"
  fi

  verify_disc "$CD_DEVICE"

  # ── Stage 2: Rip ──
  log_stage "Rip CD"
  rip_cd "$wav_dir" "$CD_DEVICE"

  # ── Stage 2b: CD-Extra gap fix ──
  trim_cdextra_last_track "$wav_dir"

  # ── Stage 3: Encode ──
  log_stage "Encode FLAC"
  encode_flac "$wav_dir" "$flac_dir"

  # ── Stage 3b: Track numbers ──
  set_track_numbers "$flac_dir"

  # ── Stage 4: Tag ──
  log_stage "Tag (MusicBrainz)"
  if ! tag_with_beets "$flac_dir" "$library_dir"; then
    log_stage "Manual Tag"
    manual_tag "$flac_dir" "$library_dir"
  fi

  # ── Stage 4b: Fetch Lyrics ──
  if [[ "$NO_LYRICS" == "false" ]]; then
    log_stage "Fetch Lyrics"
    fetch_lyrics "$library_dir" || true
  fi

  # ── Stage 5: Upload ──
  if [[ "$NO_UPLOAD" == "false" ]]; then
    log_stage "Upload"
    upload "$library_dir"
  fi

  # Copy to output dir if requested
  if [[ -n "$OUTPUT_DIR" ]]; then
    mkdir -p "$OUTPUT_DIR"
    cp -r "$library_dir"/* "$OUTPUT_DIR/"
    echo "Files also copied to: $OUTPUT_DIR"
  fi

  # ── Stage 6: Eject + Cleanup ──
  log_stage "Eject & Cleanup"
  eject_cd "$CD_DEVICE"

  print_summary "$library_dir"
}

main "$@"
