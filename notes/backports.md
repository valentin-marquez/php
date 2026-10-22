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
| 7.1.33  | PHP7  | pendiente | - | - | |
| 7.0.33  | PHP7  | pendiente | - | - | |
| 5.6.40  | PHP5  | pendiente | - | - | re-derivación (motor viejo) |
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
