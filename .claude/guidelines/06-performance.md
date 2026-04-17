# Performance

> Conditional loading, caching, Action Scheduler, query optimization, and WooCommerce-specific performance patterns.

---

## Conditional Loading

Never load assets globally:

```php
public function enqueue_scripts(): void {
	if ( ! is_checkout() ) {
		return;
	}

	// Check if already enqueued (multi-plugin safety).
	if ( wp_script_is( 'nvm-inventory-checkout', 'enqueued' ) ) {
		return;
	}

	wp_enqueue_script(
		'nvm-inventory-checkout',
		Plugin::url( 'assets/js/checkout.js' ),
		[],    // No jQuery dependency for frontend.
		Plugin::VERSION,
		[ 'strategy' => 'defer' ]  // WP 6.3+ script loading strategy.
	);
}
```

---

## Action Scheduler for Heavy Tasks

Any task > 2 seconds must be async:

```php
// Schedule — guard against duplicates first.
if ( ! as_has_scheduled_action( 'nvm/inventory/sync', [ 'product_id' => $id ], 'nvm-inventory' ) ) {
	as_schedule_single_action(
		time() + 60,
		'nvm/inventory/sync',
		[ 'product_id' => $id ],
		'nvm-inventory'          // Group keeps plugin jobs separate from other plugins.
	);
}

// Handler.
add_action( 'nvm/inventory/sync', [ $this, 'process_sync' ] );
```

### Recurring Tasks

```php
// Schedule recurring task (if not already scheduled).
if ( ! as_has_scheduled_action( 'nvm/inventory/daily_cleanup', [], 'nvm-inventory' ) ) {
	as_schedule_recurring_action(
		time(),
		DAY_IN_SECONDS,
		'nvm/inventory/daily_cleanup',
		[],
		'nvm-inventory'
	);
}
```

### Retry Behaviour

Action Scheduler retries a job **up to 3 times** by default. To signal a failure and allow a retry, throw an `\Exception`. To mark a job permanently done (no retry), return normally:

```php
public function process_sync( int $product_id ): void {
	$product = wc_get_product( $product_id );

	if ( ! $product ) {
		// Returning normally marks the action complete — no retry.
		return;
	}

	if ( ! $this->sync_service->push( $product ) ) {
		// Throwing causes AS to mark the action failed and schedule a retry.
		throw new \RuntimeException( "Sync failed for product {$product_id}" );
	}
}
```

### Chaining Batches via Action Scheduler

For smaller catalogs where each AS job processes one page and schedules the next. For large catalogs (10k+ rows) prefer the cursor pagination approach in the **Batched Processing** section below.

```php
/**
 * Process large datasets in batches via Action Scheduler.
 * Each batch schedules the next one — no memory issues.
 */
public function schedule_batch_sync(): void {
	as_schedule_single_action(
		time(),
		'nvm/inventory/batch_sync',
		[ 'page' => 1 ],
		'nvm-inventory'
	);
}

public function process_batch( int $page ): void {
	$per_page    = 50;
	$product_ids = wc_get_products( [
		'limit'  => $per_page,
		'page'   => $page,
		'return' => 'ids',
		'status' => 'publish',
	] );

	if ( empty( $product_ids ) ) {
		wc_get_logger()->info( 'Batch sync complete.', [ 'source' => Plugin::SLUG ] );
		return;
	}

	foreach ( $product_ids as $product_id ) {
		$this->sync_single_product( $product_id );
	}

	// Schedule next batch.
	as_schedule_single_action(
		time(),
		'nvm/inventory/batch_sync',
		[ 'page' => $page + 1 ],
		'nvm-inventory'
	);
}
```

### Cleanup on Deactivation

Always cancel pending actions when the plugin deactivates, or they persist in the queue:

```php
public static function deactivate(): void {
	as_unschedule_all_actions( 'nvm/inventory/sync', [], 'nvm-inventory' );
}
```

---

## Transient Caching (Persistent)

For data that should survive across requests:

```php
$cache_key = Plugin::PREFIX . 'expensive_data_' . $product_id;
$data      = get_transient( $cache_key );

if ( false === $data ) {
	$data = $this->expensive_operation( $product_id );
	set_transient( $cache_key, $data, HOUR_IN_SECONDS );
}

return $data;
```

---

## Object Cache (Per-Request)

For data reused multiple times within the same request (avoids repeated `get_post_meta` calls):

