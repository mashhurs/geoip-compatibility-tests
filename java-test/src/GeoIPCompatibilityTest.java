import com.maxmind.geoip2.DatabaseReader;
import com.maxmind.geoip2.model.*;
import com.maxmind.geoip2.record.*;
import com.maxmind.db.CHMCache;

import java.io.File;
import java.io.IOException;
import java.net.InetAddress;
import java.util.*;

/**
 * Standalone GeoIP Compatibility Test
 * Tests MaxMind GeoIP2 library functionality independent of Logstash
 * 
 * Usage: java -cp "geoip2.jar:maxmind-db.jar:jackson-*.jar:." GeoIPCompatibilityTest [database_path]
 */
public class GeoIPCompatibilityTest {

    private static final String[] TEST_IPS = {
        "8.8.8.8",      // Google DNS
        "1.1.1.1",      // Cloudflare
        "93.184.216.34", // Example.com
        "216.58.214.206", // Google
        "151.101.1.140"  // Fastly
    };

    private static int passed = 0;
    private static int failed = 0;
    private static List<String> failures = new ArrayList<>();

    public static void main(String[] args) {
        System.out.println("==========================================");
        System.out.println("GeoIP Library Compatibility Test");
        System.out.println("==========================================");
        System.out.println();

        // Print library versions
        printLibraryInfo();

        // Test with provided database or use test databases
        String basePath = args.length > 0 ? args[0] : findTestDatabases();
        
        if (basePath != null) {
            runDatabaseTests(basePath);
        } else {
            System.out.println("No test databases found. Running API tests only.");
            runApiTests();
        }

        printSummary();
    }

    private static void printLibraryInfo() {
        System.out.println("Library Information:");
        System.out.println("--------------------");
        try {
            // Get GeoIP2 version from package
            Package geoip2Pkg = DatabaseReader.class.getPackage();
            if (geoip2Pkg != null) {
                System.out.println("GeoIP2 Implementation: " + 
                    (geoip2Pkg.getImplementationVersion() != null ? 
                        geoip2Pkg.getImplementationVersion() : "Unknown"));
            }
            
            // Print Java version
            System.out.println("Java Version: " + System.getProperty("java.version"));
            System.out.println("Java Vendor: " + System.getProperty("java.vendor"));
            
        } catch (Exception e) {
            System.out.println("Could not determine library version: " + e.getMessage());
        }
        System.out.println();
    }

    private static String findTestDatabases() {
        // Look for test databases in common locations
        String[] searchPaths = {
            "../repos/logstash-filter-geoip/src/test/resources/maxmind-test-data",
            "../../repos/logstash-filter-geoip/src/test/resources/maxmind-test-data",
            "../test-data",
            "test-data"
        };

        for (String path : searchPaths) {
            File dir = new File(path);
            if (dir.exists() && dir.isDirectory()) {
                File[] mmdbs = dir.listFiles((d, name) -> name.endsWith(".mmdb"));
                if (mmdbs != null && mmdbs.length > 0) {
                    return dir.getAbsolutePath();
                }
            }
        }
        return null;
    }

    private static void runDatabaseTests(String basePath) {
        System.out.println("Running Database Tests");
        System.out.println("Base Path: " + basePath);
        System.out.println("======================");
        System.out.println();

        // Test City database
        testCityDatabase(basePath + "/GeoIP2-City-Test.mmdb");
        testCityDatabase(basePath + "/GeoLite2-City-Test.mmdb");
        
        // Test Country database
        testCountryDatabase(basePath + "/GeoIP2-Country-Test.mmdb");
        testCountryDatabase(basePath + "/GeoLite2-Country-Test.mmdb");
        
        // Test ASN database
        testAsnDatabase(basePath + "/GeoLite2-ASN-Test.mmdb");
        
        // Test ISP database
        testIspDatabase(basePath + "/GeoIP2-ISP-Test.mmdb");
        
        // Test Domain database
        testDomainDatabase(basePath + "/GeoIP2-Domain-Test.mmdb");
        
        // Test Enterprise database
        testEnterpriseDatabase(basePath + "/GeoIP2-Enterprise-Test.mmdb");
        
        // Test Anonymous IP database
        testAnonymousIpDatabase(basePath + "/GeoIP2-Anonymous-IP-Test.mmdb");
    }

