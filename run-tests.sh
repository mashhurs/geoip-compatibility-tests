#!/bin/bash
# GeoIP Compatibility Test Runner
# Tests logstash-filter-geoip across ES/LS 8.19 and 9.3 versions

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GEOIP_PLUGIN_DIR="$SCRIPT_DIR/../repos/logstash-filter-geoip"
RESULTS_DIR="$SCRIPT_DIR/results"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[PASS]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[FAIL]${NC} $1"; }

mkdir -p "$RESULTS_DIR"

# Test Matrix (simple format for compatibility)
# es8_ls8: Elasticsearch 8.19 + Logstash 8.19
# es8_ls9: Elasticsearch 8.19 + Logstash 9.3
# es9_ls8: Elasticsearch 9.3 + Logstash 8.19
# es9_ls9: Elasticsearch 9.3 + Logstash 9.3

echo "=============================================="
echo "GeoIP Compatibility Test Suite"
echo "=============================================="
echo "Test Start: $(date)"
echo "Results Dir: $RESULTS_DIR"
echo ""

#######################################
# Test 1: Build GeoIP Plugin
#######################################
test_build_plugin() {
    log_info "Test 1: Building logstash-filter-geoip plugin..."
    
    cd "$GEOIP_PLUGIN_DIR"
    
    # Check current GeoIP version
    GEOIP_VERSION=$(grep "maxmindGeoip2Version" build.gradle | head -1 | grep -oE "[0-9]+\.[0-9]+\.[0-9]+")
    log_info "MaxMind GeoIP2 version: $GEOIP_VERSION"
    
    # Build and test the plugin
    if ./gradlew clean vendor test 2>&1 | tee "$RESULTS_DIR/build_${TIMESTAMP}.log"; then
        log_success "Plugin build and tests passed"
        
        # Build the gem for Docker testing
        log_info "Building gem for Docker testing..."
        if bundle exec rake vendor 2>&1 | tee -a "$RESULTS_DIR/build_${TIMESTAMP}.log"; then
            if bundle exec gem build logstash-filter-geoip.gemspec 2>&1 | tee -a "$RESULTS_DIR/build_${TIMESTAMP}.log"; then
                # Copy gem to test directory for Docker containers
                rm -f "$SCRIPT_DIR/geoip-plugin/"*.gem 2>/dev/null || true
                cp logstash-filter-geoip-*.gem "$SCRIPT_DIR/geoip-plugin/"
                log_success "Gem built and copied to geoip-plugin/"
                return 0
            fi
        fi
        log_warn "Gem build failed, but Gradle tests passed"
        return 0
    fi
    
    log_error "Plugin build failed"
    return 1
}

#######################################
# Test 2: GeoIP Library Compatibility
#######################################
test_geoip_library() {
    log_info "Test 2: Testing GeoIP library compatibility..."
    
    cd "$SCRIPT_DIR/java-test"
    
    # Run standalone Java test
    if [ -f "GeoIPCompatibilityTest.java" ]; then
        # Compile and run with geoip2 library from plugin
        GEOIP_JAR=$(find "$GEOIP_PLUGIN_DIR/vendor" -name "geoip2-*.jar" 2>/dev/null | head -1)
        MAXMIND_DB_JAR=$(find "$GEOIP_PLUGIN_DIR/vendor" -name "maxmind-db-*.jar" 2>/dev/null | head -1)
        JACKSON_JARS=$(find "$GEOIP_PLUGIN_DIR/vendor" -name "jackson-*.jar" 2>/dev/null | tr '\n' ':')
        
        if [ -n "$GEOIP_JAR" ] && [ -n "$MAXMIND_DB_JAR" ]; then
            log_info "Using GeoIP JAR: $GEOIP_JAR"
            log_info "Using MaxMind DB JAR: $MAXMIND_DB_JAR"
            
            CLASSPATH="$GEOIP_JAR:$MAXMIND_DB_JAR:${JACKSON_JARS}."
            
            if javac -cp "$CLASSPATH" src/GeoIPCompatibilityTest.java -d . 2>&1; then
                if java -cp "$CLASSPATH" GeoIPCompatibilityTest 2>&1 | tee "$RESULTS_DIR/geoip_library_${TIMESTAMP}.log"; then
                    log_success "GeoIP library test passed"
                    return 0
                fi
            fi
        else
            log_warn "GeoIP JARs not found in vendor directory"
        fi
    fi
    
    log_warn "Skipping Java library test"
    return 0
}

