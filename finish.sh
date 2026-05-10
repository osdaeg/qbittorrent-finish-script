#!/bin/bash

# =============================================================================
# finish.sh - Script post-descarga de qBittorrent
# Ubicación: $BASEDIR/finish.sh
# Llamado por qBittorrent como: $BASEDIR/finish.sh %K "%N" %Z %D %L %R %F
# =============================================================================
# Parámetros de qBittorrent:
#   %K = ID del torrent (hash)
#   %N = Nombre del torrent
#   %Z = Tamaño de la descarga (bytes)
#   %D = Directorio de guardado
#   %L = Categoría
#   %R = Ruta completa del contenido
#   %F = Ruta del primer archivo (si es un solo archivo)
# =============================================================================

TORRENT_HASH="$1"
TORRENT_NAME="$2"
TORRENT_SIZE="$3"
SAVE_DIR="$4"
CATEGORY="$5"
CONTENT_PATH_R="$6"
FIRST_FILE="$7"

# %F contiene la ruta completa cuando es un archivo individual
# %R contiene la ruta de la carpeta cuando es multi-archivo
# Usamos %F si está disponible (archivo individual), si no %R (carpeta)
if [ -n "$FIRST_FILE" ]; then
    CONTENT_PATH="$FIRST_FILE"
else
    CONTENT_PATH="$CONTENT_PATH_R"
fi

BASEDIR=/config

source $BASEDIR/finish.env

# =============================================================================
# FUNCIONES
# =============================================================================

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> $BASEDIR/finished.log
}

# Envía notificación a Gotify
# $1 = título, $2 = mensaje, $3 = prioridad (1=min, 5=normal, 10=max)
gotify_notify() {
    local title="$1"
    local message="$2"
    local priority="${3:-5}"

    if [ "$SEND_NOTIFICATION" == "yes" ]; then
    curl -s -X POST "${GOTIFY_URL}/message" \
        -H "X-Gotify-Key: ${GOTIFY_TOKEN}" \
        -F "title=${title}" \
        -F "message=${message}" \
        -F "priority=${priority}" \
        -o /dev/null
    fi    
}

# Devuelve 0 si el archivo es un video (por extensión)
is_video() {
    local file="$1"
    local ext="${file##*.}"
    echo "$ext" | grep -qiE "^(${VIDEO_EXTENSIONS})$"
}

# Escanea un archivo con ClamAV. Devuelve 0 si está limpio, 1 si infectado.
# Imprime el nombre del virus si está infectado.
# Formato de respuesta de clamav-rest-api (result es un array):
#   { "success": true, "data": { "result": [ { "name": "...", "is_infected": false, "viruses": [] } ] } }
scan_file() {
    local filepath="$1"
    local filename
    filename=$(basename "$filepath")

    local result
    result=$(curl -s -X POST "${CLAMAV_URL}/api/v1/scan" \
        -F "FILES=@\"${filepath}\"")

    # Parseo nativo sin jq — funciona tanto si result es objeto como array
    local is_infected
    is_infected=$(echo "$result" | grep -o '"is_infected":[^,}\]]*' | head -1 | grep -o 'true\|false')

    if [ "$is_infected" = "true" ]; then
        local virus
        virus=$(echo "$result" | grep -o '"viruses":\["[^"]*"' | grep -o '"[^"]*"$' | tr -d '"')
        echo "$virus"
        return 1
    fi

    return 0
}

# Elimina un archivo infectado y lo excluye en qBittorrent
delete_infected() {
    local filepath="$1"
    local filename
    filename=$(basename "$filepath")

    log "Eliminando archivo infectado: ${filepath}"
    rm -f "$filepath"

    # Intentar marcar el archivo como no deseado en qBittorrent via API
    # La API de qBittorrent no tiene un endpoint directo para "no volver a descargar"
    # pero podemos remover el archivo de la lista del torrent vía file priority = 0 (no descargar)
    # Primero obtenemos el índice del archivo dentro del torrent
    local files_json
    files_json=$(curl -s "${QB_URL}/api/v2/torrents/files?hash=${TORRENT_HASH}")

    # Buscar el índice del archivo por nombre
    local file_index
    file_index=$(echo "$files_json" | grep -o '"index":[0-9]*[^}]*"name":"[^"]*'"${filename}"'"' | grep -o '"index":[0-9]*' | grep -o '[0-9]*' | head -1)

    if [ -n "$file_index" ]; then
        # Establecer prioridad 0 = no descargar
        curl -s -X POST "${QB_URL}/api/v2/torrents/filePrio" \
            -d "hash=${TORRENT_HASH}&id=${file_index}&priority=0" \
            -o /dev/null
        log "Archivo marcado como no descargar en qBittorrent (índice ${file_index})"
    else
        log "No se pudo determinar el índice del archivo en qBittorrent"
    fi
}

