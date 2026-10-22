# Estado de backports

Base: parche oficial PHP-7.4 (`712e60f9ed`). Cada versión: parche en
`patches/php-<ver>.patch`, build en docker con regeneración de la VM, y
verificación con `poc/regression.sh`.

Leyenda verificación: REG = test de regresión (mecanismo zend_mm_safe_error_ex,
cubre la vía de corrupción por bailout). El resto de hunks (session callback,
resets de main.c/SAPI.c/zend_execute_API.c) son port fiel del upstream,
aplicados pero no cubiertos por el test automático.

| Versión | Motor | Parche | Build | REG | Notas de adaptación |
|---------|-------|--------|-------|-----|---------------------|
| 7.4.33  | PHP7  | oficial | OK | PATCHED | aplica tal cual |
| 7.3.33  | PHP7  | php-7.3.33.patch | OK | PATCHED | +ZSTR_MAX_LEN/OVERHEAD (no existían); guarda CONCAT-extend agregada; resets en rama fast_shutdown |
| 7.2.34  | PHP7  | php-7.2.34.patch | OK | PATCHED | conjunto esencial (sin VM-concat/singleton); +ZSTR_MAX_LEN n/a |
| 7.1.33  | PHP7  | php-7.1.33.patch | OK | PATCHED | esencial; uncond resets tras EG(active)=0 |
| 7.0.33  | PHP7  | php-7.0.33.patch | OK | PATCHED | esencial; objects_store free de 1 arg |
| 5.6.40  | PHP5  | php-5.6.40.patch | OK | PATCHED | re-derivación esencial |
| 5.5.38  | PHP5  | pendiente | - | - | re-derivación |
| 5.4.45  | PHP5  | pendiente | - | - | re-derivación |

Imágenes docker: 7.x -> debian:bookworm, 5.x -> debian:jessie (archive.debian.org).

## Conjunto esencial vs completo

7.3.33 lleva el port COMPLETO del parche oficial (incluye guardas de overflow
en ZEND_CONCAT/FAST_CONCAT y la optimización de arrays singleton +
HT_HASH_RESET).

7.2/7.1/7.0 (y 5.x) llevan el **conjunto esencial**, que cierra ambas CVE por
su vector principal y portea robusto entre versiones:
- `zend_mm_safe_error_ex` + conversión de los `zend_error_noreturn` de overflow
  en zend_alloc.c / zend_hash.c / zend_multiply.h (evita el bailout que corrompe
  estado -> CVE-2026-109619).
- Neutralización del callback `php_session_rfc1867_callback` (session.c),
  resets de `PG(http_globals)`/`PG(modules_activated)` (main.c), NULL tras efree
  (SAPI.c), resets de handlers en shutdown_executor (zend_execute_API.c), NULL
  de head/tail en zend_llist_destroy (-> CVE-2026-109618, estado stale reusado).
- Límite `max_multipart_body_parts` en rfc1867.c (acota el disparador OOM).

Excluido del esencial (hardening secundario, documentado): guardas de overflow
de concatenación en la VM (requieren tocar el archivo generado zend_vm_execute.h;
overflow solo alcanzable con strings ~SIZE_MAX) y los arrays singleton
(optimización de footprint, no vector de la CVE). El test de regresión verifica
el mecanismo safe_error_ex; el resto es port fiel del upstream.

## Re-derivación 5.x (motor pre-PHP7)

5.6/5.5/5.4 no comparten motor con 7.x, así que se re-derivó el conjunto esencial:
- `zend_alloc.c`: helper `zend_mm_safe_error_ex` (fprintf + `_exit(1)`), `zend_mm_safe_error`
  hace `_exit` directo en la ruta overflow==0 (antes de cualquier bailout), las 6
  rutas de overflow de enteros y la de string allocation pasan a `_exit`, y
  `zend_mm_panic` usa `_exit`. Cierra el vector de corrupción por bailout (109619).
- `ext/session/session.c`: `if (!PS(rfc1867_enabled) || 1)` neutraliza el callback
  de upload_progress (109618).
- `main/main.c`: `PG(http_globals)[i] = NULL` tras el dtor en request_shutdown.
- `main/SAPI.c`: NULL tras efree de auth_user/password/digest/content_type_dup/current_user.

Omitido en 5.x (documentado): resets de handlers en `shutdown_executor` (estructura
del motor 5.x muy distinta; el vector principal de 109618 ya queda cerrado por la
neutralización del callback y el reset de http_globals), guardas de concat en la VM
y arrays singleton (hardening secundario). Verificado: baseline VULNERABLE,
parcheado PATCHED, build limpio en debian:jessie (gcc 4.9).
