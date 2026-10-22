# php — backport CVE-2026-109618 / CVE-2026-109619

Backport del fix oficial de las dos RCE no autenticadas de PHP (CVSS 9.2,
release del 2026-10-21) hacia versiones EOL: desde 8.1 hasta PHP 5.4.0 (donde
nace el código vulnerable). De 8.2 en adelante hay release oficial corregido
(8.2.35 / 8.3.36 / 8.4.27 / 8.5.12): ahí se actualiza, no se backportea.

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

Fijado en release: 8.5.12 / 8.4.27 / 8.3.36 / 8.2.35 (sus commits de release se
archivan verbatim en `patches/official-PHP-8.{2,3,4,5}.*.patch`, solo referencia,
no se compilan). Parches oficiales *source-only* (ramas EOL, sin binario) para
7.4, 8.0 y 8.1, también verbatim. Debajo de 7.4 es todo backport propio.

## Estructura

- `patches/` — parches oficiales extraídos + los nuestros, uno por versión
- `build/`   — Dockerfiles por era de toolchain + `build.sh`
- `poc/`     — test de regresión del UAF (debe fallar sin parche, pasar con)
- `notes/`   — mapeo de hunks, errores de compilación y cómo se mitigaron
- `.upstream/` — clon de php-src (no se commitea), fuente de los parches

## Estado: COMPLETO

Escalera de backport verificada 8.1.33 -> 5.4.45. Cada binario parcheado pasa
el test de regresión (`poc/regression.sh`): el baseline es VULNERABLE y el
parcheado PATCHED.

| Versión | Base | Verificación |
|---------|------|--------------|
| 8.1.33 / 8.0.30 / 7.4.33 | parche oficial EOL (verbatim) | PATCHED |
| 7.3.33 / 7.2.34 / 7.1.33 / 7.0.33 | port completo | PATCHED |
| 5.6.40 / 5.5.38 / 5.4.45 | re-derivación esencial (motor PHP5) | PATCHED |

Los 7.x llevan el port completo (7.1 calca el PR comunitario #24500 de ieth0,
único backport público; 7.0/7.2 a paridad). El build usa `--enable-session`, así
que `ext/session/session.c` —el vector parcheado— se compila. Una auditoría con
agente Fable contra el PR comunitario corrigió tres defectos en los backports
7.0–7.3 (compilación `|| true`→`|| 1`, reubicación de resets de `shutdown_executor`,
guarda `zend_mm_alloc_huge`); detalle en `notes/backports.md`.

Parches en `patches/php-<ver>.patch`. Tags `backport-<ver>` por versión.
Detalle de alcance y adaptaciones por versión en `notes/backports.md`.

## Uso

Compilar un PHP parcheado (CLI mínimo, en docker con toolchain de época):

```
./build/build.sh 8.1.33 debian:bookworm patches/official-PHP-8.1.patch  # 8.0/8.1/7.4 oficial
./build/build.sh 7.2.34 debian:bookworm patches/php-7.2.34.patch        # familia 7.x
./build/build.sh 5.6.40 debian:jessie   patches/php-5.6.40.patch        # familia 5.x
```

Verificar un binario:

```
./poc/regression.sh build/out/php-7.2.34-patched
```

Para un deploy real hay que recompilar con el mismo `./configure` que la build
en producción (SAPI fpm/apache, extensiones), no el `--disable-all` del harness.
Los parches aplican igual: `patch -p1 --fuzz=3 < patches/php-<ver>.patch` sobre
el tarball oficial de esa versión.