# Transfiere un archivo con transferr
# $1 = ruta del archivo, $2 = destination, $3 = subfolder (opcional)
transfer_file() {
    local filepath="$1"
    local destination="$2"
    local subfolder="$3"

    log "Transfiriendo: ${filepath} → ${destination}"

    if [ -n "$subfolder" ]; then
        curl -s -X POST "${TRANSFERR_URL}/transfer" \
            -F "file=@\"${filepath}\"" \
            -F "destination=${destination}" \
            -F "subfolder=${subfolder}" \
            -w "\nHTTP: %{http_code}" \
            -o /dev/null
    else
        curl -s -X POST "${TRANSFERR_URL}/transfer" \
            -F "file=@\"${filepath}\"" \
            -F "destination=${destination}" \
            -w "\nHTTP: %{http_code}" \
            -o /dev/null
    fi
}

# Sube el log a pastebin y notifica por Gotify con la URL
# $1 = contexto del error (mensaje corto)
paste_error() {
    local context="${1:-error desconocido}"
    local log_content

    # Leer el log acumulado hasta ahora
    log_content=$(cat $BASEDIR/finished.log 2>/dev/null | tail -100)
    [ -z "$log_content" ] && log_content="(sin log disponible)"

    # Crear paste via API
    local payload
    payload=$(printf '{"title":"qbit: %s — %s","content":%s,"language":"plaintext","ttl_seconds":604800}' \
        "$TORRENT_NAME" \
        "$context" \
        "$(echo "$log_content" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))')")

    local resp paste_id paste_url
    resp=$(curl -s -X POST "${PASTEBIN_URL}/api/pastes" \
        -H "Content-Type: application/json" \
        -d "$payload" 2>/dev/null)

    paste_id=$(echo "$resp" | grep -o '"id":"[^"]*"' | head -1 | cut -d'"' -f4)

    if [ -n "$paste_id" ]; then
        paste_url="${PASTEBIN_URL}/p/${paste_id}"
        log "Log subido a pastebin: ${paste_url}"
        gotify_notify \
            "❌ Error en post-proceso" \
            "📁 ${TORRENT_NAME}
⚠️ ${context}
📋 Log: ${paste_url}" \
            10
    else
        log "No se pudo subir el log a pastebin."
        gotify_notify \
            "❌ Error en post-proceso" \
            "📁 ${TORRENT_NAME}
⚠️ ${context}
(pastebin no disponible)" \
            10
    fi
}

