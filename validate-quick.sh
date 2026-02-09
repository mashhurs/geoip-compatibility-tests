#!/bin/bash
# Quick GeoIP Validation Script
# Validates the geoip-filter plugin without Docker

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GEOIP_PLUGIN_DIR="$SCRIPT_DIR/../repos/logstash-filter-geoip"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_pass() { echo -e "${GREEN}[PASS]${NC} $1"; }
log_fail() { echo -e "${RED}[FAIL]${NC} $1"; }

PASS=0
FAIL=0

echo "=============================================="
echo "GeoIP Filter Quick Validation"
echo "=============================================="
echo ""

# Step 1: Check build.gradle versions
log_info "Step 1: Checking GeoIP library versions..."
cd "$GEOIP_PLUGIN_DIR"

GEOIP2_VER=$(grep "maxmindGeoip2Version" build.gradle | head -1 | grep -oE "[0-9]+\.[0-9]+\.[0-9]+")
MAXMIND_DB_VER=$(grep "maxmindDbVersion" build.gradle | head -1 | grep -oE "[0-9]+\.[0-9]+\.[0-9]+")
JAVA_VER=$(grep -A2 "^java {" build.gradle | grep "sourceCompatibility" | grep -oE "VERSION_[0-9_]+")

echo "  GeoIP2 version: $GEOIP2_VER"
echo "  MaxMind DB version: $MAXMIND_DB_VER"
echo "  Java compatibility: $JAVA_VER"

# Validate versions
if [[ "$GEOIP2_VER" =~ ^4\. ]]; then
    log_pass "GeoIP2 is version 4.x (compatible with ES 8.x/9.x)"
    ((PASS++))
elif [[ "$GEOIP2_VER" =~ ^5\. ]]; then
    log_pass "GeoIP2 is version 5.x (latest)"
    ((PASS++))
else
    log_fail "GeoIP2 version $GEOIP2_VER may be outdated"
    ((FAIL++))
fi

if [[ "$JAVA_VER" == "VERSION_11" || "$JAVA_VER" == "VERSION_17" || "$JAVA_VER" == "VERSION_21" ]]; then
    log_pass "Java version $JAVA_VER is compatible"
    ((PASS++))
else
    log_fail "Java version $JAVA_VER may not be compatible with GeoIP2 4.x+"
    ((FAIL++))
fi

echo ""

# Step 2: Run Gradle build and tests
log_info "Step 2: Running Gradle build and tests..."
if ./gradlew clean test 2>&1 | tee /tmp/geoip_gradle_test.log | tail -20; then
    GRADLE_EXIT=${PIPESTATUS[0]}
    if [ $GRADLE_EXIT -eq 0 ]; then
        log_pass "Gradle tests passed"
        ((PASS++))
    else
        log_fail "Gradle tests failed (exit code: $GRADLE_EXIT)"
        ((FAIL++))
    fi
else
    log_fail "Gradle build failed"
    ((FAIL++))
fi

echo ""

# Step 3: Build vendor artifacts
log_info "Step 3: Building vendor artifacts..."
if ./gradlew vendor 2>&1 | tail -5; then
    log_pass "Vendor build successful"
    ((PASS++))
else
    log_fail "Vendor build failed"
    ((FAIL++))
fi

echo ""

# Step 4: Run RSpec tests
log_info "Step 4: Running RSpec tests..."
if bundle exec rspec spec/filters/geoip* 2>&1 | tee /tmp/geoip_rspec.log | tail -20; then
    RSPEC_EXIT=${PIPESTATUS[0]}
    if [ $RSPEC_EXIT -eq 0 ]; then
        log_pass "RSpec tests passed"
        ((PASS++))
        
        # Count tests
        RSPEC_SUMMARY=$(tail -5 /tmp/geoip_rspec.log | grep "examples")
        echo "  $RSPEC_SUMMARY"
    else
        log_fail "RSpec tests failed"
        ((FAIL++))
    fi
else
    log_fail "RSpec execution failed"
    ((FAIL++))
fi

echo ""

# Step 5: Verify key files exist
log_info "Step 5: Verifying build artifacts..."

GEOIP_JAR=$(find vendor -name "geoip2-*.jar" 2>/dev/null | head -1)
MAXMIND_JAR=$(find vendor -name "maxmind-db-*.jar" 2>/dev/null | head -1)
FILTER_JAR=$(find vendor -name "logstash-filter-geoip-*.jar" 2>/dev/null | head -1)

if [ -n "$GEOIP_JAR" ]; then
    log_pass "GeoIP2 JAR found: $(basename $GEOIP_JAR)"
    ((PASS++))
else
    log_fail "GeoIP2 JAR not found"
    ((FAIL++))
fi

if [ -n "$MAXMIND_JAR" ]; then
    log_pass "MaxMind DB JAR found: $(basename $MAXMIND_JAR)"
    ((PASS++))
else
    log_fail "MaxMind DB JAR not found"
    ((FAIL++))
fi

if [ -n "$FILTER_JAR" ]; then
    log_pass "Filter JAR found: $(basename $FILTER_JAR)"
    ((PASS++))
else
    log_fail "Filter JAR not found"
    ((FAIL++))
fi

echo ""

# Step 6: Check for deprecation warnings
log_info "Step 6: Checking for critical deprecation warnings..."

DEPRECATION_COUNT=$(grep -c "deprecated" /tmp/geoip_gradle_test.log 2>/dev/null || echo "0")
echo "  Deprecation mentions in build log: $DEPRECATION_COUNT"

# Check for specific 4.x deprecations (getMetroCode)
if grep -q "getMetroCode" /tmp/geoip_gradle_test.log 2>/dev/null; then
    log_info "Note: getMetroCode() is deprecated in GeoIP2 4.3.0+ (still functional)"
fi

# Check for removed methods (5.x)
if grep -q "cannot find symbol.*getMetroCode" /tmp/geoip_gradle_test.log 2>/dev/null; then
    log_fail "getMetroCode() removed - using GeoIP2 5.x without code update"
    ((FAIL++))
fi

echo ""
echo "=============================================="
echo "Validation Summary"
echo "=============================================="
echo -e "Passed: ${GREEN}$PASS${NC}"
echo -e "Failed: ${RED}$FAIL${NC}"
echo ""

if [ $FAIL -eq 0 ]; then
    echo -e "${GREEN}All validations passed!${NC}"
    echo ""
    echo "The logstash-filter-geoip plugin is ready for testing with:"
    echo "  - Elasticsearch 8.19.x"
    echo "  - Elasticsearch 9.3.x"
    echo "  - Logstash 8.19.x"
    echo "  - Logstash 9.3.x"
    exit 0
else
    echo -e "${RED}Some validations failed.${NC}"
    echo "Please review the failures above."
    exit 1
fi
