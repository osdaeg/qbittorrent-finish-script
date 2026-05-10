#!/bin/bash

# =============================================================================
# subs.sh - Búsqueda y descarga de subtítulos
# Uso: ./subs.sh "/ruta/al/video.mkv" [radarr|sonarr] [opensubtitles|subdl]
#   $1 = ruta completa del archivo de video
#   $2 = categoría opcional (radarr agrega el año al nombre en el pool)
#   $3 = proveedor opcional (sin parámetro: flujo normal con todos los proveedores)
# =============================================================================

VIDEO_PATH="$1"
CATEGORY="${2:-sonarr}"
PROVIDER="${3:-}"   # opensubtitles | subdl | (vacío = flujo normal)

# =============================================================================
# CONFIGURACIÓN
# =============================================================================

source /home/daniel/docker/downloads/qbittorrent/config/finish.env

SUBS_POOL="/home/daniel/docker/downloads/qbittorrent/config/subs"
LOG_FILE="subs.log"

# =============================================================================
# FUNCIONES
# =============================================================================

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG_FILE"
}

gotify_notify() {
    local title="$1"
    local message="$2"
    local priority="${3:-5}"

    curl -s -X POST "${GOTIFY_URL}/message" \
        -H "X-Gotify-Key: ${GOTIFY_TOKEN}" \
        -F "title=${title}" \
        -F "message=${message}" \
        -F "priority=${priority}" \
        -o /dev/null
}

# Busca subtítulos en OpenSubtitles y devuelve el primer file_id encontrado
# $1 = query, $2 = jwt, $3 = idioma, $4 = parámetros extra (opcional)
opensubs_search() {
    local query="$1"
    local jwt="$2"
    local lang="$3"
    local extra_params="${4:-}"

    local encoded_query
    encoded_query=$(python3 -c "import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1]))" "$query")

    local resp
    resp=$(curl -s -L \
        -H "Api-Key: ${OPENSUBS_API_KEY}" \
        -H "Authorization: Bearer ${jwt}" \
        -H "User-Agent: ${OPENSUBS_USERAGENT}" \
        -H "Accept: application/json" \
        "${OPENSUBS_URL}/subtitles?query=${encoded_query}&languages=${lang}&order_by=download_count&order_direction=desc${extra_params}")

    echo "$resp" | grep -o '"file_id":[0-9]*' | head -1 | grep -o '[0-9]*'
}

# Busca subtítulos en SubDL y devuelve el download_link del primer resultado
# $1 = query (nombre limpio sin SxxExx para series), $2 = tipo (movie|tv)
# $3 = temporada (opcional), $4 = episodio (opcional)
subdl_search() {
    local query="$1"
    local type="$2"
    local season="${3:-}"
    local episode="${4:-}"

    local encoded_query
    encoded_query=$(python3 -c "import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1]))" "$query")

    local url="${SUBDL_URL}/subtitles?api_key=${SUBDL_API_KEY}&film_name=${encoded_query}&type=${type}&languages=ES"
    [ -n "$season" ]  && url="${url}&season_number=${season}"
    [ -n "$episode" ] && url="${url}&episode_number=${episode}"

    local resp
    resp=$(curl -s -L "$url")

    echo "$resp" | grep -o '"url":"[^"]*\.zip"' | head -1 | cut -d'"' -f4
}

# Descarga un subtítulo de OpenSubtitles dado un file_id y jwt
# $1 = file_id, $2 = jwt, $3 = ruta destino del .srt
opensubs_download() {
    local file_id="$1"
    local jwt="$2"
    local srt_path="$3"

    local dl_resp
    dl_resp=$(curl -s -X POST "${OPENSUBS_URL}/download" \
        -H "Api-Key: ${OPENSUBS_API_KEY}" \
        -H "Authorization: Bearer ${jwt}" \
        -H "User-Agent: ${OPENSUBS_USERAGENT}" \
        -H "Content-Type: application/json" \
        -H "Accept: application/json" \
        -d "{\"file_id\": ${file_id}}")

    local dl_link
    dl_link=$(echo "$dl_resp" | grep -o '"link":"[^"]*"' | head -1 | cut -d'"' -f4)

    if [ -z "$dl_link" ]; then
        log "No se pudo obtener link de descarga OpenSubtitles. Respuesta: ${dl_resp}"
        return 1
    fi

    curl -s -L "$dl_link" -o "$srt_path"
}

