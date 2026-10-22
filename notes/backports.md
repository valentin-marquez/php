# Estado de backports

Base: parche oficial PHP-7.4 (`712e60f9ed`, verbatim en `patches/official-PHP-7.4.patch`).
Cada versión: parche en `patches/php-<ver>.patch`, build en docker con regeneración
de la VM, y verificación con `poc/regression.sh`.

Leyenda verificación: REG = test de regresión (mecanismo zend_mm_safe_error_ex,
cubre la vía de corrupción por bailout). El build usa `--enable-session` (ver
`build/build.sh`), así que `ext/session/session.c` —el vector parcheado— sí se
compila; el resto de hunks (resets de main.c/SAPI.c/zend_execute_API.c) son port
fiel del upstream, aplicados y compilados pero no cubiertos por el test automático.

| Versión | Motor | Parche | Build | REG | Notas de adaptación |
|---------|-------|--------|-------|-----|---------------------|
| 8.1.33  | PHP8  | oficial EOL (verbatim, `1d7dec1`) | OK | PATCHED | rama `PHP-8.1-CVE-2026-109618-109619` |
| 8.0.30  | PHP8  | oficial EOL (verbatim, `82f8f31b`) | OK | PATCHED | rama `PHP-8.0-CVE-2026-109618-109619` |
| 7.4.33  | PHP7  | oficial EOL (verbatim, `712e60f9`) | OK | PATCHED | aplica tal cual; `|| true` (7.4 define `true`) |
| 7.3.33  | PHP7  | php-7.3.33.patch | OK | PATCHED | completo; +ZSTR_MAX_LEN/OVERHEAD; singleton vía HT_HASH_RESET |
| 7.2.34  | PHP7  | php-7.2.34.patch | OK | PATCHED | completo (paridad con PR comunitario 7.1) |
| 7.1.33  | PHP7  | php-7.1.33.patch | OK | PATCHED | completo; calca el PR comunitario #24500 (ieth0) |
| 7.0.33  | PHP7  | php-7.0.33.patch | OK | PATCHED | completo; guardas concat adaptadas (usa `zend_string_realloc`, no `extend`) |
| 5.6.40  | PHP5  | php-5.6.40.patch | OK | PATCHED | re-derivación esencial |
| 5.5.38  | PHP5  | php-5.5.38.patch | OK | PATCHED | re-derivación esencial (anclas idénticas a 5.6) |
| 5.4.45  | PHP5  | php-5.4.45.patch | OK | PATCHED | re-derivación esencial (anclas idénticas a 5.6) |

Imágenes docker: 7.x/8.x -> debian:bookworm, 5.x -> debian:jessie (archive.debian.org).

## Cobertura: desde 5.4 hasta 8.1

Backport necesario (ramas EOL sin release corregido): 5.4, 5.5, 5.6, 7.0, 7.1,
7.2, 7.3, 7.4, 8.0, 8.1 — todas en la tabla, verificadas. PHP 6 nunca existió.
Para 7.4/8.0/8.1 hay parche oficial *source-only* (ramas `PHP-<x>-CVE-2026-109618-109619`),
guardado verbatim en `patches/official-PHP-<x>.patch`.

De **8.2 en adelante NO se backportea**: hay release oficial corregido —8.2.35,
8.3.36, 8.4.27, 8.5.12—, la acción es actualizar a esa versión. Se conserva
`patches/official-PHP-8.2.35.patch` como referencia del fix en rama activa.

## Validación: parche comunitario + agente Fable

El único backport comunitario público en php-src es el PR **#24500** (ieth0 / Amin
Shayan), rama PHP-7.1, cerrado (la política oficial es actualizar, no backportear a
EOL) pero es el port **completo y fiel** del commit 7.4. Se usó como referencia
vetada para 7.1 y como patrón para 7.0/7.2. Upstream 7.4 y el PR comunitario 7.1
difieren en dos adaptaciones deliberadas por estructura de rama:
- `session.c`: upstream 7.4 usa `|| true`; el PR 7.1 usa `|| 1` porque las ramas
  pre-7.4 no definen `true`.
- `shutdown_executor`: upstream 7.4 inserta los resets tras el bloque gc; en la
  estructura de 7.0–7.3 eso no mapea, y el PR 7.1 los reubica al final, antes de
  `EG(active) = 0;`, incondicionalmente.

