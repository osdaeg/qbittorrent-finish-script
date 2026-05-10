# 🎬 Pipeline de post-descarga para qBittorrent

Scripts bash para automatizar el procesamiento de descargas en un entorno Docker con qBittorrent: escaneo antivirus, transferencia de archivos, generación de fichas y búsqueda de subtítulos en español.

## Archivos

| Archivo | Ubicación | Descripción |
|---|---|---|
| `finish.env` | `/config/finish.env` (contenedor) | Configuración compartida por los tres scripts |
| `finish.sh` | `/config/finish.sh` (contenedor) | Script principal, ejecutado por qBittorrent al finalizar cada descarga |
| `subs.sh` | Host | Búsqueda manual de subtítulos para un archivo de video |
| `subsupd.sh` | Host | Cronjob que copia subtítulos pendientes a su destino final |

---

## Flujo general

```
qBittorrent finaliza descarga
        │
        ▼
finish.sh
  ├── 1. Notificación (Gotify)
  ├── 2. Escaneo antivirus (ClamAV)
  ├── 3. Transferencia de archivos (Transferr)
  ├── 4. Generación de fichas HTML (Butler-API)
  └── 5. Búsqueda de subtítulos (OpenSubtitles + SubDL)
              │
              ▼
         /config/subs/
              │
              ▼  (cronjob cada 1h)
        subsupd.sh
              │
              ▼
    /media/Series/ o /media/Películas/
```

---

## Servicios requeridos

Todos deben estar corriendo como contenedores Docker.

