# Backport CVE-2026-109618 / CVE-2026-109619

![CVE-2026-109618](https://img.shields.io/badge/CVE-2026--109618-b31b1b?style=flat-square)
![CVE-2026-109619](https://img.shields.io/badge/CVE-2026--109619-b31b1b?style=flat-square)
![CVSS](https://img.shields.io/badge/CVSS-9.2_cr%C3%ADtica-b31b1b?style=flat-square)
![PHP](https://img.shields.io/badge/PHP-5.4--8.1-777bb4?style=flat-square)
![estado](https://img.shields.io/badge/estado-verificado-2e7d32?style=flat-square)

Backport del fix oficial de las dos RCE no autenticadas de PHP (publicado el 21
de octubre de 2026) hacia ramas en fin de vida, desde 8.1 hasta 5.4.0, que es
donde nace el código vulnerable. De 8.2 en adelante existe release oficial
corregido (8.2.35, 8.3.36, 8.4.27 y 8.5.12): en esas versiones se actualiza, no
se backportea.

## Las vulnerabilidades

| CVE | Aviso | Clase | Causa raíz |
|-----|-------|-------|------------|
| CVE-2026-109618 | GHSA-w8hw-w9fx-j79w | use-after-free, fuga de memoria y RCE | el estado de `session.upload_progress` y del unserializer queda colgando si un error fatal (por ejemplo un OOM al exceder `memory_limit`) interrumpe el parseo multipart antes de `zend_activate_modules()`; el heap del request se libera con punteros que aún apuntan a él |
| CVE-2026-109619 | GHSA-6wmf-4rv5-p3rp | bucket obsoleto, confusión de tipos y RCE | `_zend_hash_str_add_or_update_i()` incrementa los contadores antes de asignar la key; si esa asignación falla, `zend_array_destroy()` recorre un bucket contado pero sin inicializar |

El disparador común es un error fatal, típicamente un OOM al exceder
`memory_limit`, durante el arranque del request o el parseo multipart, que se
salta la limpieza. La configuración por defecto es vulnerable. El código
vulnerable existe desde PHP 5.4.0. La severidad es CVSS 9.2, crítica. El fix
oficial es de Arnaud Le Blanc e Ilija Tovilo.

## El fix aplicado

El parche no corrige cada operación de hash por separado, sino que ataca la
causa común: un bailout (un salto con longjmp) a mitad de una asignación de
memoria. Al fallar una asignación, por desbordamiento de enteros o por agotar el
`memory_limit`, PHP llamaba a `zend_error_noreturn()` y luego a `zend_bailout()`.
Ese salto deja contadores incrementados y punteros a medio inicializar, y la
limpieza posterior recorre esa estructura corrupta. De ahí la reutilización por
el siguiente request en el mismo worker.

Cambios centrales del backport:

1. `zend_mm_safe_error_ex` (nuevo, en `Zend/zend_alloc.c`): reemplaza la pareja
   `zend_error_noreturn` más bailout, en las rutas de fallo de asignación, por un
   error fatal que imprime el mensaje y llama a `_exit(1)` directo. Sin longjmp no
   queda estado corrupto reutilizable. `zend_mm_panic` y `zend_out_of_memory`
   pasan también a `_exit(1)`.
2. `Zend/zend_hash.c`: las ramas de desbordamiento de enteros pasan por
   `zend_mm_safe_error_ex`.
3. `main/rfc1867.c`: límite `max_multipart_body_parts` y retención solo de las
   cabeceras Content-Disposition y Content-Type. Acota el disparador del OOM.
4. `ext/session/session.c`: neutraliza el cuerpo de
   `php_session_rfc1867_callback`, lo que cierra la vía de upload_progress.
5. `main/main.c`, `main/SAPI.c` y `Zend/zend_execute_API.c`: reset de
   `http_globals` y `modules_activated`, NULL tras `efree`, y reset de los
   handlers y el object store en `shutdown_executor`, para que el siguiente
   request no reutilice punteros obsoletos.

El mecanismo primario es el `_exit(1)`: mata el worker en lugar de reutilizar
estado corrupto.

## Cobertura

| Versión | Linaje del parche | Verificación |
|---------|-------------------|--------------|
| 8.1.33 / 8.0.30 / 7.4.33 | parche oficial EOL, verbatim | PATCHED |
| 7.3.33 / 7.2.34 / 7.1.33 / 7.0.33 | port completo propio | PATCHED |
| 5.6.40 / 5.5.38 / 5.4.45 | rederivación esencial (motor PHP5) | PATCHED |

Para 7.4, 8.0 y 8.1 hay parche oficial source-only (ramas
`PHP-<x>-CVE-2026-109618-109619`), guardado verbatim. Debajo de 7.4 es backport
propio: los 7.x son port completo (7.1 sigue el PR comunitario #24500, el único
backport público; 7.0, 7.2 y 7.3 quedan a paridad con él), y los 5.x son
rederivación sobre un motor distinto. Una auditoría independiente sobre los 7.x
corrigió tres defectos: la compilación con `|| true`, la ubicación de los resets
de `shutdown_executor` y la guarda de `zend_mm_alloc_huge`.

Los commits de 8.2.35, 8.3.36, 8.4.27 y 8.5.12 se archivan en `patches/` solo
como referencia; no se compilan.

## Verificación

Hay dos tests, con alcances distintos:

- `poc/regression.sh <binario-cli>`: prueba el mecanismo del fix (bailout frente
  a `_exit`) con un OOM sintético en CLI. El baseline resulta VULNERABLE y el
  parcheado PATCHED.
- `poc/regression-multipart.sh <binario-cgi>`: prueba end-to-end del trigger
  real. Dispara el OOM dentro del parseo multipart en request-startup, con
  `session.upload_progress` habilitado, contra el SAPI web php-cgi. En el
  baseline el bailout se traga el error y aborta el request con el estado a medio
  construir (exit 255, sin salida). En el parcheado, `zend_mm_safe_error_ex`
  emite el error y hace `_exit(1)` (exit 1).

Alcance honesto del PoC multipart: verifica el trigger real y el mecanismo del
fix. No demuestra el use-after-free, ni que el OOM caiga dentro del código de
upload_progress (cae en el crecimiento del hash de `$_POST`, con la sesión ya
enganchada). Se corrió en 7.4.33, 7.2.34 y 5.6.40, un representante de cada
linaje de parche.

## Instalación

Estos son parches de código fuente. No parchean un binario en caliente: para
proteger una máquina hay que recompilar PHP con el parche y reemplazar el binario
o el SAPI que corre.

### Opción A: script automático (recomendada)

Detecta la versión de PHP del sistema, baja el tarball oficial y el parche que
corresponde, y recompila con los mismos flags del build actual. Es seguro por
defecto: compila a un directorio de staging y no toca el PHP de producción; al
final imprime los comandos para instalar. Con `--install` hace el `make install`
y recuerda reiniciar el SAPI.

Estos parches apuntan a PHP ya sin soporte, donde lo habitual es compilar desde
fuente, que es justo lo que hace el script. Para detectar los flags lee el
`Configure Command` de `php -i`. Si tu PHP viene de un paquete de la distro
(apt), ese campo suele venir vacío: instala el paquete `-dev` (por ejemplo
`php7.4-dev`) para exponer `php-config`, con el que el script recupera los flags.
Ten en cuenta que reconstruir un PHP empaquetado desde el tarball oficial
reemplaza el binario pero no sustituye limpio los SAPI que la distro empaqueta
aparte (fpm, módulo de apache); en ese caso conviene reconstruir el paquete
fuente de la distro con el parche, o migrar a un build propio desde fuente.

```sh
# compila y verifica, sin tocar produccion
curl -fsSL https://raw.githubusercontent.com/valentin-marquez/php/main/install.sh | sh

# compila e instala sobre el PHP actual
curl -fsSL https://raw.githubusercontent.com/valentin-marquez/php/main/install.sh | sh -s -- --install
sudo systemctl restart php-fpm   # o apache2, segun tu setup
```

### Opción B: manual

El mismo proceso, paso a paso, por si preferís controlarlo. Ejemplo para PHP 5.4:

```sh
# 1. version exacta y flags del build actual (copialos para el paso 4)
php -v
php -i | grep 'Configure Command'

# 2. dependencias de compilacion (ajusta segun tus extensiones)
sudo apt-get update
sudo apt-get install -y build-essential autoconf bison re2c pkg-config \
  libxml2-dev libsqlite3-dev curl

# 3. tarball oficial de ESA version mas el parche, y aplicar
curl -fsSLO https://www.php.net/distributions/php-5.4.45.tar.gz
tar xzf php-5.4.45.tar.gz && cd php-5.4.45
curl -fsSLO https://raw.githubusercontent.com/valentin-marquez/php/main/patches/php-5.4.45.patch
patch -p1 < php-5.4.45.patch

# 4. configurar con LOS MISMOS flags del paso 1, compilar e instalar
./configure <tus-flags-de-produccion>
make -j"$(nproc)"
sudo make install

# 5. reiniciar el SAPI y verificar
sudo systemctl restart php7.4-fpm   # o apache2, segun tu setup
php -v
```

### Opción C: probar en Docker, sin tocar la máquina

Compila un PHP parcheado aislado y corre el test de regresión.

```sh
git clone https://github.com/valentin-marquez/php
cd php
./build/build.sh 5.4.45 debian:jessie patches/php-5.4.45.patch
./poc/regression.sh build/out/php-5.4.45-patched   # imprime PATCHED
```

Notas:

- El `./configure` debe coincidir con el build de producción (SAPI fpm o apache,
  extensiones). El `--disable-all` del harness de este repo es solo para test.
- PHP 5.4 es de 2012. Compilarlo en un Ubuntu moderno suele fallar por toolchain
  y OpenSSL; lo natural es compilarlo en la propia máquina de época, o en la
  imagen `debian:jessie` que usa `build/build.sh`.
- Los parches propios de 7.0 a 7.3 tocan `Zend/zend_vm_def.h` sin el
  `Zend/zend_vm_execute.h` regenerado. Si el build falla por eso, se regenera con
  `(cd Zend && ../sapi/cli/php zend_vm_gen.php) && make`. Los parches oficiales
  (7.4, 8.0, 8.1) ya traen el header regenerado. El script de la Opción A hace
  esto solo.
- Para 8.2 o superior no uses estos parches: actualiza al release oficial.

## Estructura

- `install.sh`: instalador automático (detecta versión, baja, parchea y compila).
- `patches/`: un parche por versión, más los oficiales archivados.
- `build/build.sh`: compila en Docker con el toolchain de época (bookworm para
  7.x y 8.x, jessie para 5.x) y emite los binarios CLI y CGI.
- `poc/`: los dos tests de regresión.

## Referencias

- PR comunitario #24500 (backport a PHP-7.1): https://github.com/php/php-src/pull/24500
- Avisos: GHSA-w8hw-w9fx-j79w, GHSA-6wmf-4rv5-p3rp
