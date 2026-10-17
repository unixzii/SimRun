#!/bin/sh
# bundle.sh <bundle> <path>=<source>...: assembles <bundle> from its parts, signs it and puts it in place.
# Each <path> is in the bundle: one ending in / is a folder that <source> goes into under its own name, any other is
# <source>'s new name. Folders are copied whole (with ditto: symbolic links stay links), without .DS_Store files.
# The bundle is signed ad hoc as a whole ($SIGN --deep; SIGN defaults to codesign -s - -f).
# It is assembled next to <bundle> and swapped in with a rename, so a process running from the old bundle keeps its
# (unlinked) files instead of having them overwritten underneath it.
set -e
bundle=$1; shift
new=$(dirname "$bundle")/.$(basename "$bundle").new
old=$(dirname "$bundle")/.$(basename "$bundle").old
rm -rf "$new" "$old"
mkdir -p "$new"
for part in "$@"; do
  path=${part%%=*} source=${part#*=}
  case $path in
    */) dest=$new/$path$(basename "$source") ;;
    *)  dest=$new/$path ;;
  esac
  mkdir -p "$(dirname "$dest")"
  if [ -d "$source" ]; then ditto "$source" "$dest"; else cp "$source" "$dest"; fi
done
find "$new" -name .DS_Store -delete
${SIGN:-codesign -s - -f} --deep "$new" 2>/dev/null
if [ -d "$bundle" ]; then mv "$bundle" "$old"; fi
mv "$new" "$bundle"
rm -rf "$old"