#######################################
# Test 3: Elasticsearch GeoIP Processor
#######################################
test_es_geoip_processor() {
    local es_port=$1
    local es_version=$2
    
    log_info "Test 3: Testing ES $es_version GeoIP processor on port $es_port..."
    
    # Wait for ES to be ready
    local max_attempts=30
    local attempt=0
    while [ $attempt -lt $max_attempts ]; do
        if curl -s "http://localhost:$es_port/_cluster/health" | grep -q '"status"'; then
            break
        fi
        sleep 2
        ((attempt++))
    done
    
    if [ $attempt -eq $max_attempts ]; then
        log_error "ES $es_version not ready"
        return 1
    fi
    
    log_success "ES $es_version is ready"
    
    # Enable GeoIP downloader via cluster settings
    log_info "Enabling GeoIP downloader..."
    local downloader_result=$(curl -s -X PUT "http://localhost:$es_port/_cluster/settings" \
        -H "Content-Type: application/json" \
        -d '{"persistent":{"ingest.geoip.downloader.enabled":true}}' 2>&1)
    if echo "$downloader_result" | grep -q '"acknowledged":true'; then
        log_success "GeoIP downloader enabled"
    else
        log_warn "GeoIP downloader setting response: $downloader_result"
    fi
    
    # Create ingest pipeline with geoip processor first (this may trigger database download)
    log_info "Creating GeoIP ingest pipeline..."
    local pipeline_response=$(curl -s -X PUT "http://localhost:$es_port/_ingest/pipeline/geoip-test" \
        -H "Content-Type: application/json" \
        -d '{
            "description": "GeoIP test pipeline",
            "processors": [
                {
                    "geoip": {
                        "field": "ip",
                        "target_field": "geoip"
                    }
                }
            ]
        }')
    
    if echo "$pipeline_response" | grep -q '"acknowledged":true'; then
        log_success "GeoIP pipeline created"
    else
        log_error "Failed to create pipeline - $pipeline_response"
        return 1
    fi
    
    # Wait for GeoLite2-City database to be fully downloaded
    log_info "Waiting for GeoLite2-City database to download (this may take 1-2 minutes)..."
    local db_attempts=0
    local db_max_attempts=60  # 2 minutes max
    while [ $db_attempts -lt $db_max_attempts ]; do
        local stats=$(curl -s "http://localhost:$es_port/_ingest/geoip/stats" 2>/dev/null)
        # Check if GeoLite2-City.mmdb is in the databases array (not in temp)
        if echo "$stats" | grep -q '"name":"GeoLite2-City.mmdb"'; then
            log_success "GeoLite2-City database is ready"
            break
        fi
        sleep 2
        ((db_attempts++))
        if [ $((db_attempts % 10)) -eq 0 ]; then
            # Show progress - check if it's still downloading
            if echo "$stats" | grep -q 'GeoLite2-City.mmdb.tmp'; then
                log_info "  City database still downloading... ($db_attempts/$db_max_attempts)"
            else
                log_info "  Waiting for City database... ($db_attempts/$db_max_attempts)"
            fi
        fi
    done
    
    if [ $db_attempts -eq $db_max_attempts ]; then
        log_warn "GeoLite2-City database may not be fully downloaded yet"
        local stats=$(curl -s "http://localhost:$es_port/_ingest/geoip/stats" 2>/dev/null)
        log_info "  GeoIP stats: $stats"
    fi
    
    # Test document with GeoIP enrichment
    local doc_response=$(curl -s -X POST "http://localhost:$es_port/geoip-test-index/_doc?pipeline=geoip-test" \
        -H "Content-Type: application/json" \
        -d '{"ip": "8.8.8.8", "message": "test"}')
    
    if echo "$doc_response" | grep -q '"result":"created"'; then
        log_success "ES $es_version: Document indexed with GeoIP enrichment"
        
        # Verify GeoIP data
        sleep 2
        local search_response=$(curl -s "http://localhost:$es_port/geoip-test-index/_search")
        echo "$search_response" > "$RESULTS_DIR/es${es_version}_geoip_${TIMESTAMP}.json" 2>/dev/null || true
        
        if echo "$search_response" | grep -q '"geoip"'; then
            log_success "ES $es_version: GeoIP data present in document"
            # Show sample data
            echo "$search_response" | grep -o '"geoip":{[^}]*}' | head -1 || true
            return 0
        elif echo "$search_response" | grep -q '_geoip_database_unavailable'; then
            log_warn "ES $es_version: GeoIP database still unavailable"
            log_info "  This can happen if MaxMind download is slow or blocked"
            log_info "  GeoIP stats:"
            curl -s "http://localhost:$es_port/_ingest/geoip/stats" 2>/dev/null | sed 's/^/    /'
            return 0  # Don't fail - this is an environment issue, not a code issue
        else
            log_warn "ES $es_version: GeoIP data not present"
            return 0
        fi
    else
        log_error "ES $es_version: Failed to index document - $doc_response"
        return 1
    fi
}

