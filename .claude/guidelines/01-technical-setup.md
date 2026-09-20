# Technical Setup

> PHP requirements, naming conventions, and plugin registry.

---

## PHP Requirements

**Minimum**: PHP 8.0

**Leverage modern syntax**: constructor promotion, named arguments, `match`, union types, nullsafe operator, `enum` (8.1+), `readonly` (8.1+), intersection types (8.1+), `readonly` classes (8.2+), DNF types (8.2+).

When using 8.1+ or 8.2+ features, document the minimum version in the class PHPDoc with `@requires PHP 8.1`.

---

## Naming Conventions

| Element | Convention | Example |
|---------|------------|---------|
| Plugin Slug | Short, unique identifier | `INV`, `CCF`, `SSYNC` |
| Global Constants | `NVM_{SLUG}_` prefix (only FILE & PATH) | `NVM_INV_FILE`, `NVM_INV_PATH` |
| Class Constants | Inside Plugin class | `Plugin::VERSION`, `Plugin::SLUG` |
| Functions | `nvm_` prefix, snake_case | `nvm_get_stock()` |
| Classes | `NVM\{Plugin}\` namespace, PascalCase | `NVM\Inventory\Stock_Manager` |
| Methods/Props | snake_case | `$this->product_id` |
| Hooks | `nvm/{plugin-slug}/` prefix | `do_action( 'nvm/inventory/stock_updated' )` |
| REST Routes | `nvm/{plugin-slug}/v1` namespace | `register_rest_route( 'nvm/inventory/v1', ... )` |
| DB Tables | `{$wpdb->prefix}nvm_{slug}_` | `wp_nvm_inv_sync_log` |
| Script Handles | `nvm-{plugin-slug}-{purpose}` | `nvm-inventory-admin` |
| Nonce Actions | `Plugin::PREFIX . '{action}'` | `nvm_inv_save_settings` |

---

## Plugin Slug Registry

Register new plugins here to avoid collisions:

| Plugin Folder | Short Slug | Namespace | Global Prefix |
|---------------|------------|-----------|---------------|
| `nvm-inventory` | `INV` | `NVM\Inventory` | `NVM_INV_` |
| `nvm-checkout-fields` | `CCF` | `NVM\Checkout_Fields` | `NVM_CCF_` |
| `nvm-stock-sync` | `SSYNC` | `NVM\Stock_Sync` | `NVM_SSYNC_` |
| `nvm-product-feeds` | `PF` | `NVM\Product_Feeds` | `NVM_PF_` |
| `nvm-order-export` | `OE` | `NVM\Order_Export` | `NVM_OE_` |
| `nvm-vendors` | `VND` | `NVM\Vendors` | `NVM_VND_` |
| `nvm-stickerfreak-orders` | `STICKERFREAK_ORDERS` | `NVM\Stickerfreak_Orders` | `NVM_STICKERFREAK_ORDERS_` |
| `nvm-stickerfreak-preview` | `STICKERFREAK_PREVIEW` | `NVM\Stickerfreak_Preview` | `NVM_STICKERFREAK_PREVIEW_` |
| `nvm-stickerfreak-adjustments` | `STICKERFREAK_ADJUSTMENTS` | `NVM\Stickerfreak_Adjustments` | `NVM_STICKERFREAK_ADJUSTMENTS_` |
| `nvm-stickerfreak-login` | `STICKERFREAK_LOGIN` | `NVM\Stickerfreak_Login` | `NVM_STICKERFREAK_LOGIN_` |
| `nvm-stickerfreak-reorder` | `STICKERFREAK_REORDER` | `NVM\Stickerfreak_Reorder` | `NVM_STICKERFREAK_REORDER_` |

> **Rule**: Before creating a new plugin, add its slug to this table to avoid collisions.

> **Note**: The `nvm-stickerfreak-*` family predates this registry and uses the
> full folder name as its slug rather than a 3-5 character abbreviation. The
> entries record what those plugins actually ship — renaming the global
> constants of plugins already in production is not worth the churn. New
> plugins outside that family should still use a short slug.

---

## Composer PSR-4

```json
"autoload": {
	"psr-4": {
		"NVM\\{Plugin}\\": "src/"
	}
}
```

---

## Standards

- WordPress Coding Standards
- Tabs for indentation
- Braces on same line
