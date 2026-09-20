# Plugin Lifecycle & Data Migrations

> Activation, deactivation, uninstall, and schema migrations that actually reach existing installs.

The single most common data bug in this codebase: a table is created with `dbDelta()` at activation and never migrated again. **The activation hook does not fire when a plugin is updated** — not via the WP updater, not via FTP, not via `wp plugin update`. Schema changes shipped in v1.2 never reach a site that installed v1.0.

Custom tables: `04-security.md` (SQL safety), `06-performance.md` (indexing). This file owns creation, versioning, and teardown.

---

## 1. The Three Lifecycle Events

| Event | Fires | Use For | Never |
|-------|-------|---------|-------|
| `register_activation_hook` | Manual activation only. **Not on update.** | Run migrations, seed defaults, schedule tasks | Assume it runs on every version |
| `register_deactivation_hook` | Manual deactivation. Also during some update flows. | Unschedule tasks, clear caches | Delete any user data |
| `uninstall.php` | Plugin deleted from the admin | Purge data the merchant opted to delete | Assume the plugin is loaded |

**Migrations do not belong in the activation hook alone.** Activation seeds a fresh install; a version-gated runner on `admin_init` covers updates. Both call the same `Migrator::run()`.

---

## 2. Activation

```php
/**
 * Plugin activation.
 *
 * @since 1.0.0
 */
public function activate(): void {
	// Creates tables on a fresh install, migrates on reactivation.
	Migrator::run();

	// add_option() not update_option(): reactivating must not reset settings.
	add_option( self::PREFIX . 'settings', self::default_settings(), '', false );

	if ( ! as_has_scheduled_action( 'nvm/inventory/daily_cleanup', [], 'nvm-inventory' ) ) {
		as_schedule_recurring_action(
			time() + DAY_IN_SECONDS,
			DAY_IN_SECONDS,
			'nvm/inventory/daily_cleanup',
			[],
			'nvm-inventory'
		);
	}

	/**
	 * Fires on plugin activation.
	 *
	 * @since 1.0.0
	 */
	do_action( 'nvm/inventory/activated' );
}
```

Rules:

- **`add_option()` for defaults, never `update_option()`.** `add_option()` is a no-op when the key exists, so a deactivate/reactivate cycle preserves the merchant's settings.
- **Pass `false` for `$autoload`** on anything not read on every request. See `06-performance.md`.
- **No output.** Anything echoed here produces the "unexpected output during activation" warning and can break redirects.
- **Never call `flush_rewrite_rules()` directly.** Custom post types register on `init`, which has not run during activation, so the flush writes rules that omit them. Set a flag instead:

```php
// In activate():
update_option( self::PREFIX . 'flush_rewrite', 'yes', false );

// In the init hook, after CPTs are registered:
if ( 'yes' === get_option( self::PREFIX . 'flush_rewrite' ) ) {
	delete_option( self::PREFIX . 'flush_rewrite' );
	flush_rewrite_rules();
}
```

- **Multisite:** activation fires once for the network, not per site. Handle the `$network_wide` argument or every subsite silently misses its tables:

```php
/**
 * Plugin activation.
 *
 * register_activation_hook() passes $network_wide as the first argument.
 * activate_single_site() holds the body shown above.
 *
 * @since 1.0.0
 */
public function activate( bool $network_wide = false ): void {
	if ( $network_wide && is_multisite() ) {
		foreach ( get_sites( [ 'fields' => 'ids', 'number' => 0 ] ) as $site_id ) {
			switch_to_blog( (int) $site_id );
			$this->activate_single_site();
			restore_current_blog();
		}
		return;
	}

	$this->activate_single_site();
}
```

---

## 3. Schema Version & Migration Runner

The version option is the contract. Store it separately from `Plugin::VERSION` — the plugin can ship a release with no schema change.