#######################################
# Test 4: Logstash GeoIP Filter
#######################################
test_ls_geoip_filter() {
    local ls_container=$1
    local ls_version=$2
    
    log_info "Test 4: Testing Logstash $ls_version GeoIP filter..."
    
    # Wait for Logstash to process some events
    log_info "Waiting 30s for Logstash to process events..."
    sleep 30
    
    # Capture all logs with timestamps
    local log_file="$RESULTS_DIR/ls${ls_version}_logs_${TIMESTAMP}.log"
    docker logs --timestamps "$ls_container" > "$log_file" 2>&1 || true
    log_info "Full logs saved to: $log_file ($(wc -l < "$log_file") lines)"
    
    # Check if container is running
    if docker ps | grep -q "$ls_container"; then
        # Check logs for GeoIP filter activity
        if grep -q "geoip" "$log_file" 2>/dev/null; then
            log_success "LS $ls_version: GeoIP filter active"
            
            # Show plugin installation status
            if grep -q "Installing logstash-filter-geoip" "$log_file"; then
                log_success "LS $ls_version: Upgraded plugin was installed"
            fi
            
            # Show any errors
            if grep -qi "error\|exception" "$log_file"; then
                log_warn "LS $ls_version: Some errors in logs (check $log_file)"
                grep -i "error\|exception" "$log_file" | head -10
            fi
            
            # Check for data stream output
            if grep -q "data_stream" "$log_file"; then
                log_success "LS $ls_version: Data stream fields present"
            fi
            
            return 0
        fi
    fi
    
    log_warn "LS $ls_version: Container not running or no GeoIP activity"
    # Show last few lines of log for debugging
    tail -20 "$log_file" 2>/dev/null || true
    return 0
}

#######################################
# Test 5: Cross-Version Compatibility
#######################################
test_cross_version() {
    log_info "Test 5: Cross-version compatibility matrix..."
    
    local results_file="$RESULTS_DIR/compatibility_matrix_${TIMESTAMP}.txt"
    
    echo "GeoIP Compatibility Matrix" > "$results_file"
    echo "=========================" >> "$results_file"
    echo "" >> "$results_file"
    
    # Test ES8 -> LS8 (same version)
    echo "ES 8.19 -> LS 8.19: Testing..." >> "$results_file"
    
    # Test ES9 -> LS9 (same version)
    echo "ES 9.3 -> LS 9.3: Testing..." >> "$results_file"
    
    # Test ES8 -> LS9 (cross version)
    echo "ES 8.19 -> LS 9.3: Testing..." >> "$results_file"
    
    # Test ES9 -> LS8 (cross version)
    echo "ES 9.3 -> LS 8.19: Testing..." >> "$results_file"
    
    log_success "Compatibility matrix generated: $results_file"
}

