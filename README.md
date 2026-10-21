# php — backport CVE-2026-109618 / CVE-2026-109619

Backport del fix oficial de las dos RCE no autenticadas de PHP (CVSS 9.2,
release del 2026-10-21) hacia versiones EOL, hasta PHP 5.4.0 (donde nace el
código vulnerable).

## Las vulnerabilidades

| CVE | Clase | Causa raíz |
|-----|-------|------------|
| CVE-2026-109618 | UAF / memory disclosure + RCE | estado de `session.upload_progress` y del unserializer queda colgando si un fatal (OOM > `memory_limit`) interrumpe el parseo multipart antes de `zend_activate_modules()`; el heap de request se libera con `PS(id)`/`PS(http_session_vars)`/`BG(unserialize)` aún apuntando a él |
| CVE-2026-109619 | stale bucket / type confusion + RCE | `_zend_hash_str_add_or_update_i()` incrementa `nNumUsed`/`nNumOfElements` antes de alocar la key; si esa alocación hace fatal, `zend_array_destroy()` recorre un bucket contado pero sin inicializar |

Disparador común: fatal error (típicamente OOM al exceder `memory_limit`)
durante el arranque del request / parseo multipart, que salta la limpieza.
Config por defecto es vulnerable. Código vulnerable desde 5.4.0.

Funciones tocadas (según writeups): `rfc1867_post_handler`,
`register_http_post_files_variable_ex`, `php_register_variable_ex`,
`_zend_hash_str_add_or_update_i`, `zend_array_destroy`,
`php_session_rfc1867_callback/cleanup`, `php_session_initialize`,
`php_session_track_init`, `php_rshutdown_session_globals`,
`php_var_unserialize_init/destroy`, `var_push_dtor_value`,
`php_hash_environment`, `zend_activate_modules`, `php_request_shutdown`.

## Oficial (base ya desplegada)

Fijado: 8.5.12 / 8.4.27 / 8.3.36 / 8.2.35. Backports mínimos oficiales para
7.4, 8.0, 8.1. Nuestro trabajo empieza DEBAJO de 7.4.

## Estructura

- `patches/` — parches oficiales extraídos + los nuestros, uno por versión
- `build/`   — Dockerfiles por era de toolchain + `build.sh`
- `poc/`     — test de regresión del UAF (debe fallar sin parche, pasar con)
- `notes/`   — mapeo de hunks, errores de compilación y cómo se mitigaron
- `.upstream/` — clon de php-src (no se commitea), fuente de los parches
