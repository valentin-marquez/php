#!/usr/bin/env bash
# build.sh <php-version> <base-image> [patch-file]
# Compila PHP CLI mínimo en Docker (toolchain de época) desde el tarball
# oficial de php.net. Si se pasa patch-file, lo aplica con `patch -p1`.
# Deja el binario en build/out/php-<version>[-patched].
set -euo pipefail
docker info >/dev/null 2>&1 || { echo "ERROR: docker daemon no corre. Levantalo con: sudo systemctl start docker"; exit 4; }
VER="${1:?version, ej 7.4.33}"; IMG="${2:?imagen, ej debian:bookworm}"; PATCH="${3:-}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/build/out"; mkdir -p "$OUT"
TAG="php-$VER"; [ -n "$PATCH" ] && TAG="$TAG-patched"
rm -f "$OUT/$TAG"
URL="https://www.php.net/distributions/php-$VER.tar.gz"
# imágenes Debian EOL: sus repos viven solo en archive.debian.org
ARCHIVE=""
case "$IMG" in *jessie*|*wheezy*|*stretch*) ARCHIVE=1;; esac
PATCHMNT=""; PATCHCP=""
if [ -n "$PATCH" ]; then PATCHMNT="-v $PATCH:/patch.diff:ro"; PATCHCP='echo ">> aplicando parche"; patch -p1 --fuzz=3 < /patch.diff;'; fi
docker run --rm $PATCHMNT -v "$OUT:/out" "$IMG" bash -c '
  set -e
  export DEBIAN_FRONTEND=noninteractive
  if [ -n "'"$ARCHIVE"'" ]; then
    sed -i "s|deb.debian.org|archive.debian.org|g; s|security.debian.org|archive.debian.org|g; /-updates/d" /etc/apt/sources.list
    APTOPT="-o Acquire::Check-Valid-Until=false --allow-unauthenticated"
  else APTOPT=""; fi
  apt-get $APTOPT update -qq
  apt-get $APTOPT install -y --no-install-recommends curl ca-certificates build-essential autoconf bison re2c pkg-config libxml2-dev >/dev/null
  cd /tmp
  curl -fsSL "'"$URL"'" -o php.tar.gz
  tar xzf php.tar.gz && cd "php-'"$VER"'"
  '"$PATCHCP"'
  ./configure --disable-all --enable-cli --without-pear >/dev/null
  make -j"$(nproc)" >/dev/null
  cp sapi/cli/php /out/"'"$TAG"'"
  /out/"'"$TAG"'" -v | head -1
'
[ -x "$OUT/$TAG" ] || { echo "BUILD_FAILED: no se generó $OUT/$TAG"; exit 5; }
echo "OK -> build/out/$TAG"
