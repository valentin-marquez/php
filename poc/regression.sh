#!/usr/bin/env bash
# Diferenciador patched/vulnerable sin servidor web ni ASAN.
# El fix convierte el fatal de asignación (overflow / memory_limit excedido)
# en _exit(1) directo (zend_mm_safe_error_ex) en vez de bailout+E_ERROR.
# Un bailout corre register_shutdown_function; _exit no.
#   VULNERABLE -> imprime SHUTDOWN_RAN      PATCHED -> no lo imprime
set -u
PHP_BIN="${1:?uso: regression.sh /ruta/a/php}"
[ -x "$PHP_BIN" ] || { echo "ERROR: binario inexistente o no ejecutable: $PHP_BIN"; exit 2; }
"$PHP_BIN" -r 'echo "RUNS";' 2>/dev/null | grep -q RUNS || { echo "ERROR: el binario no ejecuta PHP"; exit 2; }
out=$("$PHP_BIN" -d memory_limit=16M -r '
  register_shutdown_function(function(){ fwrite(STDERR, "SHUTDOWN_RAN\n"); });
  fwrite(STDERR, "SCRIPT_START\n");
  $a = [];
  while (true) { $a[] = str_repeat("x", 100000); }
' 2>&1)
echo "$out" | grep -q SCRIPT_START || { echo "ERROR: el script no arrancó; out=[$out]"; exit 2; }
echo "$out" | grep -qi 'memory\|allocat' || { echo "ADVERTENCIA: no se ve el error de memoria; out=[$out]"; }
if echo "$out" | grep -q SHUTDOWN_RAN; then
  echo "VULNERABLE (bailout: el shutdown corrió)"; exit 1
else
  echo "PATCHED (_exit: el shutdown no corrió)"; exit 0
fi
