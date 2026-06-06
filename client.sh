#!/bin/bash
# client.sh — Call dots.tts RunPod Queue-Based endpoint
# 
# Setup:
#   export DOTS_TTS_ENDPOINT="https://api.runpod.ai/v2/YOUR_ENDPOINT_ID"
#   export RUNPOD_API_KEY="rpa_..."
#
# Usage:
#   source client.sh
#   dots-tts "Bonjour JB" --voice jb --format opus

set -e

ENDPOINT="${DOTS_TTS_ENDPOINT:-$1}"
RUNPOD_KEY="${RUNPOD_API_KEY:-$(cat ~/clawd/dots-tts-deploy/runpod.md 2>/dev/null)}"
DEFAULT_VOICE="${DOTS_TTS_VOICE:-default}"
DEFAULT_FORMAT="${DOTS_TTS_FORMAT:-opus}"

dots-tts() {
    local text=""
    local voice="$DEFAULT_VOICE"
    local fmt="$DEFAULT_FORMAT"
    local out=""
    
    # Parse args
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --voice)    voice="$2"; shift 2 ;;
            --format)   fmt="$2"; shift 2 ;;
            --out)      out="$2"; shift 2 ;;
            --endpoint) ENDPOINT="$2"; shift 2 ;;
            *)          text="$1"; shift ;;
        esac
    done
    
    if [ -z "$text" ]; then
        echo "Usage: dots-tts \"text\" [--voice jb] [--format opus|wav] [--out path]" >&2
        return 1
    fi
    
    if [ -z "$ENDPOINT" ]; then
        echo "❌ Set DOTS_TTS_ENDPOINT or pass --endpoint" >&2
        return 1
    fi
    
    if [ -z "$RUNPOD_KEY" ]; then
        echo "❌ Set RUNPOD_API_KEY or create ~/clawd/dots-tts-deploy/runpod.md" >&2
        return 1
    fi
    
    [ -z "$out" ] && out="/tmp/dots-tts-$(date +%s).$fmt"
    
    echo "🎙️ dots.tts → RunPod Queue" >&2
    echo "   text: ${text:0:80}..." >&2
    echo "   voice: $voice | format: $fmt" >&2
    
    local start=$(date +%s)
    
    # Submit sync job (wait for result)
    local response
    response=$(curl -s -X POST "${ENDPOINT}/runsync" \
        -H "Content-Type: application/json" \
        -H "Authorization: Bearer $RUNPOD_KEY" \
        -d "$(python3 -c "import json; print(json.dumps({'input': {'text': '$text', 'voice': '$voice', 'format': '$fmt'}}))")" \
        -w "\n%{http_code}" 2>/dev/null)
    
    local elapsed=$(($(date +%s) - start))
    local http_code=$(echo "$response" | tail -1)
    local body=$(echo "$response" | sed '$d')
    
    if [ "$http_code" != "200" ]; then
        echo "❌ HTTP $http_code (${elapsed}s)" >&2
        echo "$body" | head -5 >&2
        return 1
    fi
    
    # Parse RunPod response: {"output": {"audio_base64": "...", ...}}
    echo "$body" | python3 -c "
import json, sys, base64
d = json.load(sys.stdin)
out = d.get('output', d)
if 'error' in out:
    print(f'❌ {out[\"error\"]}', file=sys.stderr)
    sys.exit(1)
b64 = out.get('audio_base64', '')
if not b64:
    print('❌ No audio in response', file=sys.stderr)
    sys.exit(1)
audio = base64.b64decode(b64)
with open('$out', 'wb') as f:
    f.write(audio)
info = {
    'duration_s': out.get('duration_s', 0),
    'gen_time_s': out.get('gen_time_s', 0),
    'rtf': out.get('rtf', 0),
    'size_kb': round(len(audio)/1024, 1),
    'voice': out.get('voice', '?'),
    'format': out.get('format', '?'),
}
print(json.dumps(info, indent=2))
" 2>/dev/null
    
    local code=$?
    if [ $code -eq 0 ] && [ -f "$out" ] && [ -s "$out" ]; then
        echo "   ✅ $(ls -lh "$out" | awk '{print $5}') | ${elapsed}s total" >&2
        echo "MEDIA:$out"
        return 0
    else
        echo "❌ Generation failed (${elapsed}s)" >&2
        return 1
    fi
}

# If called directly
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    dots-tts "$@"
fi