```php
$cache_key = Plugin::PREFIX . 'stock_' . $product_id;
$found     = false;
$stock     = wp_cache_get( $cache_key, Plugin::SLUG, false, $found );

if ( ! $found ) {
	$product = wc_get_product( $product_id );
	$stock   = $product?->get_stock_quantity() ?? 0;
	wp_cache_set( $cache_key, $stock, Plugin::SLUG, 300 );
}

return $stock;
```

---

## Transient vs Object Cache — Which to Use

| Situation | Use |
|-----------|-----|
| Data must survive across multiple requests | `set_transient()` |
| Data is only reused within the **same request** | `wp_cache_set()` |
| Persistent cache (Redis/Memcached) is installed | Object cache is also durable — prefer it over transients |
| External API response (valid for minutes/hours) | `set_transient()` |
| Loop that calls `get_post_meta()` N times | `update_meta_cache()` prefetch, then `wp_cache_set()` result |

> **Rule**: default to `set_transient()` when unsure. Object cache without a persistent backend (Redis/Memcached) is request-scoped only — data is lost at the end of the PHP process.

---

## Cache Invalidation

Always invalidate when data changes:

```php
public function update_stock( int $product_id, int $quantity ): void {
	$product = wc_get_product( $product_id );
	$product?->set_stock_quantity( $quantity );
	$product?->save();

	// Clear all caches for this product.
	delete_transient( Plugin::PREFIX . 'expensive_data_' . $product_id );
	wp_cache_delete( Plugin::PREFIX . 'stock_' . $product_id, Plugin::SLUG );

	/**
	 * Fires after stock is updated — let other code clear its caches too.
	 *
	 * @since 1.0.0
	 *
	 * @param int $product_id Product ID.
	 * @param int $quantity   New stock quantity.
	 */
	do_action( 'nvm/inventory/stock_updated', $product_id, $quantity );
}
```

---

## Query Performance Rules

- **Always set `limit`** on `wc_get_orders()` and `wc_get_products()`. Never unbounded.
- **Use `'return' => 'ids'`** when you only need IDs, not full objects.
- **Batch large operations**: Process in chunks of 50-200, not all at once.
- **Avoid `get_posts` in loops**: Prefetch with a single query when possible.
- **Never call `wp_cache_flush()`** in a loop — it wipes the entire object cache for every other plugin on the site. Use `wp_cache_flush_runtime()` (WP 6.0+) to clear only the in-memory cache, and `wc_delete_product_transients( $id )` for targeted product cache busting.

---

## Prefetch to Avoid N+1 Queries

The single biggest performance cliff in WordPress is looping over posts/products/orders and calling `get_post_meta()`, `get_the_terms()`, or `wc_get_product()` inside the loop — each call hits the DB independently.

### Prefetch Post Meta

```php
$product_ids = [ 12, 34, 56, 78 ];

// One query for ALL meta rows of these IDs instead of N queries inside the loop.
update_meta_cache( 'post', $product_ids );

foreach ( $product_ids as $id ) {
	$sku   = get_post_meta( $id, '_sku', true );        // Served from cache.
	$stock = get_post_meta( $id, '_stock', true );      // Served from cache.
}
```

For orders (HPOS): use `wc_get_orders( [ 'include' => $ids ] )` once, or prefetch via `OrdersTableDataStore`. Do not call `wc_get_order()` inside a loop over thousands of IDs.

### Prefetch `WP_Query` Properly

The default `WP_Query` is noisy: it counts total rows, primes term/meta caches, and runs post-processing hooks even when you don't need them. Disable what you don't use:

```php
$query = new WP_Query( [
	'post_type'              => 'product',
	'posts_per_page'         => 100,
	'fields'                 => 'ids',           // Skip post hydration.
	'no_found_rows'          => true,            // Skip SQL_CALC_FOUND_ROWS (no pagination count).
	'update_post_meta_cache' => false,           // Only set to false if you truly don't read meta.
	'update_post_term_cache' => false,           // Only set to false if you don't read terms.
	'orderby'                => 'ID',
	'order'                  => 'ASC',
] );
```

**Rule of thumb**:
- Need pagination total? Leave `no_found_rows` default (false).
- Reading meta inside the loop? Leave `update_post_meta_cache` true **and** ensure you're using `get_post_meta` (cache-aware), not `$wpdb`.
- Reading taxonomy terms? Leave `update_post_term_cache` true.

Setting these to `false` without understanding what you read downstream *creates* N+1 queries. Measure before toggling.

---

## Batched Processing (Cursor Pagination)

Offset pagination (`page=1,2,3…`) degrades linearly on large catalogs (`LIMIT 50 OFFSET 49950` still scans 50k rows), and skips or duplicates items when the loop mutates the data it's iterating. Use ID-based cursor pagination instead:

```php
public function process_all_products(): void {
	global $wpdb;

	$batch_size = 100;
	$last_id    = 0;

	do {
		// Cursor query: always scans forward from the last seen ID.
		// Uses the PRIMARY KEY index — constant-time per page regardless of catalog size.
		$product_ids = $wpdb->get_col(
			$wpdb->prepare(
				"SELECT ID FROM {$wpdb->posts}
				 WHERE post_type = 'product'
				   AND post_status = 'publish'
				   AND ID > %d
				 ORDER BY ID ASC
				 LIMIT %d",
				$last_id,
				$batch_size
			)
		);

		if ( empty( $product_ids ) ) {
			break;
		}

		$product_ids = array_map( 'intval', $product_ids );

		// Prefetch meta in one query instead of N queries inside the loop.
		update_meta_cache( 'post', $product_ids );

		foreach ( $product_ids as $product_id ) {
			$this->process_single_product( $product_id );
		}

		$last_id = end( $product_ids );

		// Free runtime memory without nuking the persistent object cache.
		wp_cache_flush_runtime();

		// Let other code react (e.g., update a progress indicator).
		do_action( 'nvm/inventory/batch_processed', $product_ids );

	} while ( count( $product_ids ) === $batch_size );
}
```

### Why Not `wc_get_products()` Here?

`wc_get_products()` is fine for small, bounded queries, but it instantiates `WC_Product` objects (or at minimum runs through the CRUD layer) and its `page`/`offset` pagination has the same MySQL cost. For multi-thousand-row loops, a raw `$wpdb` cursor query over IDs is dramatically faster. Hydrate to `WC_Product` only for the IDs you actually need to mutate.

---

## For Long-Running Imports

Wrap bulk jobs with cache suspension to prevent runtime memory blow-up:

```php
wp_suspend_cache_addition( true );
try {
	$this->process_all_products();
} finally {
	wp_suspend_cache_addition( false );
}
```

Combine with Action Scheduler (see above) so each chunk runs in its own request with a fresh PHP process.

---

## Bulk Term Assignment — Defer Counting

`wp_set_object_terms()` recalculates term counts after every call. Inside a loop, this fires N expensive `COUNT(*)` queries. Defer until the loop is done:

```php
wp_defer_term_counting( true );

foreach ( $product_ids as $id ) {
	wp_set_object_terms( $id, $category_ids, 'product_cat' );
}

wp_defer_term_counting( false ); // One recalculation for the entire batch.
```

Same pattern for `wp_defer_comment_counting( true/false )` if updating comments in bulk.

---

## Options — Disable Autoload for Large Values

`add_option()` defaults to `autoload = true`, meaning the value is loaded on **every page** as part of WordPress's bootstrap query. For data only needed on specific pages (cached reports, config blobs), opt out:

```php
// BAD — large data autoloaded on every page.
update_option( 'nvm_inv_all_sync_results', $huge_array, true );

// GOOD — store only config/settings as autoloaded.
update_option( 'nvm_inv_settings', $small_settings, true );

// WP 6.6+: pass false. Older WP: pass 'no'.
add_option( Plugin::PREFIX . 'report_cache', $data, '', false );
update_option( Plugin::PREFIX . 'report_cache', $new_data, false );
// Or better: use a custom table for large datasets.
```

Check existing options for large autoloaded values:

```sql
SELECT option_name, LENGTH(option_value) AS size
FROM wp_options
WHERE autoload = 'yes'
ORDER BY size DESC
LIMIT 20;
```

---

## Memory Management in Batch Loops

Hydrated objects accumulate in memory across batches — unset them at the end of the inner loop:

```php
foreach ( $product_ids as $product_id ) {
	$product = wc_get_product( $product_id );
	$this->process_product( $product );

	// Release references; prevents memory creep over thousands of iterations.
	$product = null;
}
```

For CLI/WP-CLI or Action Scheduler jobs that run outside a normal web request, trigger a garbage collection pass after each batch:

```php
if ( function_exists( 'gc_collect_cycles' ) ) {
	gc_collect_cycles();
}
```

---

## WooCommerce-Specific Performance

### Avoid N+1 Queries on Order Items

```php
// BAD — N+1: one query per product inside the loop.
$order = wc_get_order( $order_id );
foreach ( $order->get_items() as $item ) {
	$product = $item->get_product(); // Triggers a query each time.
	$sku     = $product?->get_sku();
}

// GOOD — Prefetch all product IDs, then batch-load.
$order       = wc_get_order( $order_id );
$product_ids = [];

foreach ( $order->get_items() as $item ) {
	$product_ids[] = $item->get_product_id();
}

// Prime the WooCommerce object cache.
_prime_post_caches( $product_ids );
wc_get_products( [ 'include' => $product_ids, 'limit' => count( $product_ids ) ] );

// Now these calls hit cache, not the database.
foreach ( $order->get_items() as $item ) {
	$product = $item->get_product();
	$sku     = $product?->get_sku();
}
```