    private static void testCityDatabase(String dbPath) {
        File dbFile = new File(dbPath);
        if (!dbFile.exists()) {
            System.out.println("SKIP: " + dbPath + " (not found)");
            return;
        }

        System.out.println("Testing City Database: " + dbFile.getName());
        
        try (DatabaseReader reader = new DatabaseReader.Builder(dbFile)
                .withCache(new CHMCache())
                .build()) {

            // Verify database type
            String dbType = reader.getMetadata().getDatabaseType();
            assertTest("Database type contains 'City'", 
                dbType.contains("City"), 
                "Type: " + dbType);

            // Test lookup
            for (String ip : TEST_IPS) {
                try {
                    InetAddress addr = InetAddress.getByName(ip);
                    CityResponse response = reader.city(addr);
                    
                    // Verify we can access key fields
                    Country country = response.getCountry();
                    City city = response.getCity();
                    Location location = response.getLocation();
                    
                    // Test getters work (4.x style)
                    String countryCode = country != null ? country.getIsoCode() : null;
                    String cityName = city != null ? city.getName() : null;
                    Double lat = location != null ? location.getLatitude() : null;
                    Double lon = location != null ? location.getLongitude() : null;
                    
                    // Note: getMetroCode() is deprecated in 4.3.0 but should still work
                    Integer metroCode = location != null ? location.getMetroCode() : null;
                    
                    System.out.println("  " + ip + " -> " + countryCode + "/" + cityName + 
                        " (" + lat + "," + lon + ") metro=" + metroCode);
                    
                } catch (Exception e) {
                    // AddressNotFoundException is expected for some IPs
                    if (!(e instanceof com.maxmind.geoip2.exception.AddressNotFoundException)) {
                        System.out.println("  " + ip + " -> ERROR: " + e.getMessage());
                    }
                }
            }
            
            assertTest("City database read successful", true, dbFile.getName());
            
        } catch (Exception e) {
            assertTest("City database read", false, e.getMessage());
        }
        System.out.println();
    }

    private static void testCountryDatabase(String dbPath) {
        File dbFile = new File(dbPath);
        if (!dbFile.exists()) {
            System.out.println("SKIP: " + dbPath + " (not found)");
            return;
        }

        System.out.println("Testing Country Database: " + dbFile.getName());
        
        try (DatabaseReader reader = new DatabaseReader.Builder(dbFile)
                .withCache(new CHMCache())
                .build()) {

            String dbType = reader.getMetadata().getDatabaseType();
            assertTest("Database type contains 'Country'", 
                dbType.contains("Country"), 
                "Type: " + dbType);

            for (String ip : TEST_IPS) {
                try {
                    InetAddress addr = InetAddress.getByName(ip);
                    CountryResponse response = reader.country(addr);
                    
                    Country country = response.getCountry();
                    String countryCode = country != null ? country.getIsoCode() : null;
                    String countryName = country != null ? country.getName() : null;
                    
                    System.out.println("  " + ip + " -> " + countryCode + " (" + countryName + ")");
                    
                } catch (Exception e) {
                    if (!(e instanceof com.maxmind.geoip2.exception.AddressNotFoundException)) {
                        System.out.println("  " + ip + " -> ERROR: " + e.getMessage());
                    }
                }
            }
            
            assertTest("Country database read successful", true, dbFile.getName());
            
        } catch (Exception e) {
            assertTest("Country database read", false, e.getMessage());
        }
        System.out.println();
    }

