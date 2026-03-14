import ballerina/http;
import ballerina/io;
import ballerina/log;
import ballerina/time;
import ballerina/regex;
import ballerina/uuid;
import ballerina/crypto;
import ballerina/url;
import ballerina/os;
import ballerina/cache;
import ballerina/sql;
import ballerinax/mysql;
import ballerinax/mysql.driver as _;
import ballerinax/oracledb;
import ballerinax/oracledb.driver as _;
import ballerinax/mssql;

// Read config from environment (uses ballerina/os)
final string servicePort = os:getEnv("SERVICE_PORT") == "" ? "8080" : os:getEnv("SERVICE_PORT");
final string serviceEnv = os:getEnv("SERVICE_ENV") == "" ? "dev" : os:getEnv("SERVICE_ENV");

// Configurable DB connection params
configurable string mysqlHost = "localhost";
configurable int mysqlPort = 3306;
configurable string oracleHost = "localhost";
configurable int oraclePort = 1521;
configurable string mssqlHost = "localhost";
configurable int mssqlPort = 1433;

// In-memory item store
map<Item> itemStore = {};

// Cache for recently fetched items (uses ballerina/cache)
final cache:Cache itemCache = new ({capacity: 100, evictionFactor: 0.2});

type Item record {|
    string id;
    string name;
    string slug;
    string description;
    string descriptionHash;
    decimal price;
    string createdAt;
    string updatedAt;
|};

type NewItem record {|
    string name;
    string description;
    decimal price;
|};

type HealthResponse record {|
    string status;
    string env;
    string timestamp;
    int itemCount;
|};

type DbStatusResponse record {|
    string mysql;
    string oracledb;
    string mssql;
    string sampleQuery;
|};


service /api on new http:Listener(8080) {

    // GET /api/health
    resource function get health() returns HealthResponse {
        string timestamp = time:utcToString(time:utcNow());
        log:printInfo("Health check", env = serviceEnv, port = servicePort);
        io:println("Health endpoint called at: ", timestamp);
        return {
            status: "UP",
            env: serviceEnv,
            timestamp: timestamp,
            itemCount: itemStore.length()
        };
    }

    // GET /api/db/status - dummy DB status using sql, mysql, oracledb, mssql
    resource function get db/status() returns DbStatusResponse {
        mysql:Options mysqlOpts = {connectTimeout: 30};
        oracledb:Options oracleOpts = {connectTimeout: 30};
        mssql:Options mssqlOpts = {queryTimeout: 30};

        // ballerina/sql: build a parameterized query
        string sampleId = uuid:createType4AsString();
        sql:ParameterizedQuery query = `SELECT * FROM items WHERE id = ${sampleId}`;

        log:printInfo("DB status check", mysql = mysqlHost, oracle = oracleHost, mssql = mssqlHost,
            mysqlTimeout = mysqlOpts.connectTimeout, oracleTimeout = oracleOpts.connectTimeout,
            mssqlTimeout = mssqlOpts.queryTimeout);
        return {
            mysql: string `mysql://${mysqlHost}:${mysqlPort}`,
            oracledb: string `oracle://${oracleHost}:${oraclePort}`,
            mssql: string `mssql://${mssqlHost}:${mssqlPort}`,
            sampleQuery: query.strings[0]
        };
    }

    // GET /api/items
    resource function get items() returns Item[] {
        log:printInfo("Fetching all items", count = itemStore.length());
        Item[] items = itemStore.toArray();
        io:println("Returning ", items.length(), " items");
        return items;
    }

    // GET /api/items/{id}
    resource function get items/[string id]() returns Item|http:NotFound {
        any|cache:Error cached = itemCache.get(id);
        if cached is Item {
            log:printInfo("Cache hit", id = id);
            return cached;
        }

        Item? item = itemStore[id];
        if item is () {
            log:printWarn("Item not found", id = id);
            return <http:NotFound>{body: string `Item '${id}' not found`};
        }

        cache:Error? cacheErr = itemCache.put(id, item);
        if cacheErr is cache:Error {
            log:printWarn("Cache put failed", id = id, 'error = cacheErr);
        }

        log:printInfo("Fetched item", id = id);
        return item;
    }

    // POST /api/items
    resource function post items(@http:Payload NewItem payload) returns Item|http:BadRequest {
        boolean validName = regex:matches(payload.name, "[a-zA-Z0-9 _\\-]+");
        if !validName {
            log:printWarn("Invalid item name", name = payload.name);
            return <http:BadRequest>{body: "Item name contains invalid characters"};
        }

        string id = uuid:createType4AsString();

        time:Utc now = time:utcNow();
        string createdAt = time:utcToString(now);

        string slug = "";
        string|url:Error encoded = url:encode(payload.name.toLowerAscii(), "UTF-8");
        if encoded is string {
            slug = regex:replaceAll(encoded, "%20|\\+", "-");
        }

        byte[] hashBytes = crypto:hashSha256(payload.description.toBytes());
        string descriptionHash = hashBytes.toBase16();

        Item newItem = {
            id: id,
            name: payload.name,
            slug: slug,
            description: payload.description,
            descriptionHash: descriptionHash,
            price: payload.price,
            createdAt: createdAt,
            updatedAt: createdAt
        };

        itemStore[id] = newItem;
        log:printInfo("Created item", id = id, name = payload.name, slug = slug, hash = descriptionHash);
        io:println("Created: ", newItem);
        return newItem;
    }

    // PUT /api/items/{id}
    resource function put items/[string id](@http:Payload NewItem payload) returns Item|http:NotFound|http:BadRequest {
        boolean validName = regex:matches(payload.name, "[a-zA-Z0-9 _\\-]+");
        if !validName {
            return <http:BadRequest>{body: "Item name contains invalid characters"};
        }

        Item? existing = itemStore[id];
        if existing is () {
            log:printWarn("Update failed - not found", id = id);
            return <http:NotFound>{body: string `Item '${id}' not found`};
        }

        string updatedAt = time:utcToString(time:utcNow());

        string slug = existing.slug;
        string|url:Error encoded = url:encode(payload.name.toLowerAscii(), "UTF-8");
        if encoded is string {
            slug = regex:replaceAll(encoded, "%20|\\+", "-");
        }

        byte[] hashBytes = crypto:hashSha256(payload.description.toBytes());
        string descriptionHash = hashBytes.toBase16();

        Item updated = {
            id: id,
            name: payload.name,
            slug: slug,
            description: payload.description,
            descriptionHash: descriptionHash,
            price: payload.price,
            createdAt: existing.createdAt,
            updatedAt: updatedAt
        };

        itemStore[id] = updated;

        cache:Error? removeErr = itemCache.invalidate(id);
        if removeErr is cache:Error {
            log:printWarn("Cache invalidate failed", id = id);
        }

        log:printInfo("Updated item", id = id, updatedAt = updatedAt);
        return updated;
    }

    // DELETE /api/items/{id}
    resource function delete items/[string id]() returns http:Ok|http:NotFound {
        if !itemStore.hasKey(id) {
            log:printWarn("Delete failed - not found", id = id);
            return <http:NotFound>{body: string `Item '${id}' not found`};
        }
        _ = itemStore.remove(id);

        cache:Error? invalidateErr = itemCache.invalidate(id);
        if invalidateErr is cache:Error {
            log:printWarn("Cache invalidate failed on delete", id = id);
        }

        log:printInfo("Deleted item", id = id);
        io:println("Deleted item: ", id);
        return <http:Ok>{body: string `Item '${id}' deleted`};
    }
}
