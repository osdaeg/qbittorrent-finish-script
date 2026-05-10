#!/bin/bash

# =============================================================================
# subsupd.sh - Copia subtítulos de /config/subs al destino final
# Uso: ejecutar como cronjob en el host cada N minutos
# =============================================================================
# Busca .srt en SUBS_DIR, consulta Sonarr/Radarr para encontrar el path
# del episodio/película, copia el .srt al lado del .mkv y borra el original.
# =============================================================================

# =============================================================================
# CONFIGURACIÓN
# =============================================================================

source /home/daniel/docker/downloads/qbittorrent/config/finish.env

LOG_FILE="/home/daniel/docker/downloads/qbittorrent/config/subsupd.log"

# =============================================================================
# FUNCIONES
# =============================================================================

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG_FILE"
}

# Igual que log pero escribe a stderr — usar dentro de funciones que retornan valores por stdout
logf() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG_FILE" >&2
}

# Convierte una ruta interna de Sonarr/Radarr a ruta del host
translate_path() {
    local internal_path="$1"
    local app="$2"  # sonarr o radarr

    if [ "$app" = "sonarr" ]; then
        echo "${internal_path/${SONARR_PATH_INTERNAL}/${SONARR_PATH_HOST}}"
    else
        echo "${internal_path/${RADARR_PATH_INTERNAL}/${RADARR_PATH_HOST}}"
    fi
}

