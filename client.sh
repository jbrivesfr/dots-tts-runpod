#!/bin/bash
# client.sh — Call dots.tts RunPod Load Balancer endpoint
# 
# Setup:
#   export DOTS_TTS_ENDPOINT="https://YOUR_ENDPOINT_ID.api.runpod.ai"
#   export RUNPOD_API_KEY="rpa_..."    (only needed for queue-based; LB doesn't need it)
#
# Usage:
#   source client.sh
#   dots-tts "Bonjour JB" --voice jb --format opus --endpoint https://xxx.api.runpod.ai
#   dots-tts "Hello world" --voice default

set -e

ENDPOINT="${DOTS_TTS_ENDPOINT:-$1}"
RUNPOD_KEY="${RUNPOD_API_KEY:-$(cat ~/clawd/dots-tts-deploy/runpod.md 2>/dev/null || cat ~/clawd/runpod.md 2>/dev/null)}"
DEFAULT_VOICE="${DOTS_TTS_VOICE:-default}"
DEFAULT_FORMAT="${DOTS_TTS_FORMAT:-opus}"

dots-tts() {
    local text=""
    local voice="$DEFAULT_VOICE"
    local fmt="$DEFAULT_FORMAT"
    local out=""
    local endpoint="$ENDPOINT"
    
    # Parse args
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --voice)    voice="$2"; shift 2 ;;
            --format)   fmt="$2"; shift 2 ;;
            --out)      out="$2"; shift 2 ;;
            --endpoint) endpoint="$2"; shift 2 ;;
            *)          text="$1"; shift ;;
        esac
    done
    
    if [ -z "$text" ]; then
        echo "Usage: dots-tts \"text\" [--voice jb] [--format opus|wav] [--out path] [--endpoint url]" >&2
        return 1
    fi
    
    if [ -z "$endpoint" ]; then
        echo "❌ Set DOTS_TTS_ENDPOINT or pass --endpoint" >&2
        echo "   Format: https://ENDPOINT_ID.api.runpod.ai" >&2
        return 1
    fi
    
    # Ensure endpoint has trailing /
    [[ "$endpoint" != */ ]] && endpoint="$endpoint/"
    
    [ -z "$out" ] && out="/tmp/dots-tts-$(date +%s).${fmt}"
    
    echo "🎙️ dots.tts → RunPod LB" >&2
    echo "   text: ${text:0:80}..." >&2
    echo "   voice: $voice | format: $fmt" >&2
    echo "   endpoint: ${endpoint}generate" >&2
    
    local start=$(date +%s)
    
    # Call RunPod LB endpoint
    local auth_header=""
    [ -n "$RUNPOD_KEY" ] && auth_header="-H Authorization: Bearer $RUNPOD_KEY"
    
    local http_code
    http_code=$(curl -s -o "$out" -w "%{http_code}" \
        -X POST "${endpoint}generate" \
        -H "Content-Type: application/json" \
        -H "Accept: audio/*" \
        $auth_header \
        -d "{\"text\": $(python3 -c "import json,sys; print(json.dumps(sys.argv[1]))" "$text"), \"voice\": \"$voice\", \"format\": \"$fmt\"}" 2>/dev/null)
    
    local elapsed=$(($(date +%s) - start))
    
    # Check result
    if [ -f "$out" ] && [ -s "$out" ]; then
        local file_type=$(file "$out" | grep -o 'RIFF\|Ogg\|WAVE\|audio' || echo "unknown")
        local size=$(ls -lh "$out" | awk '{print $5}')
        echo "   ✅ ${size} | ${elapsed}s total" >&2
        echo "   type: $file_type" >&2
        echo "MEDIA:$out"
        return 0
    else
        local err=$(cat "$out" 2>/dev/null || echo "No output")
        echo "❌ Failed (${elapsed}s): $err" >&2
        return 1
    fi
}

# If called directly
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    dots-tts "$@"
fi