# Ejecuta un comando y si falla llama a paste_error (solo si PASTE_ERRORS=yes)
# Uso: try_or_report "descripcion" comando arg1 arg2...
try_or_report() {
    local context="$1"
    shift
    "$@"
    local rc=$?
    if [ $rc -ne 0 ] && [ "$PASTE_ERRORS" == "yes" ]; then
        paste_error "${context} (exit ${rc})"
    fi
    return $rc
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
# $1 = query (nombre limpio), $2 = tipo (movie|tv), $3 = temporada (opcional), $4 = episodio (opcional)
# Retorna el download_link relativo, ej: /subtitle/12345.zip
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
# Flujo: os es-la → os es → subdl es → os en ai_translated
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

    # Si tiene SxxExx: quedarse solo con serie + SxxExx, descartar título del episodio
    if echo "$query" | grep -qiE 'S[0-9]{2}E[0-9]{2}'; then
        query=$(echo "$query" | sed 's/\([Ss][0-9]\{2\}[Ee][0-9]\{2\}\).*/\1/' \
            | sed 's/ - / /g;s/  */ /g;s/ *$//')
    else
        # Para películas: quitar separadores y tags de release
        query=$(echo "$query" | sed \
            -e 's/ - / /g' \
            -e 's/\b\(1080p\|720p\|2160p\|4K\|BluRay\|BDRip\|WEB-DL\|WEBRip\|WEBDL\|HDTV\|DVDRip\|x264\|x265\|HEVC\|AAC\|AC3\|EAC3\|DTS\|HDR\|SDR\|REMUX\|PROPER\|REPACK\|FLUX\|NTb\|PSA\|YTS\)\b.*//Ig' \
            -e 's/  */ /g;s/ *$//')
    fi

    # Para $MOVIES_CATEGORY: extraer el año del nombre original y agregarlo entre paréntesis
    if [ "$CATEGORY" = "$MOVIES_CATEGORY" ]; then
        local year
        year=$(echo "$video_name" | grep -oE '\b(19|20)[0-9]{2}\b' | head -1)
        if [ -n "$year" ]; then
            query=$(echo "$query" | sed "s/ *${year} *$//;s/ *${year} */ /g" | sed 's/  */ /g;s/ *$//')
            year_str=" (${year})"
        fi
    fi

    log "Buscando subtítulo para: ${video_name} (query: ${query})"

    # Extraer temporada y episodio si es serie (para SubDL)
    local subdl_season="" subdl_episode="" subdl_type="movie"
    if echo "$query" | grep -qiE 'S[0-9]{2}E[0-9]{2}'; then
        subdl_type="tv"
        subdl_season=$(echo "$query" | grep -oiE 'S([0-9]{2})E[0-9]{2}' | grep -oE '[0-9]{2}' | head -1 | sed 's/^0*//')
        subdl_episode=$(echo "$query" | grep -oiE 'S[0-9]{2}E([0-9]{2})' | grep -oE '[0-9]{2}' | tail -1 | sed 's/^0*//')
        # Query para SubDL: solo el nombre de la serie (sin SxxExx)
        local subdl_query
        subdl_query=$(echo "$query" | sed 's/ *[Ss][0-9]\{2\}[Ee][0-9]\{2\}.*//' | sed 's/ *$//')
    else
        local subdl_query="$query"
    fi

    # --- LOGIN para obtener JWT de OpenSubtitles ---
    local login_resp jwt
    login_resp=$(curl -s -X POST "${OPENSUBS_URL}/login" \
        -H "Api-Key: ${OPENSUBS_API_KEY}" \
        -H "User-Agent: ${OPENSUBS_USERAGENT}" \
        -H "Content-Type: application/json" \
        -H "Accept: application/json" \
        -d "{\"username\": \"${OPENSUBS_USER}\", \"password\": \"${OPENSUBS_PASS}\"}")

    jwt=$(echo "$login_resp" | grep -o '"token":"[^"]*"' | head -1 | cut -d'"' -f4)

    if [ -z "$jwt" ]; then
        log "OpenSubtitles: fallo de login. Respuesta: ${login_resp}"
    else
        log "OpenSubtitles: login OK"
    fi

    local file_id="" found_lang="" subdl_link="" provider=""

    # Intento 1: OpenSubtitles español latino
    if [ -n "$jwt" ]; then
        file_id=$(opensubs_search "$query" "$jwt" "es-la")
        [ -n "$file_id" ] && found_lang="español latino" && provider="opensubtitles"
    fi

    # Intento 2: OpenSubtitles español
    if [ -z "$file_id" ] && [ -n "$jwt" ]; then
        file_id=$(opensubs_search "$query" "$jwt" "es")
        [ -n "$file_id" ] && found_lang="español" && provider="opensubtitles"
    fi

    # Intento 3: SubDL español
    if [ -z "$file_id" ]; then
        subdl_link=$(subdl_search "$subdl_query" "$subdl_type" "$subdl_season" "$subdl_episode")
        if [ -n "$subdl_link" ]; then
            found_lang="español (SubDL)"
            provider="subdl"
            log "SubDL: subtítulo encontrado → ${subdl_link}"
        fi
    fi

    # Intento 4: OpenSubtitles inglés con ai_translated
    if [ -z "$file_id" ] && [ -z "$subdl_link" ] && [ -n "$jwt" ]; then
        file_id=$(opensubs_search "$query" "$jwt" "en" "&ai_translated=include")
        [ -n "$file_id" ] && found_lang="inglés (ai_translated)" && provider="opensubtitles"
    fi

    if [ -z "$file_id" ] && [ -z "$subdl_link" ]; then
        log "No se encontró subtítulo para: ${video_name}"
        gotify_notify \
            "🔤 Sin subtítulo" \
            "📁 ${video_name}
No se encontró subtítulo en ningún proveedor." \
            3
        return 0
    fi

    # --- DESCARGA según proveedor ---
    local srt_path="${video_dir}/${video_name}.srt"

    log "Subtítulo encontrado (${found_lang}) via ${provider}. Descargando..."

    if [ "$provider" = "opensubtitles" ]; then
        opensubs_download "$file_id" "$jwt" "$srt_path"
    elif [ "$provider" = "subdl" ]; then
        subdl_download "$subdl_link" "$srt_path"
    fi

    if [ -f "$srt_path" ] && [ -s "$srt_path" ]; then
        log "Subtítulo guardado junto al video: ${srt_path}"

        # Copiar también a $BASEDIR/subs/ con nombre limpio (query) para subsupd.sh
        mkdir -p $BASEDIR/subs
        local srt_clean="$BASEDIR/subs/${query}${year_str}.srt"
        cp "$srt_path" "$srt_clean"
        log "Subtítulo copiado a subs pool: ${srt_clean}"

        gotify_notify \
            "🔤 Subtítulo descargado" \
            "📁 ${video_name}
🌐 Idioma: ${found_lang}" \
            3
    else
        log "Error: el archivo de subtítulo quedó vacío o no se creó."
        rm -f "$srt_path"
    fi
}