### Use Lookup Tables for Price Queries

WooCommerce maintains lookup tables for faster queries. Use them:

```php
// Use lookup table for price-range queries (faster than meta queries).
$products = wc_get_products( [
	'limit'     => 50,
	'min_price' => 10,
	'max_price' => 100,
	'return'    => 'ids',
] );
```

### Avoid Loading Full Objects When Not Needed

```php
// BAD — loads full WC_Product for each, heavy on memory.
$products = wc_get_products( [ 'limit' => 500 ] );
$names    = array_map( fn( $p ) => $p->get_name(), $products );

// GOOD — use IDs + direct meta access for simple reads.
$product_ids = wc_get_products( [ 'limit' => 500, 'return' => 'ids' ] );
$names       = array_map( fn( int $id ): string => get_the_title( $id ), $product_ids );
```

### Cart Fragment Optimization

```php
// Disable cart fragments AJAX on pages that don't need it.
add_action( 'wp_enqueue_scripts', static function(): void {
	if ( is_front_page() || is_archive() ) {
		wp_dequeue_script( 'wc-cart-fragments' );
	}
}, 100 );
```

---

## Database Query Optimization

### Use `$wpdb->prepare()` with Proper Indexing

```php
// Ensure your custom tables have appropriate indexes.
// Always use prepare() for custom queries.
global $wpdb;
$table = $wpdb->prefix . 'nvm_sync_log';

$results = $wpdb->get_results(
	$wpdb->prepare(
		"SELECT product_id, sync_status, synced_at
		 FROM {$table}
		 WHERE sync_status = %s
		 AND synced_at > %s
		 ORDER BY synced_at DESC
		 LIMIT %d",
		'failed',
		gmdate( 'Y-m-d H:i:s', strtotime( '-24 hours' ) ),
		100
	)
);
```

### Custom Table Indexes

```php
// When creating custom tables, always add indexes for columns you query.
public function create_tables(): void {
	global $wpdb;
	$table   = $wpdb->prefix . 'nvm_sync_log';
	$charset = $wpdb->get_charset_collate();

	$sql = "CREATE TABLE {$table} (
		id bigint(20) unsigned NOT NULL AUTO_INCREMENT,
		product_id bigint(20) unsigned NOT NULL,
		sync_status varchar(20) NOT NULL DEFAULT 'pending',
		synced_at datetime NOT NULL DEFAULT CURRENT_TIMESTAMP,
		error_message text,
		PRIMARY KEY (id),
		KEY product_id (product_id),
		KEY sync_status_date (sync_status, synced_at)
	) {$charset};";

	require_once ABSPATH . 'wp-admin/includes/upgrade.php';
	dbDelta( $sql );
}
```

---

## HTTP API (External Requests)

`wp_remote_get()` / `wp_remote_post()` default to a **5-second timeout**. That is too long for any user-facing request — a single slow upstream blocks the whole PHP worker, consumes a connection slot, and on admin screens makes the entire dashboard hang.

### Always Set an Explicit Timeout

```php
$response = wp_remote_get( $url, [
	'timeout'     => 2,                                     // Hard cap. User-facing: ≤ 2s. Background: ≤ 10s.
	'redirection' => 3,                                     // Cap redirect chain.
	'user-agent'  => 'NVM Inventory/' . Plugin::VERSION,    // Identify the plugin to upstreams.
	'headers'     => [ 'Accept' => 'application/json' ],
] );

if ( is_wp_error( $response ) ) {
	wc_get_logger()->warning(
		'Upstream request failed: {error}',
		[ 'source' => Plugin::SLUG, 'error' => $response->get_error_message() ]
	);
	return null;
}

$code = wp_remote_retrieve_response_code( $response );
if ( $code < 200 || $code >= 300 ) {
	return null;
}
```

### Cache Successful Responses

Never hit an external API on every page load. Cache the parsed response, not the raw HTTP body:

