# Backport CVE-2026-109618 / CVE-2026-109619

![CVE-2026-109618](https://img.shields.io/badge/CVE-2026--109618-b31b1b?style=flat-square)
![CVE-2026-109619](https://img.shields.io/badge/CVE-2026--109619-b31b1b?style=flat-square)
![CVSS](https://img.shields.io/badge/CVSS-9.2_critical-b31b1b?style=flat-square)
![PHP](https://img.shields.io/badge/PHP-5.4--8.1-777bb4?style=flat-square)
![estado](https://img.shields.io/badge/estado-verificado-2e7d32?style=flat-square)

Backport del fix oficial de las dos RCE no autenticadas de PHP (publicado el
2026-10-21) hacia ramas EOL, desde 8.1 hasta 5.4.0, que es donde nace el codigo
vulnerable. De 8.2 en adelante existe release oficial corregido (8.2.35, 8.3.36,
8.4.27, 8.5.12): en esas versiones se actualiza, no se backportea.

## Las vulnerabilidades

| CVE | Aviso | Clase | Causa raiz |
|-----|-------|-------|------------|
| CVE-2026-109618 | GHSA-w8hw-w9fx-j79w | UAF / memory disclosure + RCE | el estado de `session.upload_progress` y del unserializer queda colgando si un fatal (OOM al exceder `memory_limit`) interrumpe el parseo multipart antes de `zend_activate_modules()`; el heap del request se libera con punteros aun apuntando a el |
| CVE-2026-109619 | GHSA-6wmf-4rv5-p3rp | stale bucket / type confusion + RCE | `_zend_hash_str_add_or_update_i()` incrementa los contadores antes de alocar la key; si esa alocacion falla, `zend_array_destroy()` recorre un bucket contado pero sin inicializar |

Disparador comun: un fatal error (tipicamente OOM al exceder `memory_limit`)
durante el arranque del request o el parseo multipart, que salta la limpieza.
La configuracion por defecto es vulnerable. El codigo vulnerable existe desde
PHP 5.4.0. Severidad CVSS 9.2 (critica). Autores del fix oficial: Arnaud Le
Blanc e Ilija Tovilo.

## El workaround aplicado

El fix no parchea cada operacion de hash una por una. Ataca la raiz comun: un
`bailout` (longjmp) a mitad de una asignacion de memoria. Al fallar un alloc
(overflow de enteros u OOM), PHP llamaba `zend_error_noreturn()` seguido de
`zend_bailout()`; ese salto deja contadores incrementados y punteros a medio
inicializar, y el teardown posterior recorre esa estructura corrupta. De ahi
la reutilizacion por el siguiente request en el mismo worker.

Cambios centrales del backport:

1. `zend_mm_safe_error_ex` (nuevo, en `Zend/zend_alloc.c`): reemplaza el
   `zend_error_noreturn` + bailout de las rutas de fallo de asignacion por un
   fatal que imprime y hace `_exit(1)` directo. Sin longjmp no hay estado
   corrupto reutilizable. `zend_mm_panic` y `zend_out_of_memory` pasan tambien
   a `_exit(1)`.
2. `Zend/zend_hash.c`: las ramas de overflow de enteros pasan por
   `zend_mm_safe_error_ex`.
3. `main/rfc1867.c`: limite `max_multipart_body_parts` y retencion solo de los
   headers Content-Disposition y Content-Type. Acota el disparador OOM.
4. `ext/session/session.c`: neutraliza el cuerpo de
   `php_session_rfc1867_callback` (cierra la via upload_progress).
5. `main/main.c`, `main/SAPI.c`, `Zend/zend_execute_API.c`: reset de
   `http_globals`, de `modules_activated`, NULL tras `efree`, y reset de los
   handlers y el object store en `shutdown_executor`, para que el siguiente
   request no reuse punteros stale.

El mecanismo primario es el `_exit(1)`: mata el worker en vez de reutilizar
estado corrupto. Detalle completo en `notes/fix-analysis.md`.

## Cobertura

| Version | Linaje del parche | Verificacion |
|---------|-------------------|--------------|
| 8.1.33 / 8.0.30 / 7.4.33 | parche oficial EOL, verbatim | PATCHED |
| 7.3.33 / 7.2.34 / 7.1.33 / 7.0.33 | port completo propio | PATCHED |
| 5.6.40 / 5.5.38 / 5.4.45 | re-derivacion esencial (motor PHP5) | PATCHED |

Para 7.4, 8.0 y 8.1 hay parche oficial source-only (ramas
`PHP-<x>-CVE-2026-109618-109619`), guardado verbatim. Debajo de 7.4 es backport
propio: los 7.x son port completo (7.1 sigue el PR comunitario #24500, unico
backport publico; 7.0/7.2/7.3 a paridad), y los 5.x son re-derivacion sobre un
motor distinto. Una auditoria independiente sobre los 7.x corrigio tres defectos
(compilacion `|| true`, ubicacion de los resets de `shutdown_executor`, guarda
`zend_mm_alloc_huge`); detalle en `notes/backports.md`.

Los commits de 8.2.35 / 8.3.36 / 8.4.27 / 8.5.12 se archivan en `patches/` solo
como referencia; no se compilan.

## Verificacion

Dos tests, con alcances distintos:

- `poc/regression.sh <bin-cli>`: prueba el mecanismo del fix (bailout frente a
  `_exit`) con un OOM sintetico en CLI. Baseline VULNERABLE, parcheado PATCHED.
- `poc/regression-multipart.sh <bin-cgi>`: prueba end-to-end del trigger real.
  Dispara el OOM dentro del parseo multipart en request-startup, con
  `session.upload_progress` habilitado, contra el SAPI web (php-cgi). Baseline:
  el bailout se traga el fatal y aborta el request con estado a medio construir
  (exit 255, sin salida). Parcheado: `zend_mm_safe_error_ex` emite el fatal y
  hace `_exit(1)` (exit 1).

Alcance honesto del PoC multipart: verifica el trigger real y el mecanismo del
fix. No demuestra el UAF ni que el OOM caiga dentro del codigo de
`upload_progress` (cae en el crecimiento del hash de `$_POST`, con la sesion ya
enganchada). Corrido en 7.4.33, 7.2.34 y 5.6.40, un representante de cada linaje.

## Instalacion en Ubuntu

Los parches son source-only. Se aplican sobre el tarball oficial de php.net de
la version exacta y se recompila. Ejemplo para 7.2.34:

```sh
sudo apt-get update
sudo apt-get install -y build-essential autoconf bison re2c pkg-config \
  libxml2-dev libsqlite3-dev curl

curl -fsSLO https://www.php.net/distributions/php-7.2.34.tar.gz
tar xzf php-7.2.34.tar.gz
cd php-7.2.34
patch -p1 --fuzz=3 < /ruta/al/repo/patches/php-7.2.34.patch

./configure --prefix=/opt/php-7.2.34-patched   # + tus flags de produccion
make -j"$(nproc)"
sudo make install
```

Notas:

- Usa el mismo `./configure` que tu build de produccion (SAPI fpm o apache,
  extensiones). El `--disable-all` del harness de este repo es solo para test.
- Los parches propios 7.0 a 7.3 tocan `Zend/zend_vm_def.h` sin incluir el
  `Zend/zend_vm_execute.h` regenerado. Si el build falla por eso, regeneralo
  con el PHP recien compilado y recompila:
  `(cd Zend && ../sapi/cli/php zend_vm_gen.php) && make -j"$(nproc)"`.
  Los parches oficiales (7.4, 8.0, 8.1) ya traen el header regenerado.
- Para 8.2 o superior no uses estos parches: actualiza al release oficial.

## Estructura

- `patches/`: un parche por version, mas los oficiales archivados.
- `build/build.sh`: compila en Docker con el toolchain de epoca (bookworm para
  7.x y 8.x, jessie para 5.x) y emite los binarios CLI y CGI.
- `poc/`: los dos tests de regresion.
- `notes/`: mapeo de hunks, analisis del fix y estado por version.

## Referencias

- PR comunitario #24500 (backport a PHP-7.1): https://github.com/php/php-src/pull/24500
- Avisos: GHSA-w8hw-w9fx-j79w, GHSA-6wmf-4rv5-p3rp