# Llama a butler-api para generar ficha del archivo
# $1 = nombre del archivo
call_butler() {
    local filename="$1"
    log "Generando ficha con butler-api para: ${filename}"
    curl -s -X POST "${BUTLER_URL}/process" \
        -F "filename=${filename}" \
        -o /dev/null
}

# =============================================================================
# MAIN
# =============================================================================

log "======================================================"
log "Inicio de post-proceso"
log "Torrent: ${TORRENT_NAME}"
log "Hash:    ${TORRENT_HASH}"
log "Categoría: ${CATEGORY}"
log "Ruta:    ${CONTENT_PATH}"
log "======================================================"

# ------------------------------------------------------------------------------
# 1. NOTIFICACIÓN DE DESCARGA FINALIZADA
# ------------------------------------------------------------------------------

# Convertir tamaño a formato legible
size_mb=$(( TORRENT_SIZE / 1024 / 1024 ))
gotify_notify \
    "✅ Descarga finalizada" \
    "📁 ${TORRENT_NAME}
📦 Tamaño: ${size_mb} MB
🏷️ Categoría: ${CATEGORY}" \
    5

log "Notificación de descarga finalizada enviada."

# ------------------------------------------------------------------------------
# 2. ESCANEO ANTIVIRUS
# ------------------------------------------------------------------------------

if [ "$SCAN_FILES" == "yes" ]; then
    log "Iniciando escaneo antivirus..."

    infected_count=0
    clean_count=0
    skipped_count=0
    infected_files=""

    # Construir lista de archivos a escanear
    if [ -f "$CONTENT_PATH" ]; then
        files_to_scan=("$CONTENT_PATH")
    else
        mapfile -t files_to_scan < <(find "$CONTENT_PATH" -type f)
    fi

    for filepath in "${files_to_scan[@]}"; do
        filename=$(basename "$filepath")

        # Saltar videos por extensión
        if is_video "$filepath"; then
            log "Saltando (video): ${filename}"
            (( skipped_count++ ))
            continue
        fi

        log "Escaneando: ${filename}"
        virus_name=$(scan_file "$filepath")
        scan_result=$?

        if [ $scan_result -eq 1 ]; then
            log "⚠️  INFECTADO: ${filename} - ${virus_name}"
            infected_files="${infected_files}\n• ${filename} (${virus_name})"
            (( infected_count++ ))
            delete_infected "$filepath"
        else
            log "✅ Limpio: ${filename}"
            (( clean_count++ ))
        fi
    done

    # Notificación resultado del escaneo
    if [ $infected_count -gt 0 ]; then
        gotify_notify \
            "🦠 Virus detectado en descarga" \
            "📁 ${TORRENT_NAME}