```php
public function fetch_exchange_rates(): array {
	$cache_key = Plugin::PREFIX . 'fx_rates';
	$cached    = get_transient( $cache_key );

	if ( is_array( $cached ) ) {
		return $cached;
	}

	$response = wp_remote_get( 'https://api.example.com/rates', [ 'timeout' => 2 ] );

	if ( is_wp_error( $response ) || 200 !== wp_remote_retrieve_response_code( $response ) ) {
		// Negative cache: avoid hammering a failing upstream.
		set_transient( $cache_key, [], 5 * MINUTE_IN_SECONDS );
		return [];
	}

	$decoded = json_decode( wp_remote_retrieve_body( $response ), true );
	$data    = is_array( $decoded ) ? $decoded : [];

	set_transient( $cache_key, $data, HOUR_IN_SECONDS );
	return $data;
}
```

### Never Call Upstream APIs on Frontend Render

If the data is needed on the frontend, populate the cache from a cron/Action Scheduler job. Frontend requests should only *read* the cache; a cache miss returns stale-or-empty, never triggers a synchronous fetch.

### Rules

| Context | Max `timeout` | Notes |
|---------|---------------|-------|
| Frontend page render | Never — use cached data | Any synchronous fetch is a production outage waiting to happen. |
| Admin dashboard | 2s | Log + degrade gracefully on failure. |
| AJAX / REST (user-initiated) | 3s | Surface errors, don't block. |
| Action Scheduler / WP-CLI | 10–30s | Acceptable when no user is waiting. |

### Batch Parallel Requests

For multiple independent URLs, use `Requests::request_multiple()` (WP 4.6+ ships Requests) via `WP_Http` — a sequential `wp_remote_get` loop turns N upstream requests into N × timeout wall-clock time.

---

## Profiling — Finding the Slow Part

Never optimise blindly. Identify the actual bottleneck first.

### Query Monitor (development)

Install the [Query Monitor](https://wordpress.org/plugins/query-monitor/) plugin. It surfaces:
- All DB queries with execution time, caller, and duplicate count
- HTTP API calls and their duration
- Hook execution time
- Memory usage per page load

Add named spans to appear in the QM timeline:

```php
do_action( 'qm/start', 'nvm-inventory-sync' );
$this->run_sync();
do_action( 'qm/stop', 'nvm-inventory-sync' );
```

### SAVEQUERIES (unit tests / local only)

```php
// In wp-config.php or test bootstrap — never in production.
define( 'SAVEQUERIES', true );

// After the code under test runs:
global $wpdb;
var_dump( $wpdb->queries ); // [ [sql, time, caller], ... ]
```

### Targeted timing in code

```php
$start = microtime( true );
$this->expensive_operation();
$elapsed = microtime( true ) - $start;

wc_get_logger()->debug(
	'Operation took {ms}ms',
	[ 'source' => Plugin::SLUG, 'ms' => round( $elapsed * 1000, 2 ) ]
);
```

### Server-Timing headers (debug only)

```php
add_action( 'send_headers', static function(): void {
	if ( ! defined( 'WP_DEBUG' ) || ! WP_DEBUG ) {
		return;
	}

	$start    = microtime( true );
	// ... operation ...
	$duration = ( microtime( true ) - $start ) * 1000;

	header( sprintf( 'Server-Timing: nvm-sync;dur=%.2f;desc="NVM Sync"', $duration ) );
} );
```

### Peak memory (CLI / Action Scheduler jobs)

```php
wc_get_logger()->debug(
	'Peak memory: {mb}MB',
	[ 'source' => Plugin::SLUG, 'mb' => round( memory_get_peak_usage( true ) / 1024 / 1024, 2 ) ]
);
```

---

## Performance Checklist

| Rule | Details |
|------|---------|
| **Always set `limit`** | Every `wc_get_orders()`, `wc_get_products()`, `WP_Query` must have a limit |
| **Use `'return' => 'ids'`** | When you only need IDs, never load full objects |
| **Batch > 50 items** | Process in chunks of 50-100, use cursor pagination for large catalogs |
| **Async > 2 seconds** | Any operation over 2 seconds must use Action Scheduler |
| **Cache expensive calls** | Use transients for cross-request, `wp_cache_*` for per-request |
| **Invalidate on write** | Every data write must clear related caches |
| **Conditional loading** | Assets only on pages that need them, with `defer`/`async` |
| **No N+1 queries** | Prefetch IDs, batch-load objects outside loops |
| **Small autoloaded options** | Config only — large data in non-autoloaded options or custom tables |
| **Index custom tables** | Add indexes for every column used in WHERE/ORDER BY |
| **Defer term counting** | Wrap bulk `wp_set_object_terms()` calls with `wp_defer_term_counting()` |
| **HTTP timeouts** | Always set explicit timeout; never fetch on frontend render |
| **Measure first** | Use Query Monitor or `SAVEQUERIES` before optimising |
