# GeoIP Compatibility Test Matrix

## Overview

This document defines the test matrix for validating `logstash-filter-geoip` compatibility across Elasticsearch and Logstash versions 8.19 and 9.3.

## Version Matrix

| Component | Version 8.x | Version 9.x |
|-----------|-------------|-------------|
| Elasticsearch | 8.19.0 | 9.3.0 |
| Logstash | 8.19.0 | 9.3.0 |
| logstash-filter-geoip | Current (upgraded) | Current (upgraded) |
| logstash-filter-elastic_integration | Compatible | Compatible |

## GeoIP Library Versions

| Library | Version 2.x (Original) | Version 4.x (Upgrade) | Version 5.x (Latest) |
|---------|------------------------|----------------------|----------------------|
| com.maxmind.geoip2:geoip2 | 2.17.0 | 4.4.0 | 5.0.2 |
| com.maxmind.db:maxmind-db | 2.1.0 | 3.1.1 | 4.0.2 |
| Min Java Version | 1.8 | 11 | 17 |

## Test Scenarios

### Scenario 1: ES 8.19 + LS 8.19 (Baseline)
- **Expected**: Full compatibility
- **Tests**:
  - [ ] GeoIP filter processes IPs correctly
  - [ ] City database lookup works
  - [ ] ASN database lookup works
  - [ ] elastic_integration filter uses ES GeoIP processor
  - [ ] Database management integration works

### Scenario 2: ES 9.3 + LS 9.3 (Latest)
- **Expected**: Full compatibility
- **Tests**:
  - [ ] GeoIP filter processes IPs correctly
  - [ ] City database lookup works
  - [ ] ASN database lookup works
  - [ ] elastic_integration filter uses ES GeoIP processor
  - [ ] Database management integration works

### Scenario 3: ES 8.19 + LS 9.3 (Cross-version)
- **Expected**: Compatible with potential warnings
- **Tests**:
  - [ ] GeoIP filter processes IPs correctly
  - [ ] elastic_integration can connect to ES 8.19
  - [ ] No breaking changes in GeoIP data format

### Scenario 4: ES 9.3 + LS 8.19 (Cross-version)
- **Expected**: Compatible with potential warnings
- **Tests**:
  - [ ] GeoIP filter processes IPs correctly
  - [ ] elastic_integration can connect to ES 9.3
  - [ ] No breaking changes in GeoIP data format

## Key API Changes to Validate

### GeoIP2 4.x Changes (from 2.x)
- [x] `getAutonomousSystemNumber()` returns `Long` instead of `Integer`
- [x] `getGeoNameId()` returns `Long` instead of `Integer`
- [x] Java 11+ required
- [x] `DeserializationException` for invalid data (instead of NPE)
- [ ] `getMetroCode()` deprecated (still works)

### GeoIP2 5.x Changes (from 4.x) - NOT USED IN 4.x UPGRADE
- Record-style accessors (`country()` instead of `getCountry()`)
- `GeoIp2Exception` is sealed
- `getMetroCode()` removed
- Java 17+ required

## Test Commands

### Quick Validation (No Docker)
```bash
cd geoip-compatibility-tests
chmod +x validate-quick.sh
./validate-quick.sh

# Or using run-tests.sh
./run-tests.sh quick
```

### Test with Version 8.19 (Docker)
```bash
cd geoip-compatibility-tests
./run-tests.sh 8.19
# or shorthand:
./run-tests.sh 8
```

### Test with Version 9.3 (Docker)
```bash
cd geoip-compatibility-tests
./run-tests.sh 9.3
# or shorthand:
./run-tests.sh 9
```

### Cross-Version Compatibility Tests (All Docker Services)
```bash
cd geoip-compatibility-tests
./run-tests.sh cross
```

### Test Against Running Elasticsearch (No Docker Startup)
```bash
# Test ES 8.19 (assumes running on port 9200)
./run-tests.sh es-8.19

# Test ES 9.3 (assumes running on port 9201)
./run-tests.sh es-9.3
```

## Elasticsearch GeoIP Processor Tests

### Create Test Pipeline
```bash
curl -X PUT "localhost:9200/_ingest/pipeline/geoip-test" -H 'Content-Type: application/json' -d'
{
  "description": "GeoIP test pipeline",
  "processors": [
    {
      "geoip": {
        "field": "ip",
        "target_field": "geo"
      }
    }
  ]
}'
```

### Test Document Enrichment
```bash
curl -X POST "localhost:9200/test-index/_doc?pipeline=geoip-test" -H 'Content-Type: application/json' -d'
{
  "ip": "8.8.8.8",
  "message": "test"
}'
```

### Verify GeoIP Data
```bash
curl -X GET "localhost:9200/test-index/_search?pretty"
```

## Logstash GeoIP Filter Tests

### Test Pipeline Configuration
```
input {
  generator {
    message => "8.8.8.8"
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
```

### Run Test
```bash
bin/logstash -e '
input { generator { message => "8.8.8.8" count => 1 } }
filter { geoip { source => "message" target => "geoip" } }
output { stdout { codec => rubydebug } }
'
```

## Expected Output Fields

### City Database
- `country_code2` / `country_iso_code`
- `country_name`
- `city_name`
- `region_name` / `region_iso_code`
- `postal_code`
- `location` (lat/lon)
- `timezone`
- `continent_code`
- `dma_code` (4.x only, deprecated)

### ASN Database
- `asn` / `autonomous_system_number`
- `as_org` / `autonomous_system_organization`
- `network`

## Known Issues

1. **DMA Code Deprecation**: `getMetroCode()` is deprecated in GeoIP2 4.3.0. Metro codes are no longer maintained by MaxMind but the field still works.

2. **ES GeoIP Database Management**: Elasticsearch manages its own GeoIP databases separately from Logstash. The databases may be at different versions.

3. **elastic_integration Plugin**: Uses Elasticsearch's internal GeoIP processor, not the Logstash filter. Database compatibility is handled by ES.

## Success Criteria

- [ ] All Gradle tests pass (70 tests)
- [ ] All RSpec tests pass (44 tests)
- [ ] No compilation errors
- [ ] No runtime exceptions during GeoIP lookups
- [ ] Output fields match expected structure
- [ ] Cross-version scenarios don't produce errors
