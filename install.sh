#!/bin/sh
# Auto-parche CVE-2026-109618 / CVE-2026-109619.
# Detecta el PHP del sistema, baja el tarball oficial y el backport que
# corresponde, aplica el parche y recompila con los MISMOS flags del build
# actual.
#
# Seguro por defecto: compila a un prefix de staging y NO toca el PHP en
# produccion; al final imprime los comandos para instalarlo. Con --install
# hace el "make install" y recuerda reiniciar el SAPI.
#
# Uso:
#   curl -fsSL https://raw.githubusercontent.com/valentin-marquez/php/main/install.sh | sh
#   curl -fsSL .../install.sh | sh -s -- --install     # compila E instala
#
# Variables de entorno opcionales:
#   PHP=/ruta/al/php    binario de PHP a parchear (por defecto: el del PATH)
#   REPO=...            base de los parches (por defecto: el repo publico)
#   PATCH_SHA256=hex    si se define, verifica el sha256 del parche bajado
set -eu

REPO="${REPO:-https://raw.githubusercontent.com/valentin-marquez/php/main}"
PHP="${PHP:-php}"

# Parseo de argumentos. Funciona igual por "curl | sh" (sin args) que por
# "curl | sh -s -- --install". Un flag desconocido aborta, para no proceder
# por error con una opcion mal escrita.
DO_INSTALL=0
for arg in "$@"; do
  case "$arg" in
    --install) DO_INSTALL=1 ;;
    -h|--help)
      echo "uso: install.sh [--install]"
      echo "  sin --install: compila a un prefix de staging y no toca produccion"
      echo "  con  --install: ademas instala sobre el PHP actual"
      exit 0 ;;
    *) printf 'error: argumento no reconocido: %s\n' "$arg" >&2; exit 2 ;;
  esac
done

say(){ printf '%s\n' "$*"; }
die(){ printf 'error: %s\n' "$*" >&2; exit 1; }

command -v "$PHP" >/dev/null 2>&1 || die "no encuentro '$PHP' en el PATH (exporta PHP=/ruta/al/php)"
command -v curl >/dev/null 2>&1 || die "falta curl"

FULL=$("$PHP" -r 'echo PHP_VERSION;' 2>/dev/null) || die "no pude leer la version de PHP"
XY=$(echo "$FULL" | cut -d. -f1,2)

# Cada rama EOL se recompila como la ultima release de esa minor, que es la que
# tiene parche; parchear hacia la ultima minor es ademas el movimiento sano de
# seguridad. Los nombres de archivo son exactos, viven en patches/.
case "$XY" in
  5.4) VER=5.4.45; PF=php-5.4.45 ;;
  5.5) VER=5.5.38; PF=php-5.5.38 ;;
  5.6) VER=5.6.40; PF=php-5.6.40 ;;
  7.0) VER=7.0.33; PF=php-7.0.33 ;;
  7.1) VER=7.1.33; PF=php-7.1.33 ;;
  7.2) VER=7.2.34; PF=php-7.2.34 ;;
  7.3) VER=7.3.33; PF=php-7.3.33 ;;
  7.4) VER=7.4.33; PF=official-PHP-7.4 ;;
  8.0) VER=8.0.30; PF=official-PHP-8.0 ;;
  8.1) VER=8.1.33; PF=official-PHP-8.1 ;;
  *) die "PHP $XY no cubierto. Soportado 5.4 a 8.1. 8.2+ tiene release oficial corregido: actualiza al release oficial." ;;
esac

say ">> sistema: PHP $FULL (rama $XY)"
say ">> parche:  $PF -> recompila como PHP $VER"
[ "$FULL" != "$VER" ] && say "   nota: tu build es $FULL; se recompila como $VER (ultima de la rama) mas el fix."

# Flags del build actual, sin el './configure' inicial que imprime phpinfo.
CFG=$("$PHP" -i 2>/dev/null | sed -n "s/^Configure Command => //p" | sed "s/'\.\/configure'//")
if [ -z "$CFG" ]; then
  # Los paquetes de Debian/Ubuntu no exponen 'Configure Command' en 'php -i'.
  # Si esta instalado el paquete -dev, php-config si da los flags.
  for pc in "${PHP}-config" "php-config${XY}" php-config; do
    command -v "$pc" >/dev/null 2>&1 || continue
    CFG=$("$pc" --configure-options 2>/dev/null); [ -n "$CFG" ] && break
  done
fi
if [ -z "$CFG" ]; then
  # Sin flags no sabemos reproducir el build de produccion. En staging se
  # permite (es un build de prueba aislado); instalar a ciegas no, porque
  # pisaria el PHP real con un binario sin las extensiones del sistema.
  if [ "$DO_INSTALL" = 1 ]; then
    die "no pude detectar los flags de ./configure. En Debian/Ubuntu los paquetes de apt no los exponen; instala el paquete -dev (por ejemplo php${XY}-dev) para tener php-config, o compila a mano con tus flags. Ten en cuenta que reconstruir un PHP de la distro desde el tarball oficial no reemplaza limpio los SAPI empaquetados (fpm, apache); ver el README."
  fi
  say ">> aviso: no detecte flags de configure; uso un build minimo (solo staging, NO apto produccion)"
