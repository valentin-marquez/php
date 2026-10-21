#!/usr/bin/env bash
# Diferenciador patched/vulnerable SIN servidor web ni ASAN.
# El fix convierte los fatals de asignación (overflow / memory_limit excedido)
# en _exit(1) directo (zend_mm_safe_error_ex), en vez de bailout+E_ERROR
# catcheable. Un bailout NO corre register_shutdown_function; el fix tampoco.
# Test: exceder memory_limit y ver si corre el shutdown handler.
#   VULNERABLE  -> imprime SHUTDOWN_RAN (hubo bailout, estado reutilizable)
#   PATCHED     -> NO lo imprime (_exit inmediato)
PHP_BIN="${1:?uso: regression.sh /ruta/a/php}"
out=$("$PHP_BIN" -d memory_limit=16M -r '
  register_shutdown_function(function(){ fwrite(STDERR, "SHUTDOWN_RAN\n"); });
  $a = [];
  while (true) { $a[] = str_repeat("x", 100000); }
' 2>&1)
if echo "$out" | grep -q SHUTDOWN_RAN; then
  echo "VULNERABLE (bailout: shutdown corrió)"; exit 1
else
  echo "PATCHED (_exit: shutdown no corrió)"; exit 0
fi