Archivos infectados eliminados:$(printf '%b' "$infected_files")
✅ Limpios: ${clean_count} | ⏭️ Videos omitidos: ${skipped_count}" \
            10
        log "Se encontraron y eliminaron ${infected_count} archivos infectados."
    else
        gotify_notify \
            "🛡️ Escaneo completado: sin amenazas" \
            "📁 ${TORRENT_NAME}
✅ Archivos limpios: ${clean_count} | ⏭️ Videos omitidos: ${skipped_count}" \
            3
        log "Escaneo completado. Todo limpio."
    fi
fi

# Reconstruir lista de archivos limpios (por si se eliminaron infectados)
if [ -f "$CONTENT_PATH" ]; then
    # Es un archivo individual: verificar que siga existiendo (puede haber sido eliminado por infectado)
    clean_files=("$CONTENT_PATH")
elif [ -d "$CONTENT_PATH" ]; then
    # Es una carpeta: buscar todos los archivos que quedaron
    mapfile -t clean_files < <(find "$CONTENT_PATH" -type f 2>/dev/null)
else
    log "ADVERTENCIA: CONTENT_PATH no existe o no es accesible: ${CONTENT_PATH}"
    paste_error "CONTENT_PATH no existe: ${CONTENT_PATH}"
    clean_files=()
fi

# ------------------------------------------------------------------------------
# 3. TRANSFERENCIA DE ARCHIVOS SEGÚN CATEGORÍA
# ------------------------------------------------------------------------------

if [ "$TRANSFER_FILES" == "yes" ]; then
    log "Procesando transferencia para categoría: ${CATEGORY}"

    transfer_destinations=()
    case "$CATEGORY" in
        $BOOKS_CATEGORY)  transfer_destinations=("${BOOK_TRANSFER[@]}") ;;
        $COMIC_CATEGORY)  transfer_destinations=("${COMIC_TRANSFER[@]}") ;;
        $MUSIC_CATEGORY)  transfer_destinations=("${MUSIC_TRANSFER[@]}") ;;
        $MOVIES_CATEGORY) transfer_destinations=("${MOVIE_TRANSFER[@]}") ;;
        $SERIES_CATEGORY) transfer_destinations=("${SERIES_TRANSFER[@]}") ;;
        *)
            log "Categoría '${CATEGORY}' no tiene regla de transferencia configurada."
            ;;
    esac

    for filepath in "${clean_files[@]}"; do
        for destination in "${transfer_destinations[@]}"; do
            transfer_file "$filepath" "$destination"
        done
    done
fi

# ------------------------------------------------------------------------------
# 4. GENERACIÓN DE FICHAS CON BUTLER-API
# ------------------------------------------------------------------------------
# Extensiones relevantes por categoría:
#   $MOVIES_CATEGORY    : una sola llamada con el video más grande
#   tv-$SERIES_CATEGORY : una llamada por cada archivo de video
#   $BOOKS_CATEGORY    : epub, pdf, mobi, azw3, azw, djvu, fb2, lit, lrf
#   $COMIC_CATEGORY    : cbz, cbr, cb7, cbt, pdf
#   $MUSIC_CATEGORY    : mp3, flac, ogg, m4a, wav, aac, opus, wma, ape, alac

BUTLER_VIDEO_EXT="mkv|mp4|avi|mov|wmv|m4v|ts|m2ts|webm|divx|xvid|mpg|mpeg|vob|rmvb|3gp"
BUTLER_LIBRO_EXT="epub|pdf|mobi|azw3|azw|djvu|fb2|lit|lrf"
BUTLER_COMIC_EXT="cbz|cbr|cb7|cbt|pdf"
BUTLER_MUSICA_EXT="mp3|flac|ogg|m4a|wav|aac|opus|wma|ape|alac"

