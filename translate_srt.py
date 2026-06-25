#!/usr/bin/env python3
"""
translate_srt.py - Traduce un archivo .srt de inglés a español usando LibreTranslate.

Uso: python3 translate_srt.py input.srt [output.srt]
     Si no se especifica output, sobreescribe el input.
"""

import sys
import re
import time
import requests
from pathlib import Path
from dotenv import load_dotenv
import os

load_dotenv()

API_URL    = os.getenv("LIBRETRANSLATE_URL", "http://localhost:5445") + "/translate"
API_KEY    = os.getenv("LIBRETRANSLATE_API_KEY")
BATCH_SIZE = int(os.getenv("LT_BATCH_SIZE", "25"))   # líneas por request
SEPARATOR  = "\n§§§\n"                                # delimitador que LT no toca


def parse_srt(content: str) -> list[dict]:
    """Parsea un SRT y devuelve lista de bloques {index, timestamp, lines}."""
    blocks = []
    # Normalizar saltos de línea
    content = content.replace("\r\n", "\n").replace("\r", "\n").strip()

    for raw_block in re.split(r"\n{2,}", content):
        lines = raw_block.strip().splitlines()
        if len(lines) < 2:
            continue

        # Primera línea: índice numérico
        if not lines[0].strip().isdigit():
            continue

        # Segunda línea: timestamp
        if "-->" not in lines[1]:
            continue

        blocks.append({
            "index":     lines[0].strip(),
            "timestamp": lines[1].strip(),
            "lines":     lines[2:],
        })

    return blocks


def rebuild_srt(blocks: list[dict]) -> str:
    """Reconstruye el contenido .srt desde los bloques."""
    parts = []
    for b in blocks:
        text = "\n".join(b["lines"])
        parts.append(f"{b['index']}\n{b['timestamp']}\n{text}")
    return "\n\n".join(parts) + "\n"


def translate_batch(texts: list[str]) -> list[str]:
    """Traduce una lista de textos en un solo request usando separador."""
    joined = SEPARATOR.join(texts)

    payload = {
        "q":      joined,
        "source": "en",
        "target": "es",
        "format": "text",
    }
    if API_KEY:
        payload["api_key"] = API_KEY

    resp = requests.post(API_URL, json=payload, timeout=60)
    resp.raise_for_status()

    data = resp.json()
    if "translatedText" not in data:
        raise RuntimeError(f"API error: {data.get('error', data)}")

    translated = data["translatedText"].split(SEPARATOR)

    # Si la API devuelve distinta cantidad, loguear y devolver originales
    if len(translated) != len(texts):
        print(f"  [WARN] Batch desbalanceado: enviados={len(texts)}, recibidos={len(translated)}. Usando originales.")
        return texts

    return [t.strip() for t in translated]


def translate_srt(input_path: Path, output_path: Path):
    print(f"[*] Parseando: {input_path.name}")

    try:
        content = input_path.read_text(encoding="utf-8")
    except UnicodeDecodeError:
        content = input_path.read_text(encoding="latin-1")

    blocks = parse_srt(content)
    if not blocks:
        print("[ERROR] No se pudieron parsear bloques del SRT.")
        sys.exit(1)

    print(f"[*] Bloques encontrados: {len(blocks)}")

    # Agrupar textos de diálogo en batches
    all_texts = ["\n".join(b["lines"]) for b in blocks]
    translated_texts = []

    total_batches = (len(all_texts) + BATCH_SIZE - 1) // BATCH_SIZE

    for i in range(0, len(all_texts), BATCH_SIZE):
        batch = all_texts[i:i + BATCH_SIZE]
        batch_num = i // BATCH_SIZE + 1
        print(f"  Traduciendo batch {batch_num}/{total_batches} ({len(batch)} bloques)...")

        try:
            translated = translate_batch(batch)
            translated_texts.extend(translated)
        except requests.HTTPError as e:
            print(f"  [HTTP ERROR] {e.response.status_code} - {e.response.text}")
            sys.exit(1)
        except Exception as e:
            print(f"  [ERROR] {e}")
            sys.exit(1)

        # Pausa breve entre batches para no saturar
        if batch_num < total_batches:
            time.sleep(0.5)

    # Reconstruir bloques con texto traducido
    for block, translated in zip(blocks, translated_texts):
        block["lines"] = translated.splitlines()

    output_path.write_text(rebuild_srt(blocks), encoding="utf-8")
    print(f"[OK] Subtítulo traducido guardado: {output_path}")


if __name__ == "__main__":
    if len(sys.argv) < 2:
        print(f"Uso: {sys.argv[0]} input.srt [output.srt]")
        sys.exit(1)

    input_path = Path(sys.argv[1])
    output_path = Path(sys.argv[2]) if len(sys.argv) >= 3 else input_path

    if not input_path.exists():
        print(f"[ERROR] Archivo no encontrado: {input_path}")
        sys.exit(1)

    translate_srt(input_path, output_path)