fi

for t in gcc make tar; do
  command -v "$t" >/dev/null 2>&1 || die "falta '$t'. En Debian/Ubuntu: sudo apt-get install build-essential autoconf bison re2c pkg-config libxml2-dev"
done
JOBS=$(nproc 2>/dev/null || echo 1)

WORK=$(mktemp -d)
# Limpieza en fallo o interrupcion. En build-only exitoso NO se borra: el
# usuario necesita el arbol para inspeccionar e instalar despues (se quita el
# trap mas abajo). En --install exitoso si se limpia.
trap 'rm -rf "$WORK"' EXIT INT TERM
cd "$WORK"

say ">> bajando php-$VER.tar.gz"
curl -fsSLO "https://www.php.net/distributions/php-$VER.tar.gz"
tar xzf "php-$VER.tar.gz"

say ">> bajando parche $PF.patch"
# Dentro del mktemp privado, no en /tmp compartido: evita carrera/symlink de
# otro usuario local sobre una ruta predecible.
PATCH="$WORK/$PF.patch"
curl -fsSL "$REPO/patches/$PF.patch" -o "$PATCH"

# Verificacion de integridad opcional. No hay hashes publicados aun, asi que
# por defecto no se verifica; si defines PATCH_SHA256 se exige que coincida.
if [ -n "${PATCH_SHA256:-}" ]; then
  command -v sha256sum >/dev/null 2>&1 || die "PATCH_SHA256 definido pero falta sha256sum"
  GOT=$(sha256sum "$PATCH" | cut -d' ' -f1)
  [ "$GOT" = "$PATCH_SHA256" ] || die "sha256 del parche no coincide (esperado $PATCH_SHA256, obtenido $GOT)"
  say ">> sha256 del parche verificado"
fi

cd "php-$VER"
say ">> aplicando $PF.patch"
# fuzz=0: el instalador compila la version EXACTA que el parche targetea, asi
# que debe aplicar sin desplazamiento. Si no aplica limpio, algo no cuadra
# (version equivocada, parche corrupto): abortamos ruidosamente en vez de
# dejar que el fuzz lo encaje mal.
patch -p1 --fuzz=0 < "$PATCH" || die "el parche no aplico limpio sobre php-$VER; abortando sin compilar"

STAGE="$WORK/stage"
if [ "$DO_INSTALL" = 1 ]; then
  say ">> configure con los flags detectados (instalacion real)"
  # shellcheck disable=SC2086
  eval ./configure $CFG
else
  say ">> configure a staging ($STAGE); no se toca el PHP de produccion"
  # El --prefix de staging va al final para ganarle al --prefix de los flags
  # detectados (en autoconf gana el ultimo).
  # shellcheck disable=SC2086
  eval ./configure $CFG --prefix="$STAGE"
fi

say ">> make -j$JOBS"
make -j"$JOBS"

# Los backports propios 7.0 a 7.3 tocan Zend/zend_vm_def.h pero NO incluyen el
# Zend/zend_vm_execute.h regenerado; hay que regenerarlo desde el php recien
# compilado y volver a compilar. Los oficiales (7.4/8.0/8.1) SI traen el header
# regenerado, por eso la condicion exige que el marcador este en def.h pero NO
# en execute.h. Los 5.x no tocan la VM y no entran aca.
if grep -q zend_mm_safe_error_ex Zend/zend_vm_def.h 2>/dev/null && \
   ! grep -q zend_mm_safe_error_ex Zend/zend_vm_execute.h 2>/dev/null; then
  say ">> regenerando zend_vm_execute.h desde zend_vm_def.h"
  ( cd Zend && ../sapi/cli/php zend_vm_gen.php )
  say ">> make -j$JOBS (segunda fase)"
  make -j"$JOBS"
fi

if [ "$DO_INSTALL" = 1 ]; then
  say ">> make install"
  if [ "$(id -u)" = 0 ]; then
    make install
  elif command -v sudo >/dev/null 2>&1; then
    sudo make install
  else
    die "make install necesita root y no hay sudo; corre el script como root o instala a mano desde $WORK/php-$VER"
  fi
  say ""
  say "LISTO. Reinicia tu SAPI para cargar el binario parcheado, por ejemplo:"
  say "  sudo systemctl restart php-fpm      # o php${XY}-fpm, o apache2, segun tu setup"
  say "y confirma con: $PHP -v"
else
  # Build-only exitoso: conservamos el arbol para inspeccionar. Quitamos el
  # trap de borrado.
  trap - EXIT INT TERM
  say ""
  say "BUILD LISTO (build de prueba en staging; no se instalo nada)."
  say "Binario parcheado para inspeccionar: $STAGE/bin/php"
  say ""
  say "Este arbol esta configurado con un prefix de staging, asi que NO corras"
  say "'make install' aqui: instalaria al staging, no a tu PHP. Para instalar de"
  say "verdad, re-ejecuta con --install (reconfigura con los flags de produccion):"
  say "  curl -fsSL $REPO/install.sh | sh -s -- --install"
  say ""
  say "Cuando termines, borra el arbol temporal:  rm -rf $WORK"
fi
