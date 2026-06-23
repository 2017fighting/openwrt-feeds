#!/usr/bin/env sh
# Generate a browsable index.html in every directory under the given site root.
#
# GitHub Pages has NO directory autoindex, so without these pages the site root
# and every subdirectory return 404. Run this after the binary feed is assembled
# and before the Pages artifact is uploaded.
#
#   sh tooling/make-index.sh site
set -eu

ROOT="${1:?usage: make-index.sh <site-root>}"
ROOT="$(cd "$ROOT" && pwd)"

human() {  # bytes -> human-readable (awk, POSIX)
  awk -v b="$1" 'BEGIN{
    split("B KB MB GB TB PB", u, " ")
    i = 1
    while (b >= 1024 && i < 6) { b /= 1024; i++ }
    printf "%.1f %s", b, u[i]
  }'
}

gen() {
  dir="$1"
  if [ "$dir" = "$ROOT" ]; then rel=""; else rel="${dir#"$ROOT"}"; rel="${rel#/}"; fi
  out="$dir/index.html"

  {
    printf '%s\n' '<!doctype html>'
    printf '<html lang="en"><head><meta charset="utf-8">'
    printf '<meta name="viewport" content="width=device-width, initial-scale=1">'
    printf '<title>Index of /%s</title>\n' "$rel"
    cat <<'CSS'
<style>
  body{font:14px/1.5 -apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif;margin:2rem auto;max-width:56rem;color:#1f2328}
  h1{font-size:1.05rem;font-weight:600;margin:0 0 .25rem}
  code{font-family:ui-monospace,SFMono-Regular,Menlo,monospace;background:#f6f8fa;padding:.1em .35em;border-radius:4px}
  table{border-collapse:collapse;width:100%;margin-top:1rem}
  th,td{padding:.4rem .6rem;text-align:left;border-bottom:1px solid #eaeef2}
  th{font-weight:600;color:#57606a;font-size:.75rem;text-transform:uppercase;letter-spacing:.04em}
  td.size,th.size{text-align:right;color:#57606a;font-variant-numeric:tabular-nums;white-space:nowrap;width:1%}
  a{color:#0969da;text-decoration:none}
  a:hover{text-decoration:underline}
  .muted{color:#57606a;margin:.2rem 0 0;font-size:.9rem}
</style>
CSS
    printf '</head><body>\n'
    printf '<h1>Index of <code>/%s</code></h1>\n' "$rel"
    printf '<p class="muted"><strong>openwrt-feeds</strong> — signed OpenWrt apk feed. '
    printf 'Repo: <a href="https://github.com/2017fighting/openwrt-feeds">2017fighting/openwrt-feeds</a>. '
    printf 'Public key: <a href="keys/key-build.pub">keys/key-build.pub</a>. '
    printf 'Docs: <a href="README.md">README.md</a>.</p>\n'
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
    printf '</tbody></table>\n</body></html>\n'
  } > "$out"
}

gen "$ROOT"
find "$ROOT" -mindepth 1 -type d 2>/dev/null | while read -r d; do gen "$d"; done

echo "make-index: wrote $(find "$ROOT" -name index.html | wc -l | tr -d ' ') index.html file(s) under $ROOT"