```php
declare(strict_types=1);

namespace NVM\Inventory\Database;

use NVM\Inventory\Plugin;

/**
 * Runs schema migrations in version order, exactly once each.
 *
 * @since 1.0.0
 */
final class Migrator {

	private const OPTION = Plugin::PREFIX . 'db_version';
	private const LOCK   = Plugin::PREFIX . 'migrating';

	/**
	 * Migrations keyed by the schema version they produce.
	 *
	 * Keys must sort with version_compare(). Never edit or reorder a
	 * shipped entry — add a new one.
	 *
	 * @since 1.0.0
	 *
	 * @return array<string, callable():void>
	 */
	private static function migrations(): array {
		return [
			'1.0.0' => [ self::class, 'create_sync_log' ],
			'1.2.0' => [ self::class, 'add_attempts_column' ],
		];
	}

	/**
	 * Apply every migration newer than the installed schema version.
	 *
	 * @since 1.0.0
	 */
	public static function run(): void {
		$installed = (string) get_option( self::OPTION, '0.0.0' );
		$target    = (string) array_key_last( self::migrations() );

		if ( version_compare( $installed, $target, '>=' ) ) {
			return;
		}

		if ( ! self::acquire_lock() ) {
			return;
		}

		try {
			foreach ( self::migrations() as $version => $callback ) {
				if ( version_compare( $installed, $version, '>=' ) ) {
					continue;
				}

				$callback();

				// Checkpoint after each step: a fatal here does not replay
				// the migrations that already succeeded.
				update_option( self::OPTION, $version, false );
			}
		} finally {
			self::release_lock();
		}
	}

	/**
	 * Claim the migration lock atomically.
	 *
	 * add_option() fails when the row exists, which makes it a usable
	 * mutex. A transient is not: get/set is two queries and races.
	 *
	 * @since 1.0.0
	 */
	private static function acquire_lock(): bool {
		return add_option( self::LOCK, time(), '', false );
	}

	/**
	 * @since 1.0.0
	 */
	private static function release_lock(): void {
		delete_option( self::LOCK );
	}
}
```

Wire it so updates are covered:

```php
// In Plugin::init() — runs for every request path that can migrate safely.
add_action( 'admin_init', [ Migrator::class, 'run' ] );
```

- **`admin_init`, not `plugins_loaded`.** Migrating on a front-end request means a shopper pays the latency and two concurrent requests race the lock.
- **Every migration must be idempotent.** The lock can be orphaned by a fatal, and WP-CLI can invoke the runner concurrently with a web request. Write each step so a second run is harmless.
- **Never edit a shipped migration.** Sites that already ran it will not run it again. Add a new version key.
- Expose it to WP-CLI so a deploy can migrate without an admin page load — see `12-advanced-patterns.md`:

```php
WP_CLI::add_command( 'nvm inventory migrate', static function (): void {
	Migrator::run();
	WP_CLI::success( 'Schema up to date.' );
} );
```

---

## 4. dbDelta Formatting Rules

`dbDelta()` parses the SQL string with regexes. Deviate from its format and it silently does nothing, or re-runs `ALTER` on every single request.

```php
/**
 * @since 1.0.0
 */
private static function create_sync_log(): void {
	global $wpdb;

	$table   = $wpdb->prefix . 'nvm_inv_sync_log';
	$charset = $wpdb->get_charset_collate();

	$sql = "CREATE TABLE {$table} (
		id bigint(20) unsigned NOT NULL AUTO_INCREMENT,
		product_id bigint(20) unsigned NOT NULL,
		status varchar(20) NOT NULL DEFAULT 'pending',
		message text,
		created_at datetime NOT NULL DEFAULT CURRENT_TIMESTAMP,
		PRIMARY KEY  (id),
		KEY product_id (product_id),
		KEY status_created (status, created_at)
	) {$charset};";

	require_once ABSPATH . 'wp-admin/includes/upgrade.php';
	dbDelta( $sql );
}
```

Non-negotiable formatting:

| Rule | Why |
|------|-----|
| **Two spaces** after `PRIMARY KEY` | The regex requires it. One space and the key is skipped |
| `KEY`, never `INDEX` | `INDEX` is not recognised |
| Every field on its own line | Fields are split on newlines |
| Lowercase types (`bigint(20)`, not `BIGINT(20)`) | Comparison against the live schema is case-sensitive, so uppercase re-issues the `ALTER` on every run |
| Name every key | Unnamed keys cannot be diffed |
| No backticks around the table name | Breaks the table-name match |
| `require_once ABSPATH . 'wp-admin/includes/upgrade.php';` | `dbDelta()` is not loaded on front-end requests |

**What `dbDelta()` cannot do** — use an explicit `ALTER` in a migration step:

- Drop a column, or rename one
- Drop an index
- Narrow a column's type
- Change the table's charset or engine