| Servicio | Puerto | Función |
|---|---|---|
| [qBittorrent](https://codeberg.org/qbittorrent/qBittorrent) + [Gluetun](https://codeberg.org/qdm12/gluetun) | 8081 | Cliente de torrents con VPN |
| [Gotify](https://gotify.net/) | 8088 | Notificaciones push |
| [clamav-rest-api](https://codeberg.org/benzino77/clamav-rest-api) | 3311 | Escaneo antivirus |
| [Transferr](https://codeberg.org/osdaeg/transferr) | 7900 | Copia de archivos entre volúmenes Docker |
| [Butler-API](https://codeberg.org/osdaeg/butler) | 7999 | Generación de fichas HTML con Gemini |
| [Paste.sh](https://codeberg.org/osdaeg/paste.sh) | 8090 | Almacenamiento de logs de error |
| [Sonarr](https://sonarr.tv/) | 8989 | Gestión de series |
| [Radarr](https://radarr.video/) | 7878 | Gestión de películas |

Gluetun es opcional

### Cuentas externas necesarias

- **[OpenSubtitles.com](https://www.opensubtitles.com)** — cuenta gratuita + API key de consumidor
- **[SubDL](https://subdl.com)** — cuenta gratuita + API key

---

## Instalación

### 1. Clonar el repositorio

```bash
git clone https://codeberg.org/osdaeg/qbittorrent-finish-script.git
cd qbittorrent-finish-script
```

### 2. Configurar `finish.env`

Copiá el archivo al directorio de configuración de qBittorrent y completá los valores:

```bash
cp finish.env /ruta/a/qbittorrent/config/finish.env
```

Variables obligatorias:

```bash
HOST="192.168.1.10"              # IP del host

GOTIFY_TOKEN="..."               # Token de la app en Gotify

OPENSUBS_API_KEY="..."           # API key de OpenSubtitles
OPENSUBS_USER="..."              # Usuario de OpenSubtitles
OPENSUBS_PASS="..."              # Contraseña de OpenSubtitles

SUBDL_API_KEY="..."              # API key de SubDL

SONARR_KEY="..."                 # API key de Sonarr (Settings → General)
RADARR_KEY="..."                 # API key de Radarr (Settings → General)

SUBS_DIR="/ruta/config/subs"     # Carpeta pool de subtítulos (ruta en el host)

SONARR_PATH_INTERNAL="/tv"       # Ruta interna de Sonarr dentro de Docker
SONARR_PATH_HOST="/media/Series" # Ruta equivalente en el host

RADARR_PATH_INTERNAL="/movies"
RADARR_PATH_HOST="/media/Películas"
```

> `finish.env` no necesita permisos de ejecución (solo lectura, `644`).

### 3. Instalar `finish.sh`

```bash
cp finish.sh /ruta/a/qbittorrent/config/finish.sh
chmod +x /ruta/a/qbittorrent/config/finish.sh
```

En qBittorrent ir a **Opciones → Descargas → Ejecutar programa externo al finalizar**:

```
/config/finish.sh %K "%N" %Z %D %L %R %F
```

### 4. Instalar `subs.sh` y `subsupd.sh`

```bash
cp subs.sh ~/subs.sh
cp subsupd.sh ~/subsupd.sh
chmod +x ~/subs.sh ~/subsupd.sh
```

Editá la ruta del `source` en ambos scripts para que apunte a tu `finish.env`:

```bash
source /ruta/a/qbittorrent/config/finish.env
```

### 5. Configurar el cronjob de `subsupd.sh`

```bash
crontab -e
```

Agregar (ejecuta cada hora):

```
0 * * * * /home/usuario/subsupd.sh
```

---

## Categorías

El comportamiento se adapta según la categoría del torrent en qBittorrent:

| Categoría | Transferencia | Ficha Butler | Subtítulos |
|---|---|---|---|
| `radarr` | — | ✅ archivo más grande | ✅ |
| `sonarr` | — | ✅ por episodio | ✅ |
| `libros` | calibre + booklore | ✅ por libro | — |
| `comics` | comics | ✅ por archivo | — |
| `musica` | slskd | ✅ por pista | — |

Los nombres de categoría y destinos de transferencia son configurables en `finish.env` y deben coincidir con las categorias en `radarr/sonarr` y en `qbittorrent`:

```bash
MOVIES_CATEGORY="radarr"
SERIES_CATEGORY="sonarr"
BOOKS_CATEGORY="libros"
COMIC_CATEGORY="comics"
MUSIC_CATEGORY="musica"

BOOK_TRANSFER=("calibre" "booklore")
MUSIC_TRANSFER=("slskd")
COMIC_TRANSFER=("comics")
MOVIE_TRANSFER=()    # array vacío = no transfiere
SERIES_TRANSFER=()
```

---

## Toggles

Cada etapa del pipeline se puede activar o desactivar individualmente:

```bash
PASTE_ERRORS="yes"          # Subir log a pastebin ante errores
SEND_NOTIFICATION="yes"     # Enviar notificaciones por Gotify
SCAN_FILES="yes"            # Escanear archivos con ClamAV
GENERATE_BUTLER_CARD="yes"  # Generar fichas HTML con Butler
TRANSFER_FILES="yes"        # Transferir archivos con Transferr
SEARCH_SUBTITLES="yes"      # Buscar subtítulos automáticamente
```

---

## Búsqueda de subtítulos

### Flujo automático (`finish.sh`)

Para cada video de categoría `radarr` o `sonarr`, se intenta en orden:

1. **OpenSubtitles** — español latino (`es-la`)
2. **OpenSubtitles** — español (`es`)
3. **SubDL** — español (`ES`)
4. **OpenSubtitles** — inglés con traducción AI (`en`)

El `.srt` descargado se guarda en dos lugares:
- Junto al video original en la carpeta de descargas
- En `SUBS_DIR` con nombre limpio, para que `subsupd.sh` lo procese

### `subsupd.sh`

Recorre `SUBS_DIR` buscando archivos `.srt`. Para cada uno:

1. Si el nombre contiene `SxxExx` → consulta Sonarr para encontrar el path del episodio
2. Si no → consulta Radarr para encontrar el path de la película
3. Traduce la ruta interna de Docker a la ruta real en el host
4. Copia el `.srt` junto al `.mkv` con el mismo nombre base
5. Borra el `.srt` del pool si la copia fue exitosa

Si el video aún no fue procesado por Sonarr/Radarr, el `.srt` queda en el pool para el próximo ciclo del cronjob.

### Uso manual (`subs.sh`)

```bash
# Flujo automático (todos los proveedores en orden)
./subs.sh "/ruta/al/video.mkv"

# Especificar categoría (para películas agrega el año a la query)
./subs.sh "/ruta/al/video.mkv" radarr

# Forzar un proveedor específico
./subs.sh "/ruta/al/video.mkv" sonarr opensubtitles
./subs.sh "/ruta/al/video.mkv" radarr subdl
```

---

## Logs

| Script | Log |
|---|---|
| `finish.sh` | `/config/finished.log` (dentro del contenedor) |
| `subs.sh` | `subs.log` en el directorio de ejecución |
| `subsupd.sh` | `SUBS_DIR/../subsupd.log` en el host |

---

## Notas técnicas

- Los scripts no requieren `jq`. El parseo de JSON se hace con `grep` y `python3`.
- Las rutas de archivos con espacios, comas, corchetes o paréntesis (frecuentes en nombres de libros y series) se manejan correctamente en todas las llamadas a `curl`.
- qBittorrent pasa `%F` cuando la descarga es un archivo individual y `%R` cuando es una carpeta. El script detecta automáticamente cuál usar.
- La búsqueda de subtítulos limpia el nombre del archivo antes de la query: elimina tags de release (`1080p`, `BluRay`, `x265`, etc.), corchetes, paréntesis y el título del episodio en series.
