# Mecanismo del fix oficial (base: PHP-7.4 `712e60f9ed`, "minimal mitigation for EOL")

Fix GHSA-w8hw-w9fx-j79w (CVE-2026-109618) + GHSA-6wmf-4rv5-p3rp (CVE-2026-109619).
Autores: Arnaud Le Blanc, Ilija Tovilo.

## La idea central

El bug nace de un **bailout (longjmp) a mitad de operación**: al fallar una
asignación de memoria (overflow de enteros u OOM) PHP llamaba
`zend_error_noreturn(E_ERROR, ...)` → `zend_bailout()`. Ese longjmp salta en
medio de una operación de hash/alloc que ya había incrementado contadores o
dejado punteros a medio inicializar, y el teardown posterior recorre esa
estructura corrupta. De ahí la UAF / type-confusion reutilizable por el
siguiente request en el mismo worker.

## Hunks esenciales para cerrar las CVE

1. **`zend_mm_safe_error_ex` (NUEVO, Zend/zend_alloc.c + .h)**: núcleo.
   Reemplaza el `zend_error_noreturn`+bailout en las rutas de fallo de
   asignación por un fatal que imprime y hace `_exit(1)` directo. Sin longjmp,
   sin estado corrupto reutilizable. Además `zend_mm_panic` y
   `zend_out_of_memory` pasan de `exit(1)` a `_exit(1)` (no corre atexit sobre
   heap corrupto).
2. **Zend/zend_hash.c**: las 3 ramas de overflow de enteros pasan a
   `zend_mm_safe_error_ex`. Añade `zend_new_array_singleton()` (array con
   nTableSize=1, asignación mínima).
3. **main/rfc1867.c**: ini `max_multipart_body_parts` (default -1 →
   `max_input_vars + max_file_uploads`), corta el POST al excederlo; solo
   guarda headers Content-Disposition/Content-Type y descarta duplicados;
   fixes `int`→`size_t`. Acota el disparador OOM.
4. **ext/session/session.c**: `if (!PS(rfc1867_enabled) || true)` neutraliza
   el cuerpo de `php_session_rfc1867_callback` (mata la vía upload_progress).
5. **main/main.c**: en `php_request_shutdown`: `ZVAL_UNDEF(&PG(http_globals)[i])`
   y `PG(modules_activated)=0`. El siguiente request no reusa punteros stale.
6. **main/SAPI.c**: NULL tras `efree` de auth_user/password/digest/
   content_type_dup/current_user.
7. **Zend/zend_execute_API.c**: `shutdown_executor` resetea error/exception
   handlers y objects_store aun si el bailout ocurrió antes de init_executor.
8. **main/php_variables.c**: `array_init_singleton` para los arrays GPC
   (minimiza footprint en la ventana pre-activación).

## Secundario (hardening profundo, evaluar por versión)

`Zend/zend_vm_def.h` + `Zend/zend_vm_execute.h` (generado), `Zend/zend_types.h`,
`Zend/zend_alloc` extra, y en el release completo también `ext/opcache/*`.
Para el backport mínimo priorizo 1-8; VM/opcache se porta si aplica limpio.

## Feasibility del backport

- **7.3 → 7.0**: mismo motor que 7.4. Aplica con offsets. Riesgo:
  `zend_vm_execute.h` (generado) difiere → portar esos hunks a mano o
  regenerar desde `zend_vm_def.h`. APIs usadas (`zend_is_executing`,
  `zend_get_executed_filename_ex`, etc.) existen en 7.x.
- **5.6 → 5.4**: motor PRE-reescritura PHP 7. zend_hash/zend_alloc/zval son
  distintos → **re-derivación conceptual**, no `patch -p1`. Mapean: neutralizar
  callback session, reset de globals en shutdown, NULL tras efree, safe-error
  en overflow de hash, límite de body parts. `array_init_singleton`/VM
  probablemente se omiten. ~6 archivos.