```php
/**
 * @since 1.2.0
 */
private static function add_attempts_column(): void {
	global $wpdb;

	$table = $wpdb->prefix . 'nvm_inv_sync_log';

	// Idempotent: adding a column that exists is an error, not a no-op.
	$exists = $wpdb->get_var(
		$wpdb->prepare(
			'SELECT COUNT(*) FROM information_schema.COLUMNS
			 WHERE TABLE_SCHEMA = %s AND TABLE_NAME = %s AND COLUMN_NAME = %s',
			DB_NAME,
			$table,
			'attempts'
		)
	);

	if ( (int) $exists > 0 ) {
		return;
	}

	// Table name comes from $wpdb->prefix and cannot be a prepared
	// placeholder. Never interpolate user input here.
	$wpdb->query( "ALTER TABLE {$table} ADD COLUMN attempts tinyint(3) unsigned NOT NULL DEFAULT 0" );
}
```

---

## 5. Long-Running Migrations

A migration that touches every order will hit the PHP time limit on a real store. Hand it to Action Scheduler and let the runner return immediately.

```php
/**
 * @since 2.0.0
 */
private static function backfill_order_index(): void {
	if ( ! as_has_scheduled_action( 'nvm/inventory/backfill_batch', [], 'nvm-inventory' ) ) {
		as_schedule_single_action( time(), 'nvm/inventory/backfill_batch', [ 'page' => 1 ], 'nvm-inventory' );
	}
}

// Registered in Plugin::init().
add_action( 'nvm/inventory/backfill_batch', static function ( int $page ): void {
	$orders = wc_get_orders(
		[
			'limit'  => 100,
			'paged'  => $page,
			'return' => 'ids',
		]
	);

	if ( empty( $orders ) ) {
		return; // Done. No further batch scheduled.
	}

	foreach ( $orders as $order_id ) {
		// ... migrate one order ...
	}

	as_schedule_single_action(
		time(),
		'nvm/inventory/backfill_batch',
		[ 'page' => $page + 1 ],
		'nvm-inventory'
	);
} );
```

- Bump the schema version as soon as the **batches are scheduled**, not when they finish. The runner's job is to enqueue, once.
- Code reading the new column must tolerate rows not yet backfilled until the queue drains.
- Batch sizing, HPOS-safe order queries: `06-performance.md`, `05-woocommerce.md`.

---

## 6. Deactivation

Deactivation is **not** uninstall. It fires when a merchant toggles the plugin off, and in some update flows — so it must be cheap and entirely non-destructive.

```php
/**
 * Plugin deactivation.
 *
 * @since 1.0.0
 */
public function deactivate(): void {
	// Stop scheduled work: it would otherwise fire with the plugin's
	// callbacks unregistered.
	as_unschedule_all_actions( '', [], 'nvm-inventory' );

	wp_clear_scheduled_hook( 'nvm/inventory/legacy_cron' );

	delete_transient( self::PREFIX . 'report_cache' );

	/**
	 * Fires on plugin deactivation.
	 *
	 * @since 1.0.0
	 */
	do_action( 'nvm/inventory/deactivated' );
}
```

Never here: dropping tables, deleting options, removing post meta, deleting uploaded files.

---

## 7. uninstall.php

Prefer the file over `register_uninstall_hook()`. The hook serialises a callback into the database and requires the plugin to load at delete time; the file is self-contained and WordPress runs it in isolation.

`uninstall.php` sits in the plugin root. **The plugin is not loaded when it runs** — no autoloader, no `Plugin` class, no constants.

