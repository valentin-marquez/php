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
| 7.2.34  | PHP7  | pendiente | - | - | |
| 7.1.33  | PHP7  | pendiente | - | - | |
| 7.0.33  | PHP7  | pendiente | - | - | |
| 5.6.40  | PHP5  | pendiente | - | - | re-derivación (motor viejo) |
| 5.5.38  | PHP5  | pendiente | - | - | re-derivación |
| 5.4.45  | PHP5  | pendiente | - | - | re-derivación |

Imágenes docker: 7.x -> debian:bookworm, 5.x -> debian:jessie (archive.debian.org).