# Descarga un subtítulo de SubDL dado un link relativo y lo extrae del zip
# $1 = link relativo (/subtitle/xxx.zip), $2 = ruta destino del .srt
subdl_download() {
    local subdl_link="$1"
    local srt_path="$2"
    local video_dir
    video_dir=$(dirname "$srt_path")

    local zip_path="${video_dir}/_subdl_tmp.zip"
    curl -s -L "${SUBDL_DL_URL}${subdl_link}" -o "$zip_path"

    if [ ! -s "$zip_path" ]; then
        log "Error: zip de SubDL vacío o no descargado."
        rm -f "$zip_path"
        return 1
    fi

    local tmp_dir
    tmp_dir=$(mktemp -d)
    unzip -q "$zip_path" -d "$tmp_dir" 2>/dev/null
    rm -f "$zip_path"

    local extracted_srt
    extracted_srt=$(find "$tmp_dir" -name "*.srt" | head -1)

    if [ -z "$extracted_srt" ]; then
        log "Error: no se encontró .srt dentro del zip de SubDL."
        rm -rf "$tmp_dir"
        return 1
    fi

    mv "$extracted_srt" "$srt_path"
    rm -rf "$tmp_dir"
}

# Busca y descarga subtítulo para un archivo de video
# $1 = ruta completa del archivo de video
fetch_subtitle() {
    local video_path="$1"
    local video_dir
    video_dir=$(dirname "$video_path")
    local video_base
    video_base=$(basename "$video_path")
    local video_name="${video_base%.*}"

    # Limpiar el nombre para la búsqueda
    local query year_str=""

    query=$(echo "$video_name" | sed \
        -e 's/\[^]]*\]//g' \
        -e 's/([^)]*)//g' \
        -e 's/[_.]/ /g' \
        -e 's/  */ /g' \
        -e 's/^ *//;s/ *$//')

    # Si tiene SxxExx: quedarse solo con serie + SxxExx
    if echo "$query" | grep -qiE 'S[0-9]{2}E[0-9]{2}'; then
        query=$(echo "$query" | sed 's/\([Ss][0-9]\{2\}[Ee][0-9]\{2\}\).*/\1/' \
            | sed 's/ - / /g;s/  */ /g;s/ *$//')
    else
        query=$(echo "$query" | sed \
            -e 's/ - / /g' \
            -e 's/\b\(1080p\|720p\|2160p\|4K\|BluRay\|BDRip\|WEB-DL\|WEBRip\|WEBDL\|HDTV\|DVDRip\|x264\|x265\|HEVC\|AAC\|AC3\|EAC3\|DTS\|HDR\|SDR\|REMUX\|PROPER\|REPACK\|FLUX\|NTb\|PSA\|YTS\)\b.*//Ig' \
            -e 's/  */ /g;s/ *$//')
    fi

    # Para radarr: extraer año y agregarlo entre paréntesis
    if [ "$CATEGORY" = "radarr" ]; then
        local year
        year=$(echo "$video_name" | grep -oE '\b(19|20)[0-9]{2}\b' | head -1)
        if [ -n "$year" ]; then
            query=$(echo "$query" | sed "s/ *${year} *$//;s/ *${year} */ /g" | sed 's/  */ /g;s/ *$//')
            year_str=" (${year})"
        fi
    fi

    log "Buscando subtítulo para: ${video_name} (query: ${query}${year_str}) [proveedor: ${PROVIDER:-auto}]"

    # Preparar parámetros para SubDL
    local subdl_season="" subdl_episode="" subdl_type="movie" subdl_query="$query"
    if echo "$query" | grep -qiE 'S[0-9]{2}E[0-9]{2}'; then
        subdl_type="tv"
        subdl_season=$(echo "$query" | grep -oiE 'S([0-9]{2})E[0-9]{2}' | grep -oE '[0-9]{2}' | head -1 | sed 's/^0*//')
        subdl_episode=$(echo "$query" | grep -oiE 'S[0-9]{2}E([0-9]{2})' | grep -oE '[0-9]{2}' | tail -1 | sed 's/^0*//')
        subdl_query=$(echo "$query" | sed 's/ *[Ss][0-9]\{2\}[Ee][0-9]\{2\}.*//' | sed 's/ *$//')
    fi

    # Login OpenSubtitles (solo si se necesita)
    local jwt=""
    if [ -z "$PROVIDER" ] || [ "$PROVIDER" = "opensubtitles" ]; then
        local login_resp
        login_resp=$(curl -s -X POST "${OPENSUBS_URL}/login" \
            -H "Api-Key: ${OPENSUBS_API_KEY}" \
            -H "User-Agent: ${OPENSUBS_USERAGENT}" \
            -H "Content-Type: application/json" \
            -H "Accept: application/json" \
            -d "{\"username\": \"${OPENSUBS_USER}\", \"password\": \"${OPENSUBS_PASS}\"}")

        jwt=$(echo "$login_resp" | grep -o '"token":"[^"]*"' | head -1 | cut -d'"' -f4)
        if [ -z "$jwt" ]; then
            log "OpenSubtitles: fallo de login."
        else
            log "OpenSubtitles: login OK"
        fi
    fi

    local file_id="" subdl_link="" found_lang="" provider_used=""
    local srt_path="${video_dir}/${video_name}.srt"

    # --- Búsqueda según proveedor ---
    case "${PROVIDER:-auto}" in

        opensubtitles)
            file_id=$(opensubs_search "$query" "$jwt" "es-la")
            [ -n "$file_id" ] && found_lang="español latino" && provider_used="opensubtitles"

            if [ -z "$file_id" ]; then
                file_id=$(opensubs_search "$query" "$jwt" "es")
                [ -n "$file_id" ] && found_lang="español" && provider_used="opensubtitles"
            fi

            if [ -z "$file_id" ]; then
                file_id=$(opensubs_search "$query" "$jwt" "en" "&ai_translated=include")
                [ -n "$file_id" ] && found_lang="inglés (ai_translated)" && provider_used="opensubtitles"
            fi
            ;;

        subdl)
            subdl_link=$(subdl_search "$subdl_query" "$subdl_type" "$subdl_season" "$subdl_episode")
            [ -n "$subdl_link" ] && found_lang="español (SubDL)" && provider_used="subdl"
            ;;

        auto)
            # Flujo completo: os es-la → os es → subdl es → os en ai_translated
            if [ -n "$jwt" ]; then
                file_id=$(opensubs_search "$query" "$jwt" "es-la")
                [ -n "$file_id" ] && found_lang="español latino" && provider_used="opensubtitles"
            fi

            if [ -z "$file_id" ] && [ -n "$jwt" ]; then
                file_id=$(opensubs_search "$query" "$jwt" "es")
                [ -n "$file_id" ] && found_lang="español" && provider_used="opensubtitles"
            fi

            if [ -z "$file_id" ]; then
                subdl_link=$(subdl_search "$subdl_query" "$subdl_type" "$subdl_season" "$subdl_episode")
                [ -n "$subdl_link" ] && found_lang="español (SubDL)" && provider_used="subdl"
            fi

            if [ -z "$file_id" ] && [ -z "$subdl_link" ] && [ -n "$jwt" ]; then
                file_id=$(opensubs_search "$query" "$jwt" "en" "&ai_translated=include")
                [ -n "$file_id" ] && found_lang="inglés (ai_translated)" && provider_used="opensubtitles"
            fi
            ;;
    esac

    if [ -z "$file_id" ] && [ -z "$subdl_link" ]; then
        log "No se encontró subtítulo para: ${video_name}"
        gotify_notify "🔤 Sin subtítulo" "📁 ${video_name}
