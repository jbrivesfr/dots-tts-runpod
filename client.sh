#!/bin/bash
# client.sh — Call dots.tts RunPod Serverless endpoint
# 
# Setup:
#   export DOTS_TTS_ENDPOINT="https://api.runpod.ai/v2/YOUR_ENDPOINT_ID/run"
#   export RUNPOD_API_KEY="rpa_..."
#
# Usage:
#   source client.sh
#   dots-tts "Bonjour JB" --voice jb --format opus
#   dots-tts "Hello world" --voice default

set -e

ENDPOINT="${DOTS_TTS_ENDPOINT:-$1}"
API_KEY="${RUNPOD_API_KEY:-$(cat ~/clawd/runpod.md 2>/dev/null)}"
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
            --voice)  voice="$2"; shift 2 ;;
            --format) fmt="$2"; shift 2 ;;
            --out)    out="$2"; shift 2 ;;
            --endpoint) ENDPOINT="$2"; shift 2 ;;
            *)        text="$1"; shift ;;
        esac
    done
    
    if [ -z "$text" ]; then
        echo "Usage: dots-tts \"text\" [--voice jb] [--format opus|wav] [--out path]" >&2
        return 1
    fi
    
    if [ -z "$ENDPOINT" ]; then
        echo "❌ Set DOTS_TTS_ENDPOINT or pass as argument" >&2
        return 1
    fi
    
    [ -z "$out" ] && out="/tmp/dots-tts-$(date +%s).${fmt}"
    
    echo "🎙️ dots.tts → RunPod" >&2
    echo "   text: ${text:0:80}..." >&2
    echo "   voice: $voice | format: $fmt" >&2
    
    # Call RunPod Serverless (sync)
    local start=$(date +%s)
    local response
    response=$(curl -s -X POST "$ENDPOINT" \
        -H "Content-Type: application/json" \
        -H "Authorization: Bearer $API_KEY" \
        -d "{\"input\": {\"text\": $(echo "$text" | python3 -c "import json,sys; print(json.dumps(sys.stdin.read()))"), \"voice\": \"$voice\", \"format\": \"$fmt\"}}" \
        -w "\n%{http_code}" 2>/dev/null)
    
    local http_code=$(echo "$response" | tail -1)
    local body=$(echo "$response" | head -n -1)
    local elapsed=$(($(date +%s) - start))
    
    if [ "$http_code" != "200" ]; then
        echo "❌ HTTP $http_code" >&2
        echo "$body" >&2
        return 1
    fi
    
    # Parse response: {"output": {"audio_base64": "...", ...}}
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
print(json.dumps({
    'duration_s': out.get('duration_s', 0),
    'gen_time_s': out.get('gen_time_s', 0),
    'rtf': out.get('rtf', 0),
    'size_kb': len(audio)/1024,
    'voice': out.get('voice', '?'),
    'format': out.get('format', '?')
}))
" 2>/dev/null
    
    if [ $? -eq 0 ] && [ -f "$out" ] && [ -s "$out" ]; then
        echo "   ✅ $(ls -lh "$out" | awk '{print $5}') | ${elapsed}s total" >&2
        echo "MEDIA:$out"
        return 0
    else
        echo "❌ Generation failed" >&2
        return 1
    fi
}

# If sourced, just define the function. If called directly, run it.
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    dots-tts "$@"
fi