# Busca un episodio en Sonarr por nombre de serie + temporada + episodio
# Devuelve la ruta del archivo en el host, o vacío si no encontró
find_episode_path() {
    local query="$1"  # ej: "Resident Alien S04E01"

    # Extraer serie, temporada y episodio
    local series_name season_num episode_num
    if echo "$query" | grep -qiE 'S[0-9]{2}E[0-9]{2}'; then
        local sXeX
        sXeX=$(echo "$query" | grep -oiE 'S[0-9]{2}E[0-9]{2}' | head -1 | tr '[:lower:]' '[:upper:]')
        season_num=$(echo "$sXeX" | grep -oE '[0-9]{2}' | head -1 | sed 's/^0*//')
        episode_num=$(echo "$sXeX" | grep -oE '[0-9]{2}' | tail -1 | sed 's/^0*//')
        series_name=$(echo "$query" | sed "s/ *${sXeX}.*//i" | sed 's/ *$//')
    else
        logf "No se pudo extraer SxxExx de: ${query}"
        return 1
    fi

    logf "Buscando en Sonarr: serie='${series_name}' S${season_num}E${episode_num}"

    # Buscar la serie por nombre
    local series_resp series_id
    series_resp=$(curl -s \
        -H "X-Api-Key: ${SONARR_KEY}" \
        -H "Accept: application/json" \
        "${SONARR_URL}/series?includeSeasonImages=false")

    # Buscar el id de la serie cuyo título coincida (case-insensitive)
    local clean_name
    clean_name=$(echo "$series_name" | tr '[:upper:]' '[:lower:]')

    series_id=$(echo "$series_resp" | grep -oi '"title":"[^"]*'"$(echo "$clean_name" | sed 's/ /[^"]*/')"'[^"]*"[^}]*"id":[0-9]*' \
        | grep -o '"id":[0-9]*' | grep -o '[0-9]*' | head -1)

    # Si no encontró con regex flexible, intentar búsqueda exacta
    if [ -z "$series_id" ]; then
        series_id=$(echo "$series_resp" \
            | python3 -c "
import sys, json
data = json.load(sys.stdin)
name = '${clean_name}'.lower()
for s in data:
    if name in s.get('title','').lower() or name in s.get('sortTitle','').lower() or name in s.get('cleanTitle','').lower():
        print(s['id'])
        break
" 2>/dev/null)
    fi

    if [ -z "$series_id" ]; then
        logf "Serie no encontrada en Sonarr: ${series_name}"
        return 1
    fi

    logf "Serie encontrada en Sonarr: id=${series_id}"

    # Buscar los episodios de esa serie
    local files_resp file_path
    files_resp=$(curl -s \
        -H "X-Api-Key: ${SONARR_KEY}" \
        -H "Accept: application/json" \
        "${SONARR_URL}/episodefile?seriesId=${series_id}")

    # Extraer el path del episodio que coincida con temporada y episodio
    file_path=$(echo "$files_resp" | python3 -c "
import sys, json, re
data = json.load(sys.stdin)
season = ${season_num}
episode = ${episode_num}
for f in data:
    if f.get('seasonNumber') == season:
        rp = f.get('relativePath', '')
        m = re.search(r'[Ss]0*${season_num}[Ee]0*${episode_num}', rp)
        if m:
            print(f['path'])
            break
" 2>/dev/null)

    if [ -z "$file_path" ]; then
        logf "Episodio S$(printf '%02d' $season_num)E$(printf '%02d' $episode_num) no encontrado en Sonarr para serie id=${series_id}"
        return 1
    fi

    translate_path "$file_path" "sonarr"
}

# Busca una película en Radarr por título
# Devuelve la ruta del archivo en el host, o vacío si no encontró
find_movie_path() {
    local query="$1"  # ej: "The Batman 2022"

    logf "Buscando en Radarr: '${query}'"

    local movies_resp
    movies_resp=$(curl -s \
        -H "X-Api-Key: ${RADARR_KEY}" \
        -H "Accept: application/json" \
        "${RADARR_URL}/movie")

    local clean_query
    clean_query=$(echo "$query" | tr '[:upper:]' '[:lower:]')

    local file_path
    file_path=$(echo "$movies_resp" | python3 -c "
import sys, json, re

def normalize(s):
    # Quitar caracteres especiales y espacios extra para comparar
    return re.sub(r'[^a-z0-9 ]', '', s.lower()).strip()

data = json.load(sys.stdin)
query = normalize('${clean_query}')
# También intentar sin el año entre paréntesis
query_no_year = re.sub(r'\s*\([0-9]{4}\)\s*$', '', query).strip()

for m in data:
    title = normalize(m.get('title',''))
    if query in title or title in query or query_no_year in title or title in query_no_year:
        mf = m.get('movieFile')
        if mf and mf.get('path'):
            print(mf['path'])
            break
" 2>/dev/null)

    if [ -z "$file_path" ]; then
        logf "Película no encontrada en Radarr: ${query}"
        return 1
    fi

    translate_path "$file_path" "radarr"
}

# =============================================================================
# MAIN
# =============================================================================

log "======================================================"
log "subsupd.sh - Inicio"
log "======================================================"

if [ ! -d "$SUBS_DIR" ]; then
    log "Carpeta de subs no existe: ${SUBS_DIR}"
    exit 1
fi

# Contar .srt pendientes
srt_count=$(find "$SUBS_DIR" -maxdepth 1 -name "*.srt" | wc -l)
log "Subtítulos pendientes: ${srt_count}"

if [ "$srt_count" -eq 0 ]; then
    log "Nada que procesar."
    exit 0
fi

processed=0
failed=0

while IFS= read -r srt_file; do
    srt_name=$(basename "$srt_file" .srt)
    log "------------------------------------------------------"
    log "Procesando: ${srt_name}.srt"

    media_path=""

    # Determinar si es serie (SxxExx) o película
    if echo "$srt_name" | grep -qiE 'S[0-9]{2}E[0-9]{2}'; then
        media_path=$(find_episode_path "$srt_name")
    else
        media_path=$(find_movie_path "$srt_name")
    fi

    if [ -z "$media_path" ]; then
        log "No se encontró el archivo de media para: ${srt_name}"
        (( failed++ ))
        continue
    fi

    log "Media encontrada: ${media_path}"

    # Verificar que el archivo de video exista en el host
    if [ ! -f "$media_path" ]; then
        log "El archivo de video no existe aún en el host: ${media_path}"
        (( failed++ ))
        continue
    fi

    # Construir ruta destino del .srt con el mismo nombre base que el video
    local_dir=$(dirname "$media_path")
    video_base=$(basename "$media_path")
    video_name="${video_base%.*}"
    dest_srt="${local_dir}/${video_name}.srt"

    # Copiar el subtítulo
    cp "$srt_file" "$dest_srt"

    if [ -f "$dest_srt" ]; then
        log "✅ Subtítulo copiado a: ${dest_srt}"
        rm -f "$srt_file"
        log "Eliminado de subs pool: ${srt_file}"
        (( processed++ ))
    else
        log "❌ Error al copiar subtítulo a: ${dest_srt}"
        (( failed++ ))
    fi

done < <(find "$SUBS_DIR" -maxdepth 1 -name "*.srt")

log "======================================================"
log "subsupd.sh - Fin. Procesados: ${processed} | Fallidos: ${failed}"
log "======================================================"

exit 0
