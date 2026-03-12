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

// Read config from environment (uses ballerina/os)
final string servicePort = os:getEnv("SERVICE_PORT") == "" ? "8080" : os:getEnv("SERVICE_PORT");
final string serviceEnv = os:getEnv("SERVICE_ENV") == "" ? "dev" : os:getEnv("SERVICE_ENV");

// In-memory store
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

service /api on new http:Listener(8080) {

    // GET /api/health
    resource function get health() returns HealthResponse {
        // ballerina/time: current timestamp
        string timestamp = time:utcToString(time:utcNow());
        log:printInfo("Health check", env = serviceEnv, port = servicePort);
        io:println("Health check at: ", timestamp);
        return {
            status: "UP",
            env: serviceEnv,
            timestamp: timestamp,
            itemCount: itemStore.length()
        };
    }

    // GET /api/items
    resource function get items() returns Item[] {
        log:printInfo("Listing all items", count = itemStore.length());
        Item[] items = itemStore.toArray();
        io:println("Returning ", items.length(), " items");
        return items;
    }

    // GET /api/items/{id}
    resource function get items/[string id]() returns Item|http:NotFound {
        // ballerina/cache: check cache first
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

        // Store in cache
        cache:Error? cacheErr = itemCache.put(id, item);
        if cacheErr is cache:Error {
            log:printWarn("Cache put failed", id = id, 'error = cacheErr);
        }

        log:printInfo("Fetched item", id = id);
        return item;
    }

    // POST /api/items
    resource function post items(@http:Payload NewItem payload) returns Item|http:BadRequest {
        // ballerina/regex: validate name contains only allowed characters
        boolean validName = regex:matches(payload.name, "[a-zA-Z0-9 _\\-]+");
        if !validName {
            log:printWarn("Invalid item name", name = payload.name);
            return <http:BadRequest>{body: "Item name contains invalid characters"};
        }

        // ballerina/uuid: generate unique ID
        string id = uuid:createType4AsString();

        // ballerina/time: timestamps
        time:Utc now = time:utcNow();
        string createdAt = time:utcToString(now);

        // ballerina/url: encode name as URL-safe slug
        string slug = "";
        string|url:Error encoded = url:encode(payload.name.toLowerAscii(), "UTF-8");
        if encoded is string {
            slug = regex:replaceAll(encoded, "%20|\\+", "-");
        }

        // ballerina/crypto: hash description for integrity fingerprint
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

        // ballerina/time: update timestamp
        string updatedAt = time:utcToString(time:utcNow());

        // ballerina/url: re-encode slug
        string slug = existing.slug;
        string|url:Error encoded = url:encode(payload.name.toLowerAscii(), "UTF-8");
        if encoded is string {
            slug = regex:replaceAll(encoded, "%20|\\+", "-");
        }

        // ballerina/crypto: rehash description
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

        // Invalidate cache
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

        // Invalidate cache
        cache:Error? invalidateErr = itemCache.invalidate(id);
        if invalidateErr is cache:Error {
            log:printWarn("Cache invalidate failed on delete", id = id);
        }

        log:printInfo("Deleted item", id = id);
        io:println("Deleted item: ", id);
        return <http:Ok>{body: string `Item '${id}' deleted`};
    }
}
