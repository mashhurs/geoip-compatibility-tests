#!/bin/bash
# Test Elasticsearch GeoIP Processor
# Usage: ./test-es-geoip.sh [ES_HOST] [ES_PORT]

ES_HOST="${1:-localhost}"
ES_PORT="${2:-9200}"
ES_URL="http://${ES_HOST}:${ES_PORT}"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_pass() { echo -e "${GREEN}[PASS]${NC} $1"; }
log_fail() { echo -e "${RED}[FAIL]${NC} $1"; }

echo "=============================================="
echo "Elasticsearch GeoIP Processor Test"
echo "Target: $ES_URL"
echo "=============================================="
echo ""

# Check ES is available
log_info "Checking Elasticsearch availability..."
ES_INFO=$(curl -s "$ES_URL" 2>/dev/null)
if [ $? -ne 0 ] || [ -z "$ES_INFO" ]; then
    log_fail "Cannot connect to Elasticsearch at $ES_URL"
    exit 1
fi

ES_VERSION=$(echo "$ES_INFO" | grep -o '"number" *: *"[^"]*"' | head -1 | cut -d'"' -f4)
log_pass "Connected to Elasticsearch $ES_VERSION"

# Check GeoIP database status
log_info "Checking GeoIP database status..."
GEOIP_STATS=$(curl -s "$ES_URL/_ingest/geoip/stats" 2>/dev/null)
if echo "$GEOIP_STATS" | grep -q "databases"; then
    log_pass "GeoIP stats endpoint available"
    echo "  Stats: $(echo "$GEOIP_STATS" | head -c 200)..."
else
    log_info "GeoIP stats not available (may need xpack.geoip.downloader.enabled=true)"
fi

echo ""

# Create test pipeline
log_info "Creating GeoIP test pipeline..."
PIPELINE_RESPONSE=$(curl -s -X PUT "$ES_URL/_ingest/pipeline/geoip-compat-test" \
    -H "Content-Type: application/json" \
    -d '{
        "description": "GeoIP compatibility test pipeline",
        "processors": [
            {
                "geoip": {
                    "field": "ip",
                    "target_field": "geoip_city",
                    "database_file": "GeoLite2-City.mmdb",
                    "ignore_missing": true
                }
            },
            {
                "geoip": {
                    "field": "ip",
                    "target_field": "geoip_asn",
                    "database_file": "GeoLite2-ASN.mmdb",
                    "ignore_missing": true
                }
            }
        ]
    }')

if echo "$PIPELINE_RESPONSE" | grep -q '"acknowledged":true'; then
    log_pass "Pipeline created successfully"
else
    log_fail "Failed to create pipeline: $PIPELINE_RESPONSE"
    # Try simpler pipeline
    log_info "Trying simpler pipeline..."
    PIPELINE_RESPONSE=$(curl -s -X PUT "$ES_URL/_ingest/pipeline/geoip-compat-test" \
        -H "Content-Type: application/json" \
        -d '{
            "description": "GeoIP compatibility test pipeline",
            "processors": [
                {
                    "geoip": {
                        "field": "ip",
                        "target_field": "geoip"
                    }
                }
            ]
        }')
    if echo "$PIPELINE_RESPONSE" | grep -q '"acknowledged":true'; then
        log_pass "Simple pipeline created"
    else
        log_fail "Cannot create GeoIP pipeline"
    fi
fi

# Delete test index if exists
curl -s -X DELETE "$ES_URL/geoip-compat-test-index" > /dev/null 2>&1

echo ""

# Test IPs
TEST_IPS=("8.8.8.8" "1.1.1.1" "93.184.216.34" "2606:4700:4700::1111")

log_info "Testing GeoIP enrichment with sample IPs..."
for IP in "${TEST_IPS[@]}"; do
    DOC_RESPONSE=$(curl -s -X POST "$ES_URL/geoip-compat-test-index/_doc?pipeline=geoip-compat-test" \
        -H "Content-Type: application/json" \
        -d "{\"ip\": \"$IP\", \"test\": true}")
    
    if echo "$DOC_RESPONSE" | grep -q '"result":"created"'; then
        echo -e "  ${GREEN}✓${NC} $IP indexed"
    else
        echo -e "  ${RED}✗${NC} $IP failed: $(echo "$DOC_RESPONSE" | head -c 100)"
    fi
done

echo ""

# Verify enrichment
log_info "Verifying GeoIP data in indexed documents..."
sleep 1

SEARCH_RESPONSE=$(curl -s "$ES_URL/geoip-compat-test-index/_search?size=10")

# Check for geoip fields
if echo "$SEARCH_RESPONSE" | grep -q '"geoip'; then
    log_pass "GeoIP data found in documents"
    
    # Extract and display some fields
    echo ""
    echo "Sample enriched data:"
    echo "$SEARCH_RESPONSE" | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    for hit in data.get('hits', {}).get('hits', [])[:3]:
        src = hit.get('_source', {})
        ip = src.get('ip', 'N/A')
        geoip = src.get('geoip_city') or src.get('geoip', {})
        country = geoip.get('country_iso_code') or geoip.get('country_code2', 'N/A')
        city = geoip.get('city_name', 'N/A')
        print(f'  {ip} -> {country}/{city}')
except:
    print('  (Could not parse response)')
" 2>/dev/null || echo "  (Install python3 for detailed output)"
else
    log_fail "No GeoIP data found"
    echo "Response: $(echo "$SEARCH_RESPONSE" | head -c 500)"
fi

echo ""

# Cleanup
log_info "Cleaning up test resources..."
curl -s -X DELETE "$ES_URL/geoip-compat-test-index" > /dev/null 2>&1
curl -s -X DELETE "$ES_URL/_ingest/pipeline/geoip-compat-test" > /dev/null 2>&1
log_pass "Cleanup complete"

echo ""
echo "=============================================="
echo "Test Complete"
echo "=============================================="