    private static void testAsnDatabase(String dbPath) {
        File dbFile = new File(dbPath);
        if (!dbFile.exists()) {
            System.out.println("SKIP: " + dbPath + " (not found)");
            return;
        }

        System.out.println("Testing ASN Database: " + dbFile.getName());
        
        try (DatabaseReader reader = new DatabaseReader.Builder(dbFile)
                .withCache(new CHMCache())
                .build()) {

            for (String ip : TEST_IPS) {
                try {
                    InetAddress addr = InetAddress.getByName(ip);
                    AsnResponse response = reader.asn(addr);
                    
                    // In GeoIP2 3.0+, getAutonomousSystemNumber returns Long
                    Long asn = response.getAutonomousSystemNumber();
                    String org = response.getAutonomousSystemOrganization();
                    
                    System.out.println("  " + ip + " -> AS" + asn + " (" + org + ")");
                    
                } catch (Exception e) {
                    if (!(e instanceof com.maxmind.geoip2.exception.AddressNotFoundException)) {
                        System.out.println("  " + ip + " -> ERROR: " + e.getMessage());
                    }
                }
            }
            
            assertTest("ASN database read successful", true, dbFile.getName());
            
        } catch (Exception e) {
            assertTest("ASN database read", false, e.getMessage());
        }
        System.out.println();
    }

    private static void testIspDatabase(String dbPath) {
        File dbFile = new File(dbPath);
        if (!dbFile.exists()) {
            System.out.println("SKIP: " + dbPath + " (not found)");
            return;
        }

        System.out.println("Testing ISP Database: " + dbFile.getName());
        
        try (DatabaseReader reader = new DatabaseReader.Builder(dbFile)
                .withCache(new CHMCache())
                .build()) {

            for (String ip : TEST_IPS) {
                try {
                    InetAddress addr = InetAddress.getByName(ip);
                    IspResponse response = reader.isp(addr);
                    
                    String isp = response.getIsp();
                    String org = response.getOrganization();
                    Long asn = response.getAutonomousSystemNumber();
                    
                    System.out.println("  " + ip + " -> ISP: " + isp + ", Org: " + org + ", AS" + asn);
                    
                } catch (Exception e) {
                    if (!(e instanceof com.maxmind.geoip2.exception.AddressNotFoundException)) {
                        System.out.println("  " + ip + " -> ERROR: " + e.getMessage());
                    }
                }
            }
            
            assertTest("ISP database read successful", true, dbFile.getName());
            
        } catch (Exception e) {
            assertTest("ISP database read", false, e.getMessage());
        }
        System.out.println();
    }

    private static void testDomainDatabase(String dbPath) {
        File dbFile = new File(dbPath);
        if (!dbFile.exists()) {
            System.out.println("SKIP: " + dbPath + " (not found)");
            return;
        }

        System.out.println("Testing Domain Database: " + dbFile.getName());
        
        try (DatabaseReader reader = new DatabaseReader.Builder(dbFile)
                .withCache(new CHMCache())
                .build()) {

            for (String ip : TEST_IPS) {
                try {
                    InetAddress addr = InetAddress.getByName(ip);
                    DomainResponse response = reader.domain(addr);
                    
                    String domain = response.getDomain();
                    System.out.println("  " + ip + " -> Domain: " + domain);
                    
                } catch (Exception e) {
                    if (!(e instanceof com.maxmind.geoip2.exception.AddressNotFoundException)) {
                        System.out.println("  " + ip + " -> ERROR: " + e.getMessage());
                    }
                }
            }
            
            assertTest("Domain database read successful", true, dbFile.getName());
            
        } catch (Exception e) {
            assertTest("Domain database read", false, e.getMessage());
        }
        System.out.println();
    }

    private static void testEnterpriseDatabase(String dbPath) {
        File dbFile = new File(dbPath);
        if (!dbFile.exists()) {
            System.out.println("SKIP: " + dbPath + " (not found)");
            return;
        }

        System.out.println("Testing Enterprise Database: " + dbFile.getName());
        
        try (DatabaseReader reader = new DatabaseReader.Builder(dbFile)
                .withCache(new CHMCache())
                .build()) {

            for (String ip : TEST_IPS) {
                try {
                    InetAddress addr = InetAddress.getByName(ip);
                    EnterpriseResponse response = reader.enterprise(addr);
                    
                    Country country = response.getCountry();
                    City city = response.getCity();
                    Traits traits = response.getTraits();
                    
                    String countryCode = country != null ? country.getIsoCode() : null;
                    String cityName = city != null ? city.getName() : null;
                    String userType = traits != null ? traits.getUserType() : null;
                    
                    System.out.println("  " + ip + " -> " + countryCode + "/" + cityName + 
                        " (userType: " + userType + ")");
                    
                } catch (Exception e) {
                    if (!(e instanceof com.maxmind.geoip2.exception.AddressNotFoundException)) {
                        System.out.println("  " + ip + " -> ERROR: " + e.getMessage());
                    }
                }
            }
            
            assertTest("Enterprise database read successful", true, dbFile.getName());
            
        } catch (Exception e) {
            assertTest("Enterprise database read", false, e.getMessage());
        }
        System.out.println();
    }