# Función auxiliar: filtra archivos de clean_files por extensión
# $1 = patrón de extensiones (pipe-separated)
get_files_by_ext() {
    local ext_pattern="$1"
    for fp in "${clean_files[@]}"; do
        local ext="${fp##*.}"
        if echo "$ext" | grep -qiE "^(${ext_pattern})$"; then
            echo "$fp"
        fi
    done
}

if [ "$GENERATE_BUTLER_CARD" == "yes" ]; then
    case "$CATEGORY" in

        $MOVIES_CATEGORY)
            log "Butler - $MOVIES_CATEGORY: buscando archivo de video principal..."
            largest_video=""
            largest_size=0
            while IFS= read -r fp; do
                fsize=$(stat -c%s "$fp" 2>/dev/null || echo 0)
                if [ "$fsize" -gt "$largest_size" ]; then
                    largest_size=$fsize
                    largest_video=$fp
                fi
            done < <(get_files_by_ext "$BUTLER_VIDEO_EXT")

            if [ -n "$largest_video" ]; then
                call_butler "$(basename "$largest_video")"
            else
                log "Butler - $MOVIES_CATEGORY: no se encontró archivo de video."
            fi
            ;;

        $SERIES_CATEGORY)
            log "Butler - $SERIES_CATEGORY: generando ficha por cada episodio..."
            while IFS= read -r fp; do
                call_butler "$(basename "$fp")"
            done < <(get_files_by_ext "$BUTLER_VIDEO_EXT")
            ;;

        $BOOKS_CATEGORY)
            log "Butler - $BOOKS_CATEGORY: generando ficha por cada libro..."
            while IFS= read -r fp; do
                call_butler "$(basename "$fp")"
            done < <(get_files_by_ext "$BUTLER_LIBRO_EXT")
            ;;

        $COMIC_CATEGORY)
            log "Butler - $COMIC_CATEGORY: generando ficha por cada comic..."
            while IFS= read -r fp; do
                call_butler "$(basename "$fp")"
            done < <(get_files_by_ext "$BUTLER_COMIC_EXT")
            ;;

        $MUSIC_CATEGORY)
            log "Butler - $MUSIC_CATEGORY: generando ficha por cada pista..."
            while IFS= read -r fp; do
                call_butler "$(basename "$fp")"
            done < <(get_files_by_ext "$BUTLER_MUSICA_EXT")
            ;;

        *)
            log "Categoría '${CATEGORY}' no genera fichas con butler-api."
            ;;
    esac
fi

# ------------------------------------------------------------------------------
# 5. BÚSQUEDA DE SUBTÍTULOS (solo $MOVIES_CATEGORY y $SERIES_CATEGORY)
# ------------------------------------------------------------------------------

if [ "$SEARCH_SUBTITLES" == "yes" ]; then
    case "$CATEGORY" in

        $MOVIES_CATEGORY)
            log "Buscando subtítulo para $MOVIES_CATEGORY..."
            largest_video=""
            largest_size=0
            while IFS= read -r fp; do
                fsize=$(stat -c%s "$fp" 2>/dev/null || echo 0)
                if [ "$fsize" -gt "$largest_size" ]; then
                    largest_size=$fsize
                    largest_video=$fp
                fi
            done < <(get_files_by_ext "$BUTLER_VIDEO_EXT")

            if [ -n "$largest_video" ]; then
                fetch_subtitle "$largest_video"
            else
                log "Subtítulos - $MOVIES_CATEGORY: no se encontró archivo de video."
            fi
            ;;

        $SERIES_CATEGORY)
            log "Buscando subtítulo por cada episodio..."
            while IFS= read -r fp; do
                fetch_subtitle "$fp"
            done < <(get_files_by_ext "$BUTLER_VIDEO_EXT")
            ;;

    esac
fi

# ------------------------------------------------------------------------------
# FIN
# ------------------------------------------------------------------------------

log "======================================================"
log "Post-proceso finalizado para: ${TORRENT_NAME}"
log "======================================================"

exit 0