Un agente Fable auditó el 7.1 contra el PR y destapó tres defectos en los backports
7.0–7.3 (no en 7.4/8.0, que son verbatim upstream), ya corregidos:
- **B1 — compilación.** Los 7.x usaban `|| true` heredado de 7.4; en 7.0–7.3 `true`
  no existe -> error al compilar `ext/session`. No se detectaba porque el build
  antiguo usaba `--disable-all` (session apagado). Fix: `|| 1` + harness con
  `--enable-session` para que no vuelva a esconderse.
- **A1 — `shutdown_executor` mal ubicado.** El bloque de resets caía dentro del
  `#if ZEND_DEBUG` (7.1, se compilaba fuera en release), antes del free del object
  store (7.0, early-return + leak), o dentro de `if (full_tables_cleanup)` (7.2/7.3,
  no corría en el shutdown normal). Fix: bloque completo reubicado al final, antes
  de `EG(active) = 0;`, como el PR comunitario. No reabría el CVE (el `_exit(1)`
  primario ya mata el worker en vez de reusar estado stale) pero era un defecto real.
- **A2 — guarda `zend_mm_alloc_huge` ausente** en 7.0/7.1 (sí estaba en 7.2/7.3).
  Fix: añadida la guarda `new_size < size` del upstream.

## Conjunto completo (7.0–7.4)

Todas las ramas 7.x llevan ahora el port completo del parche oficial:
- `zend_mm_safe_error_ex` (varargs + vsnprintf + filename/lineno + `_exit(1)`) y
  conversión de los `zend_error_noreturn` de overflow en zend_alloc.c / zend_hash.c /
  zend_multiply.h / zend_strtod.c; `zend_mm_panic` y `zend_out_of_memory` con `_exit`;
  guarda de overflow en `zend_mm_alloc_huge` (evita el bailout que corrompe estado ->
  CVE-2026-109619).
- Neutralización del callback `php_session_rfc1867_callback` (session.c), resets de
  `PG(http_globals)`/`PG(modules_activated)` (main.c), NULL tras efree (SAPI.c),
  resets de object store + handlers en shutdown_executor (zend_execute_API.c), NULL
  de head/tail en zend_llist_destroy (-> CVE-2026-109618, estado stale reusado).
- Límite `max_multipart_body_parts` + retención solo de Content-Disposition/Content-Type
  en rfc1867.c (acota el disparador OOM y la duplicación de headers).
- Hardening secundario: guardas de overflow de concatenación en la VM
  (ZSTR_MAX_LEN + zend_vm_def.h; zend_vm_execute.h regenerado en build) y arrays
  singleton (array_init_singleton / HT_HASH_RESET en php_variables.c).

## Re-derivación 5.x (motor pre-PHP7)

5.6/5.5/5.4 no comparten motor con 7.x, así que se re-derivó el conjunto esencial:
- `zend_alloc.c`: helper `zend_mm_safe_error_ex` (fprintf `%s` + `_exit(1)`),
  `zend_mm_safe_error` hace `_exit` directo en la ruta overflow==0 (antes de cualquier
  bailout), las 6 rutas de overflow de enteros y la de string allocation pasan a
  `_exit`, y `zend_mm_panic` usa `_exit`. Cierra el vector de corrupción por bailout
  (109619). Call sites con literales fijos (sin format args), helper de 1 argumento.
- `ext/session/session.c`: `if (!PS(rfc1867_enabled) || 1)` neutraliza el callback
  de upload_progress (109618).
- `main/main.c`: `PG(http_globals)[i] = NULL` tras el dtor en request_shutdown.
- `main/SAPI.c`: NULL tras efree de auth_user/password/digest/content_type_dup/current_user.

No aplican a 5.x (motor): `zend_mm_alloc_huge` (ZendMM3 es de 7.0+), resets de
object store en `shutdown_executor` (estructura 5.x muy distinta; el vector principal
de 109618 ya queda cerrado por la neutralización del callback y el reset de
http_globals) y guardas de concat / arrays singleton (hardening secundario).
Verificado con session habilitado: baseline VULNERABLE, parcheado PATCHED, build
limpio en debian:jessie (gcc 4.9).
