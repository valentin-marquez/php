#!/usr/bin/env bash
# PoC end-to-end del trigger real: OOM en request-startup durante el parseo
# multipart de un SAPI web, con session.upload_progress habilitado. No es el
# loop CLI sintetico de regression.sh; usa php-cgi (SAPI web manejado por env
# CGI + body por stdin, sin servidor ni socket).
#
# El fix convierte el fatal de asignacion (OOM al exceder memory_limit, o
# overflow de enteros) de zend_error_noreturn()+zend_bailout() a un _exit(1)
# directo via zend_mm_safe_error_ex. Firmas observadas (7.x/5.x-cgi):
#   VULNERABLE: php-cgi captura el bailout en request-startup y aborta sin
#               emitir el fatal (exit 255, 0 bytes), con el estado de request
#               (sesion/unserializer/http_globals) a medio construir.
#   PATCHED:    zend_mm_safe_error_ex emite el fatal ("... in Unknown on line 0",
#               origen request-startup) y hace _exit(1) en el acto (exit 1).
#
# Alcance honesto: verifica el trigger real y el mecanismo del fix; no demuestra
# el UAF/type-confusion de 109618 ni que el OOM caiga dentro del codigo de
# upload_progress (cae en el crecimiento del hash de $_POST durante el parse,
# con la sesion de upload_progress ya enganchada).
set -u
CGI="${1:?uso: regression-multipart.sh /ruta/a/php-cgi}"
[ -x "$CGI" ] || { echo "ERROR: inexistente o no ejecutable: $CGI"; exit 2; }

MEM="${MEM:-2M}"            # memory_limit minusculo; ha de caer dentro del parseo
NFIELDS="${NFIELDS:-40000}" # campos POST; cada uno aloca en el parse loop
PAD="${PAD:-32}"            # relleno por campo

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
pad="$(head -c "$PAD" /dev/zero | tr '\0' x)"
echo '<?php echo "SCRIPT_RAN_OK\n";' > "$WORK/t.php"
B="----b$$X"

# body multipart: campo de progreso primero (engancha el callback de
# upload_progress) + parte de fichero (abre la sesion) + N campos con nombre
# distinto que construyen $_POST hasta reventar el limite durante el parse.
awk -v B="$B" -v N="$NFIELDS" -v PAD="$pad" 'BEGIN{ORS="";
  printf "--%s\r\nContent-Disposition: form-data; name=\"PHP_SESSION_UPLOAD_PROGRESS\"\r\n\r\npoc\r\n",B;
  printf "--%s\r\nContent-Disposition: form-data; name=\"up\"; filename=\"f.bin\"\r\nContent-Type: application/octet-stream\r\n\r\n%s\r\n",B,PAD;
  for(i=1;i<=N;i++) printf "--%s\r\nContent-Disposition: form-data; name=\"f%d\"\r\n\r\n%s\r\n",B,i,PAD;
  printf "--%s--\r\n",B;}' > "$WORK/body"
LEN=$(wc -c < "$WORK/body")

# corre un request CGI con memory_limit=$1; deja la salida en $WORK/o, imprime "rc bytes"
run(){ env REQUEST_METHOD=POST "CONTENT_TYPE=multipart/form-data; boundary=$B" \
    CONTENT_LENGTH="$LEN" GATEWAY_INTERFACE=CGI/1.1 REDIRECT_STATUS=1 \
    SCRIPT_FILENAME="$WORK/t.php" \
    "$CGI" -d memory_limit="$1" -d session.upload_progress.enabled=1 \
      -d session.save_path="$WORK" -d enable_post_data_reading=1 \
      -d max_input_vars="$((NFIELDS + 100))" \
      -d display_errors=1 -d log_errors=0 -d html_errors=0 < "$WORK/body" > "$WORK/o" 2>&1
  echo "$? $(wc -c < "$WORK/o")"; }

# liveness: mismo body con memoria amplia -> el binario debe completar el request
run 256M >/dev/null
grep -q SCRIPT_RAN_OK "$WORK/o" || { echo "ERROR: el binario no completa un request CGI valido (liveness fallo)"; exit 2; }

# prueba: memoria minuscula -> OOM durante el parseo
stat=$(run "$MEM"); rc=${stat%% *}; bytes=${stat##* }
fatal=$(grep -Eqi 'Allowed memory size|integer overflow in memory allocation' "$WORK/o" && echo yes || echo no)
startup=$(grep -q 'in Unknown on line 0' "$WORK/o" && echo yes || echo no)

echo "--- exit=$rc bytes=$bytes mem=$MEM campos=$NFIELDS ---"
if grep -q SCRIPT_RAN_OK "$WORK/o"; then
  echo "INCONCLUSO: el parseo termino sin OOM (el script corrio). Subi NFIELDS o baja MEM."; exit 3
elif [ "$fatal" = yes ] && [ "$startup" = yes ] && [ "$rc" -eq 1 ]; then
  echo "PATCHED (zend_mm_safe_error_ex: fatal en request-startup + _exit(1))"; exit 0
elif [ "$fatal" = no ] && [ "$rc" -eq 255 ] && [ "$bytes" -eq 0 ]; then
  echo "VULNERABLE (bailout tragado: request abortado exit 255, 0 bytes, estado a medio construir)"; exit 1
else
  echo "INCONCLUSO: firma inesperada (rc=$rc fatal=$fatal startup=$startup bytes=$bytes); out=[$(head -c 200 "$WORK/o" | tr '\n' '|')]"; exit 3
fi
