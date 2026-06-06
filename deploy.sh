#!/bin/bash
# deploy.sh — Deploy dots.tts to RunPod Serverless
# Usage: 
#   1. Set API key:  export RUNPOD_API_KEY="rpa_..."
#   2. Build & push: bash deploy.sh build
#   3. Create endpoint: bash deploy.sh create
#   4. Test: bash deploy.sh test "Bonjour JB"
#
# Or all at once: bash deploy.sh all

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
API_KEY="${RUNPOD_API_KEY:-$(cat $SCRIPT_DIR/../../runpod.md 2>/dev/null || cat $SCRIPT_DIR/runpod.md 2>/dev/null)}"
DOCKER_IMAGE="${DOCKER_IMAGE:-dots-tts-runpod:latest}"
DOCKERHUB_USER="${DOCKERHUB_USER:-jbrivesfr}"

if [ -z "$API_KEY" ]; then
    echo "❌ No API key. Set RUNPOD_API_KEY or create runpod.md"
    exit 1
fi

# ── Build ──────────────────────────────────────────
do_build() {
    echo "📦 Building Docker image..."
    cd "$SCRIPT_DIR"
    
    # Check for voice samples
    if [ -d voices ] && [ "$(ls voices/*.wav 2>/dev/null)" ]; then
        echo "   🎤 Voice samples found: $(ls voices/*.wav | wc -l) files"
    else
        echo "   ⚠️  No voice samples in voices/ — voice cloning won't work"
    fi
    
    docker build --platform linux/amd64 -t "$DOCKER_IMAGE" .
    echo "   ✅ Image built: $DOCKER_IMAGE"
}

# ── Push ───────────────────────────────────────────
do_push() {
    local remote="${DOCKERHUB_USER}/dots-tts-runpod:latest"
    echo "📤 Pushing to Docker Hub: $remote"
    docker tag "$DOCKER_IMAGE" "$remote"
    docker push "$remote"
    echo "   ✅ Pushed: $remote"
    echo "   IMAGE_URL=$remote"
}

# ── Create Serverless Endpoint ─────────────────────
do_create() {
    local image="${1:-$DOCKERHUB_USER/dots-tts-runpod:latest}"
    
    echo "🚀 Creating RunPod Serverless endpoint..."
    
    # Create endpoint via GraphQL API
    local response=$(curl -s -X POST "https://api.runpod.io/graphql?api_key=$API_KEY" \
        -H "Content-Type: application/json" \
        -d '{
            "query": "mutation CreateEndpoint($input: EndpointInput!) { createEndpoint(input: $input) { id name templateType templateId } }",
            "variables": {
                "input": {
                    "name": "dots-tts-serverless",
                    "templateType": "CUSTOM",
                    "containerImage": "'"$image"'",
                    "gpuTypes": "NVIDIA GeForce RTX 3060",
                    "gpuCount": 1,
                    "minWorkers": 0,
                    "maxWorkers": 2,
                    "idleTimeout": 120,
                    "executionTimeout": 120,
                    "containerDiskSize": 20,
                    "env": {
                        "MODEL_DIR": "/app/model",
                        "VOICES_DIR": "/app/voices"
                    }
                }
            }
        }' 2>/dev/null)
    
    echo "$response" | python3 -m json.tool 2>/dev/null || echo "$response"
    
    # Extract endpoint ID
    local endpoint_id=$(echo "$response" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('data',{}).get('createEndpoint',{}).get('id',''))" 2>/dev/null)
    if [ -n "$endpoint_id" ]; then
        echo ""
        echo "✅ Endpoint created! ID: $endpoint_id"
        echo "   URL: https://api.runpod.ai/v2/$endpoint_id/run"
        echo ""
        echo "   Add to your config:"
        echo "   export DOTS_TTS_ENDPOINT='https://api.runpod.ai/v2/$endpoint_id/run'"
    fi
}

# ── Test ───────────────────────────────────────────
do_test() {
    local endpoint="${DOTS_TTS_ENDPOINT:-$RUNPOD_ENDPOINT}"
    local text="${1:-Bonjour JB, ceci est un test de dots.tts sur RunPod Serverless.}"
    
    if [ -z "$endpoint" ]; then
        echo "❌ Set DOTS_TTS_ENDPOINT or RUNPOD_ENDPOINT"
        exit 1
    fi
    
    echo "🧪 Testing: $endpoint"
    echo "   Text: $text"
    echo ""
    
    local response=$(curl -s -X POST "$endpoint" \
        -H "Content-Type: application/json" \
        -H "Authorization: Bearer $API_KEY" \
        -d "{\"input\": {\"text\": \"$text\", \"voice\": \"default\", \"format\": \"wav\"}}" \
        -w "\n%{http_code}" 2>/dev/null)
    
    local http_code=$(echo "$response" | tail -1)
    local body=$(echo "$response" | head -n -1)
    
    echo "   HTTP: $http_code"
    echo ""
    
    if [ "$http_code" = "200" ]; then
        echo "$body" | python3 -c "
import json, sys
d = json.load(sys.stdin)
out = d.get('output', d)
print(f'   Duration: {out.get(\"duration_s\",\"?\")}s')
print(f'   Gen time: {out.get(\"gen_time_s\",\"?\")}s')
print(f'   RTF: {out.get(\"rtf\",\"?\")}x')
print(f'   Size: {out.get(\"size_bytes\",0)/1024:.1f} KB')
print(f'   Format: {out.get(\"format\",\"?\")}')
" 2>/dev/null || echo "$body" | head -5
        echo ""
        echo "   ✅ Test successful!"
    else
        echo "   ❌ Test failed:"
        echo "$body" | head -10
    fi
}

# ── Main ───────────────────────────────────────────
case "${1:-all}" in
    build)  do_build ;;
    push)   do_push ;;
    create) do_create "$2" ;;
    test)   do_test "$2" ;;
    all)
        do_build
        echo ""
        do_push
        echo ""
        do_create
        ;;
    *)
        echo "Usage: bash deploy.sh [build|push|create|test|all]"
        echo ""
        echo "First time:"
        echo "  1. Add voice samples to voices/ (optional)"
        echo "  2. bash deploy.sh build    # Build Docker image"
        echo "  3. bash deploy.sh push     # Push to Docker Hub"
        echo "  4. bash deploy.sh create   # Create RunPod endpoint"
        echo "  5. bash deploy.sh test     # Test with a message"
        ;;
esac