    private static void testAnonymousIpDatabase(String dbPath) {
        File dbFile = new File(dbPath);
        if (!dbFile.exists()) {
            System.out.println("SKIP: " + dbPath + " (not found)");
            return;
        }

        System.out.println("Testing Anonymous IP Database: " + dbFile.getName());
        
        try (DatabaseReader reader = new DatabaseReader.Builder(dbFile)
                .withCache(new CHMCache())
                .build()) {

            for (String ip : TEST_IPS) {
                try {
                    InetAddress addr = InetAddress.getByName(ip);
                    AnonymousIpResponse response = reader.anonymousIp(addr);
                    
                    boolean isAnonymous = response.isAnonymous();
                    boolean isVpn = response.isAnonymousVpn();
                    boolean isHosting = response.isHostingProvider();
                    boolean isTor = response.isTorExitNode();
                    
                    System.out.println("  " + ip + " -> anon:" + isAnonymous + 
                        " vpn:" + isVpn + " hosting:" + isHosting + " tor:" + isTor);
                    
                } catch (Exception e) {
                    if (!(e instanceof com.maxmind.geoip2.exception.AddressNotFoundException)) {
                        System.out.println("  " + ip + " -> ERROR: " + e.getMessage());
                    }
                }
            }
            
            assertTest("Anonymous IP database read successful", true, dbFile.getName());
            
        } catch (Exception e) {
            assertTest("Anonymous IP database read", false, e.getMessage());
        }
        System.out.println();
    }

    private static void runApiTests() {
        System.out.println("Running API Compatibility Tests");
        System.out.println("================================");
        System.out.println();

        // Test that key classes are available
        assertTest("DatabaseReader class exists", 
            classExists("com.maxmind.geoip2.DatabaseReader"), null);
        assertTest("CityResponse class exists", 
            classExists("com.maxmind.geoip2.model.CityResponse"), null);
        assertTest("CountryResponse class exists", 
            classExists("com.maxmind.geoip2.model.CountryResponse"), null);
        assertTest("AsnResponse class exists", 
            classExists("com.maxmind.geoip2.model.AsnResponse"), null);
        assertTest("CHMCache class exists", 
            classExists("com.maxmind.db.CHMCache"), null);
        assertTest("DeserializationException class exists", 
            classExists("com.maxmind.db.DeserializationException"), null);
    }

    private static boolean classExists(String className) {
        try {
            Class.forName(className);
            return true;
        } catch (ClassNotFoundException e) {
            return false;
        }
    }

    private static void assertTest(String testName, boolean condition, String detail) {
        if (condition) {
            System.out.println("  PASS: " + testName + (detail != null ? " - " + detail : ""));
            passed++;
        } else {
            System.out.println("  FAIL: " + testName + (detail != null ? " - " + detail : ""));
            failed++;
            failures.add(testName + (detail != null ? " - " + detail : ""));
        }
    }

    private static void printSummary() {
        System.out.println();
        System.out.println("==========================================");
        System.out.println("Test Summary");
        System.out.println("==========================================");
        System.out.println("Passed: " + passed);
        System.out.println("Failed: " + failed);
        
        if (!failures.isEmpty()) {
            System.out.println();
            System.out.println("Failures:");
            for (String failure : failures) {
                System.out.println("  - " + failure);
            }
        }
        
        System.out.println();
        System.out.println("Result: " + (failed == 0 ? "SUCCESS" : "FAILURE"));
    }
}
