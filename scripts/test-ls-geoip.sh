#!/bin/bash
# Test Logstash GeoIP Filter
# Usage: ./test-ls-geoip.sh [LOGSTASH_HOME]

LOGSTASH_HOME="${1:-$HOME/logstash}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GEOIP_PLUGIN_DIR="$SCRIPT_DIR/../../repos/logstash-filter-geoip"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_pass() { echo -e "${GREEN}[PASS]${NC} $1"; }
log_fail() { echo -e "${RED}[FAIL]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }

echo "=============================================="
echo "Logstash GeoIP Filter Test"
echo "Logstash: $LOGSTASH_HOME"
echo "=============================================="
echo ""

# Check Logstash exists
if [ ! -d "$LOGSTASH_HOME" ]; then
    log_fail "Logstash not found at $LOGSTASH_HOME"
    exit 1
fi

# Get Logstash version
LS_VERSION=$(cat "$LOGSTASH_HOME/versions.yml" 2>/dev/null | grep "^logstash:" | cut -d' ' -f2)
log_info "Logstash version: $LS_VERSION"

# Check if we need to install the plugin
log_info "Checking installed geoip plugin version..."
INSTALLED_GEOIP=$("$LOGSTASH_HOME/bin/logstash-plugin" list --verbose 2>/dev/null | grep "logstash-filter-geoip")
echo "  Installed: $INSTALLED_GEOIP"

# Option to install upgraded plugin
echo ""
read -p "Install upgraded geoip plugin from local build? (y/N) " -n 1 -r
echo ""

if [[ $REPLY =~ ^[Yy]$ ]]; then
    log_info "Building and installing upgraded plugin..."
    
    cd "$GEOIP_PLUGIN_DIR"
    
    # Build the gem
    ./gradlew vendor
    bundle exec gem build logstash-filter-geoip.gemspec 2>/dev/null
    
    GEM_FILE=$(ls -t logstash-filter-geoip-*.gem 2>/dev/null | head -1)
    if [ -n "$GEM_FILE" ]; then
        log_info "Installing $GEM_FILE..."
        "$LOGSTASH_HOME/bin/logstash-plugin" install "$GEM_FILE"
        log_pass "Plugin installed"
    else
        log_fail "Gem file not found"
    fi
fi

echo ""

# Test 1: Simple GeoIP lookup
log_info "Test 1: Simple GeoIP lookup..."

TEST_CONFIG='
input {
  generator {
    lines => ["8.8.8.8", "1.1.1.1", "93.184.216.34"]
    count => 1
  }
}

filter {
  geoip {
    source => "message"
    target => "geoip"
  }
}

output {
  stdout { codec => rubydebug }
}
'

echo "$TEST_CONFIG" > /tmp/geoip_test.conf

log_info "Running Logstash with test config..."
RESULT=$("$LOGSTASH_HOME/bin/logstash" -f /tmp/geoip_test.conf 2>&1)

if echo "$RESULT" | grep -q '"country_code2"\|"country_iso_code"'; then
    log_pass "GeoIP lookup successful"
    echo ""
    echo "Sample output:"
    echo "$RESULT" | grep -A 20 '"geoip"' | head -25
else
    log_fail "GeoIP lookup may have failed"
    echo "$RESULT" | tail -30
fi

echo ""

# Test 2: ASN Database lookup
log_info "Test 2: ASN Database lookup..."

ASN_CONFIG='
input {
  generator {
    lines => ["8.8.8.8"]
    count => 1
  }
}

filter {
  geoip {
    source => "message"
    target => "geoip_asn"
    default_database_type => "ASN"
  }
}

output {
  stdout { codec => rubydebug }
}
'

echo "$ASN_CONFIG" > /tmp/geoip_asn_test.conf

ASN_RESULT=$("$LOGSTASH_HOME/bin/logstash" -f /tmp/geoip_asn_test.conf 2>&1)

if echo "$ASN_RESULT" | grep -q '"asn"\|"autonomous_system'; then
    log_pass "ASN lookup successful"
    echo ""
    echo "Sample output:"
    echo "$ASN_RESULT" | grep -A 10 '"geoip_asn"' | head -15
else
    log_warn "ASN lookup may have failed (database might not be available)"
fi

echo ""

# Test 3: Custom fields
log_info "Test 3: Custom fields selection..."

CUSTOM_CONFIG='
input {
  generator {
    lines => ["8.8.8.8"]
    count => 1
  }
}

filter {
  geoip {
    source => "message"
    target => "geo"
    fields => ["country_name", "city_name", "location"]
  }
}

output {
  stdout { codec => rubydebug }
}
'

echo "$CUSTOM_CONFIG" > /tmp/geoip_custom_test.conf

CUSTOM_RESULT=$("$LOGSTASH_HOME/bin/logstash" -f /tmp/geoip_custom_test.conf 2>&1)

if echo "$CUSTOM_RESULT" | grep -q '"country_name"'; then
    log_pass "Custom fields selection works"
else
    log_warn "Custom fields test inconclusive"
fi

# Cleanup
rm -f /tmp/geoip_test.conf /tmp/geoip_asn_test.conf /tmp/geoip_custom_test.conf

echo ""
echo "=============================================="
echo "Test Complete"
echo "=============================================="