```php
<?php
/**
 * Uninstall handler for NVM Inventory.
 *
 * Runs with the plugin unloaded: no autoloader, no Plugin class.
 *
 * @package NVM\Inventory
 * @since   1.0.0
 */

declare(strict_types=1);

// Called by WordPress only. Direct access aborts.
if ( ! defined( 'WP_UNINSTALL_PLUGIN' ) ) {
	exit;
}

if ( ! current_user_can( 'activate_plugins' ) ) {
	exit;
}

const NVM_INV_UNINSTALL_PREFIX = 'nvm_inv_';

/**
 * Purge all plugin data for the current site.
 *
 * @since 1.0.0
 */
function nvm_inv_uninstall_site(): void {
	global $wpdb;

	// Opt-in only. Deleting a plugin to reinstall it must not destroy data.
	if ( 'yes' !== get_option( NVM_INV_UNINSTALL_PREFIX . 'delete_data_on_uninstall' ) ) {
		return;
	}

	$wpdb->query( "DROP TABLE IF EXISTS {$wpdb->prefix}nvm_inv_sync_log" );

	$like = $wpdb->esc_like( NVM_INV_UNINSTALL_PREFIX ) . '%';

	$wpdb->query(
		$wpdb->prepare( "DELETE FROM {$wpdb->options} WHERE option_name LIKE %s", $like )
	);
	$wpdb->query(
		$wpdb->prepare(
			"DELETE FROM {$wpdb->options} WHERE option_name LIKE %s",
			$wpdb->esc_like( '_transient_' . NVM_INV_UNINSTALL_PREFIX ) . '%'
		)
	);
	$wpdb->query(
		$wpdb->prepare( "DELETE FROM {$wpdb->postmeta} WHERE meta_key LIKE %s", $like )
	);
	$wpdb->query(
		$wpdb->prepare( "DELETE FROM {$wpdb->usermeta} WHERE meta_key LIKE %s", $like )
	);

	wp_cache_flush();
}

if ( is_multisite() ) {
	foreach ( get_sites( [ 'fields' => 'ids', 'number' => 0 ] ) as $nvm_inv_site_id ) {
		switch_to_blog( (int) $nvm_inv_site_id );
		nvm_inv_uninstall_site();
		restore_current_blog();
	}

	delete_site_option( NVM_INV_UNINSTALL_PREFIX . 'network_settings' );
} else {
	nvm_inv_uninstall_site();
}
```

- **Gate destruction behind a setting.** Deleting a plugin to reinstall it is routine; silently destroying order history is not. Default the setting to off.
- **Prefix every option, meta key and table** so a `LIKE` sweep is precise. `01-technical-setup.md` mandates this already — uninstall is why it matters.
- **`$wpdb->esc_like()` before `%s`.** An unescaped `_` is a wildcard.
- Table names cannot be placeholders; they must come from `$wpdb->prefix` and a literal, never from input.
- Loop subsites on multisite, and clear network options outside the loop.

---

## 8. Testing Lifecycle Code

Per `09-testing.md`, with Brain Monkey. The runner's contract is "each migration runs at most once", so test that directly.

```php
public function test_run_skips_when_schema_is_current(): void {
	Functions\when( 'get_option' )->justReturn( '1.2.0' );
	Functions\expect( 'add_option' )->never();
	Functions\expect( 'update_option' )->never();

	Migrator::run();

	$this->assertConditionsMet();
}

public function test_run_applies_only_pending_migrations(): void {
	Functions\when( 'get_option' )->justReturn( '1.0.0' );
	Functions\when( 'add_option' )->justReturn( true );   // Lock acquired.
	Functions\when( 'delete_option' )->justReturn( true );

	// 1.0.0 already applied; only 1.2.0 is checkpointed.
	Functions\expect( 'update_option' )
		->once()
		->with( 'nvm_inv_db_version', '1.2.0', false );

	Migrator::run();

	$this->assertConditionsMet();
}

public function test_run_bails_when_another_process_holds_the_lock(): void {
	Functions\when( 'get_option' )->justReturn( '0.0.0' );
	Functions\when( 'add_option' )->justReturn( false );  // Lock held.
	Functions\expect( 'update_option' )->never();
	Functions\expect( 'delete_option' )->never();         // Must not free another owner's lock.

	Migrator::run();

	$this->assertConditionsMet();
}
```

Integration tests against a real database (`09-testing.md`, Integration section) should assert the table exists after `Migrator::run()` and that a second `run()` issues no further `ALTER`.

---

## 9. Checklist

| Check | Verify |
|-------|--------|
| Migration runner | Hooked to `admin_init`, not activation only |
| Schema version | Own option, separate from `Plugin::VERSION`, `$autoload` false |
| Checkpointing | Version written after each step, not once at the end |
| Idempotency | Every migration safe to run twice |
| Shipped migrations | Never edited or reordered after release |
| Lock | Acquired with `add_option()`, released in `finally` |
| `dbDelta` | Two spaces after `PRIMARY KEY`, `KEY` not `INDEX`, lowercase types |
| Column drops/renames | Explicit `ALTER`, guarded by an existence check |
| Large backfills | Action Scheduler batches, never a single request |
| Activation defaults | `add_option()`, so reactivation preserves settings |
| Rewrite flush | Deferred to `init` via a flag |
| Multisite | Activation and uninstall loop `get_sites()` |
| Deactivation | Unschedules only; destroys nothing |
| `uninstall.php` | `WP_UNINSTALL_PLUGIN` guard, capability check, opt-in setting |
| Uninstall sweep | `esc_like()` on every prefix, tables dropped, network options cleared |
