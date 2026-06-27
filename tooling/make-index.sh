#!/usr/bin/env sh
# Generate a browsable index.html in every directory under the given site root.
#
# GitHub Pages has NO directory autoindex, so without these pages the site root
# and every subdirectory return 404. On arch-level pages (the dirs that hold
# packages.adb + index.json) it also renders a packages table (from index.json)
# and an install-commands box with a copy button.
#
#   sh tooling/make-index.sh site
#   SITE_BASE=https://user.github.io/repo sh tooling/make-index.sh site
set -eu

ROOT="${1:?usage: make-index.sh <site-root>}"
ROOT="$(cd "$ROOT" && pwd)"
SITE_BASE="${SITE_BASE:-https://2017fighting.github.io/openwrt-feeds}"
SITE_BASE="${SITE_BASE%/}"

human() {  # bytes -> human-readable (awk, POSIX)
  awk -v b="$1" 'BEGIN{
    split("B KB MB GB TB PB", u, " ")
    i = 1
    while (b >= 1024 && i < 6) { b /= 1024; i++ }
    printf "%.1f %s", b, u[i]
  }'
}
esc() { sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g'; }   # minimal HTML-escape

gen() {
  dir="$1"
  if [ "$dir" = "$ROOT" ]; then rel=""; else rel="${dir#"$ROOT"}"; rel="${rel#/}"; fi
  out="$dir/index.html"

  # Arch-level page? (holds the apk index + manifest)
  is_arch=0; pkgs=""
  if [ -f "$dir/packages.adb" ] && [ -f "$dir/index.json" ] && command -v jq >/dev/null 2>&1; then
    is_arch=1
    pkgs=$(jq -r '.packages | to_entries[] | "\(.key)\t\(.value)"' "$dir/index.json" 2>/dev/null || true)
  fi

  {
    printf '%s\n' '<!doctype html>'
    printf '<html lang="en"><head><meta charset="utf-8">'
    printf '<meta name="viewport" content="width=device-width, initial-scale=1">'
    printf '<title>Index of /%s</title>\n' "$rel"
    cat <<'CSS'
<style>
  body{font:14px/1.5 -apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif;margin:2rem auto;max-width:56rem;color:#1f2328}
  h1{font-size:1.05rem;font-weight:600;margin:0 0 .25rem}
  h2{font-size:.95rem;font-weight:600;margin:1.6rem 0 .4rem}
  code,pre{font-family:ui-monospace,SFMono-Regular,Menlo,monospace}
  code{background:#f6f8fa;padding:.1em .35em;border-radius:4px}
  pre{background:#f6f8fa;padding:.8rem 1rem;border-radius:6px;overflow:auto}
  table{border-collapse:collapse;width:100%;margin-top:.4rem}
  th,td{padding:.4rem .6rem;text-align:left;border-bottom:1px solid #eaeef2}
  th{font-weight:600;color:#57606a;font-size:.75rem;text-transform:uppercase;letter-spacing:.04em}
  td.size,th.size{text-align:right;color:#57606a;font-variant-numeric:tabular-nums;white-space:nowrap;width:1%}
  a{color:#0969da;text-decoration:none} a:hover{text-decoration:underline}
  .muted{color:#57606a;margin:.2rem 0 0;font-size:.9rem}
  button{font:inherit;cursor:pointer;border:1px solid #d0d7de;border-radius:6px;background:#fff;padding:.35rem .8rem;margin-top:.5rem}
  button:hover{background:#f6f8fa}
  .pill{display:inline-block;background:#ddf4ff;color:#0969da;border-radius:99px;padding:.05em .6em;font-size:.8rem;font-weight:600}
</style>
CSS
    printf '</head><body>\n'
    printf '<h1>Index of <code>/%s</code></h1>\n' "$rel"
    printf '<p class="muted"><strong>openwrt-feeds</strong> — signed OpenWrt apk feed. '
    printf 'Repo: <a href="https://github.com/2017fighting/openwrt-feeds">2017fighting/openwrt-feeds</a>. '
    printf 'Public key: <a href="%s/keys/2017fighting.pem">2017fighting.pem</a>. ' "$SITE_BASE"
    printf 'Docs: <a href="%s/README.md">README.md</a>.</p>\n' "$SITE_BASE"

    # Quick-install box: root page only (feed.sh is copied to the site root).
    if [ "$dir" = "$ROOT" ] && [ -f "$ROOT/feed.sh" ]; then
      qi=$(printf 'sh -c "$(wget -O- %s/feed.sh)"' "$SITE_BASE")
      qie=$(printf '%s' "$qi" | esc)
      printf '<h2>Quick install</h2>\n'
      printf '<p class="muted">Auto-detects arch + release, installs the signing key and feed, then runs <code>apk update</code>.</p>\n'
      printf '<pre><code id="qi">%s</code></pre>\n' "$qie"
      cat <<'QIBTN'
<button onclick="navigator.clipboard.writeText(document.getElementById('qi').textContent).then(()=>{this.textContent='Copied ✓';setTimeout(()=>this.textContent='Copy',1500)})">Copy</button>
QIBTN
    fi

    # File listing
    printf '<h2>Files</h2>\n'
    printf '<table><thead><tr><th>Name</th><th class="size">Size</th></tr></thead><tbody>\n'
    if [ -n "$rel" ]; then
      printf '<tr><td><a href="../index.html">../</a></td><td class="size">—</td></tr>\n'
    fi
    find "$dir" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | sort | while read -r d; do
      n=$(basename "$d")
      printf '<tr><td><a href="%s/index.html">%s/</a></td><td class="size">—</td></tr>\n' "$n" "$n"
    done
    find "$dir" -mindepth 1 -maxdepth 1 -type f ! -name 'index.html' 2>/dev/null | sort | while read -r f; do
      n=$(basename "$f")
      sz=$(wc -c < "$f" | tr -d ' ')
      printf '<tr><td><a href="%s">%s</a></td><td class="size">%s</td></tr>\n' "$n" "$n" "$(human "$sz")"
    done
    printf '</tbody></table>\n'

    # Arch-level extras: packages table + install box
    if [ "$is_arch" = "1" ] && [ -n "$pkgs" ]; then
      printf '<h2>Packages</h2>\n'
      printf '<table><thead><tr><th>Package</th><th>Version</th></tr></thead><tbody>\n'
      TAB="$(printf '\t')"
      printf '%s\n' "$pkgs" | while IFS="$TAB" read -r name ver; do
        [ -n "$name" ] || continue
        ne=$(printf '%s' "$name" | esc)
        ve=$(printf '%s' "$ver" | esc)
        printf '<tr><td>%s</td><td><span class="pill">%s</span></td></tr>\n' "$ne" "$ve"
      done
      printf '</tbody></table>\n'

      repo_url="$SITE_BASE/$rel"
      key_url="$SITE_BASE/keys/2017fighting.pem"
      addlist=$(printf '%s\n' "$pkgs" | while IFS="$TAB" read -r name _; do [ -n "$name" ] && printf '%s ' "$name"; done)
      addlist="${addlist% }"
      # feed.sh (at the site root) installs the signing key, registers this feed
      # for the detected arch+release, and runs `apk update` — so the per-arch
      # install box just runs it, then `apk add`s the packages.
      cmd="sh -c \"\$(wget -O- ${SITE_BASE}/feed.sh)\"
apk add ${addlist}"
      ce=$(printf '%s' "$cmd" | esc)
      re=$(printf '%s' "$repo_url" | esc)
      printf '<h2>Repository URL</h2>\n'
      printf '<p><code id="ru">%s</code> \n' "$re"
      cat <<'RUBTN'
<button onclick="navigator.clipboard.writeText(document.getElementById('ru').textContent).then(()=>{this.textContent='Copied ✓';setTimeout(()=>this.textContent='Copy URL',1500)})">Copy URL</button></p>
RUBTN
      printf '<h2>Install on this arch</h2>\n'
      printf '<pre><code id="ic">%s</code></pre>\n' "$ce"
      cat <<'BTN'
<button onclick="navigator.clipboard.writeText(document.getElementById('ic').textContent).then(()=>{this.textContent='Copied ✓';setTimeout(()=>this.textContent='Copy install commands',1500)})">Copy install commands</button>
BTN
    fi

    printf '</body></html>\n'
  } > "$out"
}

gen "$ROOT"
find "$ROOT" -mindepth 1 -type d 2>/dev/null | while read -r d; do gen "$d"; done

echo "make-index: wrote $(find "$ROOT" -name index.html | wc -l | tr -d ' ') index.html file(s) under $ROOT"