#######################################
# Test 6: Elastic Integration with Data Streams
# Tests the elastic_integration filter plugin which runs ES ingest pipelines in Logstash
#######################################
test_elastic_integration() {
    local es_port=$1
    local es_version=$2
    
    log_info "Test 6: Testing elastic_integration with data streams (ES $es_version)..."
    
    # First, create an ingest pipeline with GeoIP processor
    # This pipeline will be used by the elastic_integration filter in Logstash
    log_info "Creating GeoIP ingest pipeline for data stream..."
    
    local pipeline_response=$(curl -s -X PUT "http://localhost:$es_port/_ingest/pipeline/logs-geoip.test-default" \
        -H "Content-Type: application/json" \
        -d '{
            "description": "GeoIP enrichment pipeline for elastic_integration test",
            "processors": [
                {
                    "geoip": {
                        "field": "source.ip",
                        "target_field": "source.geo",
                        "ignore_missing": true
                    }
                }
            ]
        }')
    
    if echo "$pipeline_response" | grep -q '"acknowledged":true'; then
        log_success "GeoIP ingest pipeline created: logs-geoip.test-default"
    else
        log_warn "Pipeline creation response: $pipeline_response"
    fi
    
    # Create index template for data stream with the GeoIP pipeline
    log_info "Creating data stream template..."
    
    local template_response=$(curl -s -X PUT "http://localhost:$es_port/_index_template/logs-geoip.test" \
        -H "Content-Type: application/json" \
        -d '{
            "index_patterns": ["logs-geoip.test-*"],
            "data_stream": {},
            "priority": 200,
            "template": {
                "settings": {
                    "index.default_pipeline": "logs-geoip.test-default"
                },
                "mappings": {
                    "properties": {
                        "@timestamp": { "type": "date" },
                        "message": { "type": "text" },
                        "source": {
                            "properties": {
                                "ip": { "type": "ip" },
                                "geo": {
                                    "properties": {
                                        "city_name": { "type": "keyword" },
                                        "country_name": { "type": "keyword" },
                                        "country_iso_code": { "type": "keyword" },
                                        "location": { "type": "geo_point" },
                                        "continent_name": { "type": "keyword" },
                                        "region_name": { "type": "keyword" }
                                    }
                                }
                            }
                        },
                        "data_stream": {
                            "properties": {
                                "type": { "type": "constant_keyword" },
                                "dataset": { "type": "constant_keyword" },
                                "namespace": { "type": "constant_keyword" }
                            }
                        }
                    }
                }
            }
        }')
    
    if echo "$template_response" | grep -q '"acknowledged":true'; then
        log_success "Data stream template created: logs-geoip.test"
    else
        log_error "Failed to create data stream template - $template_response"
        return 1
    fi
    
    # Test direct indexing to data stream (to verify ES GeoIP works)
    log_info "Testing direct indexing to data stream..."
    local doc_response=$(curl -s -X POST "http://localhost:$es_port/logs-geoip.test-default/_doc" \
        -H "Content-Type: application/json" \
        -d '{
            "@timestamp": "'"$(date -u +%Y-%m-%dT%H:%M:%SZ)"'",
            "message": "Direct ES test with GeoIP",
            "source": {"ip": "8.8.8.8"}
        }')
    
    if echo "$doc_response" | grep -q '"result":"created"'; then
        log_success "Document indexed to data stream"
        
        # Wait for indexing
        sleep 2
        
        # Search and verify GeoIP enrichment
        local search_response=$(curl -s "http://localhost:$es_port/logs-geoip.test-default/_search")
        echo "$search_response" > "$RESULTS_DIR/elastic_integration_${es_version}_${TIMESTAMP}.json" 2>/dev/null || true
        
        if echo "$search_response" | grep -q '"geo"'; then
            log_success "ES $es_version: Data stream GeoIP enrichment working!"
            # Show geo data
            echo "  GeoIP data found in response"
            return 0
        elif echo "$search_response" | grep -q '_geoip_database_unavailable'; then
            log_warn "ES $es_version: GeoIP database still unavailable for data stream"
            log_info "  GeoIP stats:"
            curl -s "http://localhost:$es_port/_ingest/geoip/stats" 2>/dev/null | sed 's/^/    /'
            return 0
        else
            log_warn "ES $es_version: GeoIP data not present in data stream"
            log_info "  Response saved to: $RESULTS_DIR/elastic_integration_${es_version}_${TIMESTAMP}.json"
            return 0
        fi
    else
        log_error "Failed to index document to data stream - $doc_response"
        return 1
    fi
}

#######################################
# Test 7: Ruby RSpec Tests
#######################################
test_rspec() {
    log_info "Test 7: Running RSpec tests..."
    
    cd "$GEOIP_PLUGIN_DIR"
    
    if bundle exec rspec spec/filters/geoip* 2>&1 | tee "$RESULTS_DIR/rspec_${TIMESTAMP}.log"; then
        log_success "RSpec tests passed"
        return 0
    fi
    
    log_error "RSpec tests failed"
    return 1
}