No se encontró subtítulo." 3
        return 0
    fi

    # --- Descarga ---
    log "Subtítulo encontrado (${found_lang}) via ${provider_used}. Descargando..."

    if [ "$provider_used" = "opensubtitles" ]; then
        opensubs_download "$file_id" "$jwt" "$srt_path"
    elif [ "$provider_used" = "subdl" ]; then
        subdl_download "$subdl_link" "$srt_path"
    fi

    if [ -f "$srt_path" ] && [ -s "$srt_path" ]; then
        log "Subtítulo guardado: ${srt_path}"

        mkdir -p "$SUBS_POOL"
        local srt_clean="${SUBS_POOL}/${query}${year_str}.srt"
        cp "$srt_path" "$srt_clean"
        log "Subtítulo copiado a subs pool: ${srt_clean}"

        gotify_notify "🔤 Subtítulo descargado" "📁 ${video_name}
🌐 Idioma: ${found_lang}" 3
    else
        log "Error: el archivo de subtítulo quedó vacío o no se creó."
        rm -f "$srt_path"
    fi
}

# =============================================================================
# MAIN
# =============================================================================

if [ -z "$VIDEO_PATH" ]; then
    echo "Uso: $0 \"/ruta/al/video.mkv\" [radarr|sonarr] [opensubtitles|subdl]"
    exit 1
fi

if [ ! -f "$VIDEO_PATH" ]; then
    echo "El archivo no existe: ${VIDEO_PATH}"
    exit 1
fi

if [ -n "$PROVIDER" ] && [ "$PROVIDER" != "opensubtitles" ] && [ "$PROVIDER" != "subdl" ]; then
    echo "Proveedor inválido: ${PROVIDER}. Usar: opensubtitles | subdl"
    exit 1
fi

log "======================================================"
log "subs.sh - Búsqueda manual"
log "Video:     ${VIDEO_PATH}"
log "Categoría: ${CATEGORY}"
log "Proveedor: ${PROVIDER:-auto}"
log "======================================================"

fetch_subtitle "$VIDEO_PATH"

log "======================================================"
log "subs.sh - Fin"
log "======================================================"

exit 0
