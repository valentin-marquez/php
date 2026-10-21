#!/usr/bin/env bash
# build.sh <php-version> <base-image> [patch-file]
# Compila PHP CLI mínimo en Docker (toolchain de época) desde el tarball
# oficial de php.net. Si se pasa patch-file, lo aplica con `patch -p1`.
# Deja el binario en build/out/php-<version>[-patched].
set -euo pipefail
VER="${1:?version, ej 7.4.33}"; IMG="${2:?imagen, ej debian:bullseye}"; PATCH="${3:-}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/build/out"; mkdir -p "$OUT"
TAG="php-$VER"; [ -n "$PATCH" ] && TAG="$TAG-patched"
MAJ="${VER%%.*}"
# museum.php.net sirve TODOS los releases históricos
URL="https://www.php.net/distributions/php-$VER.tar.gz"
PATCHMNT=""; PATCHCP=""
if [ -n "$PATCH" ]; then PATCHMNT="-v $PATCH:/patch.diff:ro"; PATCHCP='patch -p1 < /patch.diff || (echo PATCH_FAILED; exit 3);'; fi
docker run --rm $PATCHMNT -v "$OUT:/out" "$IMG" bash -c "
  set -e
  export DEBIAN_FRONTEND=noninteractive
  (apt-get update -qq && apt-get install -y -qq curl build-essential autoconf bison re2c pkg-config libxml2-dev >/dev/null) || \
    (sed -i 's|deb.debian.org|archive.debian.org|g; /security/d' /etc/apt/sources.list; apt-get -o Acquire::Check-Valid-Until=false update -qq && apt-get install -y -qq --allow-unauthenticated curl build-essential autoconf bison re2c pkg-config libxml2-dev >/dev/null)
  cd /tmp
  curl -fsSL '$URL' -o php.tar.gz
  tar xzf php.tar.gz && cd php-$VER
  $PATCHCP
  ./configure --disable-all --enable-cli --without-pear >/dev/null 2>&1 || ./configure --disable-all --enable-cli
  make -j\$(nproc) >/dev/null 2>&1 || make
  cp sapi/cli/php /out/$TAG
  /out/$TAG -v | head -1
"
echo "OK -> build/out/$TAG"