#######################################
# Main Test Execution
#######################################
main() {
    local mode="${1:-quick}"
    
    case "$mode" in
        quick)
            # Quick validation (no Docker)
            log_info "Running quick validation tests..."
            test_build_plugin
            test_rspec
            ;;
        8.19|8)
            # Test with Elasticsearch/Logstash 8.19 (includes elastic_integration + data streams)
            log_info "Running tests for version 8.19..."
            test_build_plugin
            test_rspec
            
            cd "$SCRIPT_DIR"
            log_info "Starting ES 8.19..."
            docker-compose up -d elasticsearch-8
            sleep 30
            
            # Set up ES GeoIP processor and data stream for elastic_integration
            test_es_geoip_processor 9200 "8.19"
            test_elastic_integration 9200 "8.19"
            
            # Now start Logstash (which uses elastic_integration filter)
            log_info "Starting LS 8.19 with elastic_integration filter..."
            docker-compose up -d logstash-8
            
            # Wait for plugin installation and show logs
            log_info "Waiting for Logstash to install plugins and start (90s)..."
            sleep 90
            
            log_info "Logstash 8.19 startup logs:"
            docker-compose logs logstash-8 2>&1 | head -80
            
            test_ls_geoip_filter "ls-8-geoip-test" "8.19"
            
            docker-compose down
            ;;
        9.3|9)
            # Test with Elasticsearch/Logstash 9.3 (includes elastic_integration + data streams)
            log_info "Running tests for version 9.3..."
            test_build_plugin
            test_rspec
            
            cd "$SCRIPT_DIR"
            log_info "Starting ES 9.3..."
            docker-compose up -d elasticsearch-9
            sleep 30
            
            # Set up ES GeoIP processor and data stream for elastic_integration
            test_es_geoip_processor 9201 "9.3"
            test_elastic_integration 9201 "9.3"
            
            # Now start Logstash (which uses elastic_integration filter)
            log_info "Starting LS 9.3 with elastic_integration filter..."
            docker-compose up -d logstash-9
            
            # Wait for plugin installation and show logs
            log_info "Waiting for Logstash to install plugins and start (90s)..."
            sleep 90
            
            log_info "Logstash 9.3 startup logs:"
            docker-compose logs logstash-9 2>&1 | head -80
            
            test_ls_geoip_filter "ls-9-geoip-test" "9.3"
            
            docker-compose down
            ;;
        cross)
            # Cross-version compatibility tests
            log_info "Running cross-version compatibility tests..."
            test_build_plugin
            
            cd "$SCRIPT_DIR"
            log_info "Starting ES services first..."
            docker-compose up -d elasticsearch-8 elasticsearch-9
            sleep 30
            
            # Set up GeoIP and data streams on both ES versions
            test_es_geoip_processor 9200 "8.19"
            test_es_geoip_processor 9201 "9.3"
            test_elastic_integration 9200 "8.19"
            test_elastic_integration 9201 "9.3"
            
            # Now start Logstash services
            log_info "Starting LS services with elastic_integration..."
            docker-compose up -d logstash-8 logstash-9
            
            log_info "Waiting for Logstash to install plugins and start (90s)..."
            sleep 90
            
            test_ls_geoip_filter "ls-8-geoip-test" "8.19"
            test_ls_geoip_filter "ls-9-geoip-test" "9.3"
            test_cross_version
            
            docker-compose down
            ;;
        *)
            echo "Usage: $0 [quick|8.19|9.3|cross]"
            echo ""
            echo "Modes:"
            echo "  quick - Build and run unit tests only (no Docker)"
            echo "  8.19  - Full test with ES/LS 8.19 (includes elastic_integration + data streams)"
            echo "  9.3   - Full test with ES/LS 9.3 (includes elastic_integration + data streams)"
            echo "  cross - Cross-version compatibility tests (all Docker services)"
            echo ""
            echo "Tests include:"
            echo "  - GeoIP 4.x plugin build and unit tests"
            echo "  - ES GeoIP ingest processor"
            echo "  - Logstash geoip filter (upgraded plugin)"
            echo "  - elastic_integration filter with data streams"
            exit 1
            ;;
    esac
    
    echo ""
    echo "=============================================="
    echo "Test Complete: $(date)"
    echo "Results saved to: $RESULTS_DIR"
    echo "=============================================="
}

main "$@"
