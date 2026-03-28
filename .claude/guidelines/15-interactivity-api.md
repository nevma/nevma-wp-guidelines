# Interactivity API

> Modern frontend interactivity for WordPress blocks using `data-wp-*` directives.

---

## Overview

The Interactivity API is WordPress's native solution for adding frontend interactivity to blocks without heavy JavaScript frameworks. It uses HTML directives and a reactive store system.

**Requirements**: WordPress 6.5+

---

## When to Use

| Use Interactivity API | Use Vanilla JS |
|-----------------------|----------------|
| Gutenberg blocks needing reactivity | Non-block frontend features |
| Server-rendered content with client hydration | Simple event handlers |
| Shared state between multiple blocks | Admin-only functionality |
| Complex UI interactions (accordions, modals, filters) | AJAX form submissions |

---

## Block Integration

### Enable in `block.json`

```json
{
	"$schema": "https://schemas.wp.org/trunk/block.json",
	"apiVersion": 3,
	"name": "nvm/accordion",
	"title": "Accordion",
	"supports": {
		"interactivity": true
	},
	"viewScriptModule": "file:./view.js"
}
```

**Note**: Use `viewScriptModule` (ES module) instead of `viewScript` for Interactivity API blocks.

---

## Directives Reference

| Directive | Purpose | Example |
|-----------|---------|---------|
| `data-wp-interactive` | Root element, defines namespace | `data-wp-interactive="nvm/accordion"` |
| `data-wp-context` | Scoped local state for subtree | `data-wp-context='{"isOpen": false}'` |
| `data-wp-on--{event}` | Event handler binding | `data-wp-on--click="actions.toggle"` |
| `data-wp-bind--{attr}` | Bind state to HTML attribute | `data-wp-bind--aria-expanded="context.isOpen"` |
| `data-wp-class--{name}` | Toggle CSS class based on state | `data-wp-class--is-open="context.isOpen"` |
| `data-wp-text` | Set element text content | `data-wp-text="state.message"` |
| `data-wp-watch` | Run callback when dependencies change | `data-wp-watch="callbacks.logChange"` |

---

## Server-Side Rendering (PHP)

### Initialize Global State

```php
<?php
declare( strict_types=1 );

namespace NVM\Accordion;

/**
 * Register interactivity state for the accordion block.
 *
 * @since 1.0.0
 */
function register_interactivity_state(): void {
	wp_interactivity_state(
		'nvm/accordion',
		[
			'globalCount' => 0,
		]
	);
}
add_action( 'wp_interactivity_initial_state', __NAMESPACE__ . '\\register_interactivity_state' );
```

### Render Block with Context

```php
<?php
/**
 * Render callback for the accordion block.
 *
 * @param array<string, mixed> $attributes Block attributes.
 * @return string
 */
function render_accordion_block( array $attributes ): string {
	$context = [
		'isOpen' => false,
	];

	$wrapper_attributes = get_block_wrapper_attributes();

	ob_start();
	?>
	<div
		<?php echo $wrapper_attributes; // phpcs:ignore WordPress.Security.EscapeOutput.OutputNotEscaped ?>
		data-wp-interactive="nvm/accordion"
		<?php echo wp_interactivity_data_wp_context( $context ); // phpcs:ignore WordPress.Security.EscapeOutput.OutputNotEscaped ?>
	>
		<button
			class="nvm-accordion__trigger"
			data-wp-on--click="actions.toggle"
			data-wp-bind--aria-expanded="context.isOpen"
		>
			<?php echo esc_html( $attributes['title'] ?? __( 'Toggle', 'nvm-accordion' ) ); ?>
		</button>
		<div
			class="nvm-accordion__content"
			data-wp-class--is-open="context.isOpen"
			data-wp-bind--hidden="!context.isOpen"
		>
			<InnerBlocks.Content />
		</div>
	</div>
	<?php
	return ob_get_clean();
}
```

---

## Client-Side Store (JavaScript)

### Basic Store Structure

```javascript
/**
 * Accordion block interactivity.
 *
 * @since 1.0.0
 */
import { store, getContext } from '@wordpress/interactivity';

store( 'nvm/accordion', {
	state: {
		get globalCount() {
			return store( 'nvm/accordion' ).state.globalCount;
		},
	},

	actions: {
		toggle() {
			const context = getContext();
			context.isOpen = ! context.isOpen;
		},

		open() {
			const context = getContext();
			context.isOpen = true;
		},

		close() {
			const context = getContext();
			context.isOpen = false;
		},
	},

	callbacks: {
		logState() {
			const context = getContext();
			// Runs when dependencies change.
			console.log( 'Accordion state:', context.isOpen );
		},
	},
} );
```

### Async Actions

```javascript
import { store, getContext } from '@wordpress/interactivity';

store( 'nvm/product-filter', {
	state: {
		isLoading: false,
		products: [],
	},

	actions: {
		*fetchProducts() {
			const context = getContext();
			const state = store( 'nvm/product-filter' ).state;

			state.isLoading = true;

			try {
				const response = yield fetch( `/wp-json/nvm/v1/products?category=${ context.categoryId }` );
				const data = yield response.json();
				state.products = data;
			} catch ( error ) {
				console.error( '[NVM Product Filter]', error );
			} finally {
				state.isLoading = false;
			}
		},
	},
} );
```

---

## Derived State

For computed values, define them in both PHP (SSR) and JavaScript (client):

### PHP Side

```php
wp_interactivity_state(
	'nvm/cart',
	[
		'items'    => $cart_items,
		'hasItems' => static fn() => count( wp_interactivity_state( 'nvm/cart' )['items'] ) > 0,
		'total'    => static fn() => array_reduce(
			wp_interactivity_state( 'nvm/cart' )['items'],
			static fn( $sum, $item ) => $sum + $item['price'],
			0
		),
	]
);
```

### JavaScript Side

```javascript
store( 'nvm/cart', {
	state: {
		items: [],
		get hasItems() {
			return this.items.length > 0;
		},
		get total() {
			return this.items.reduce( ( sum, item ) => sum + item.price, 0 );
		},
	},
} );
```

---

## Common Patterns

### Click Outside to Close

```html
<div
	data-wp-interactive="nvm/dropdown"
	data-wp-context='{"isOpen": false}'
	data-wp-on-document--click="actions.handleClickOutside"
>
	<button data-wp-on--click="actions.toggle">Menu</button>
	<div data-wp-bind--hidden="!context.isOpen">
		<!-- Dropdown content -->
	</div>
</div>
```

```javascript
store( 'nvm/dropdown', {
	actions: {
		toggle() {
			const context = getContext();
			context.isOpen = ! context.isOpen;
		},
		handleClickOutside( event ) {
			const context = getContext();
			const { ref } = getElement();

			if ( context.isOpen && ! ref.contains( event.target ) ) {
				context.isOpen = false;
			}
		},
	},
} );
```

### Keyboard Navigation

```html
<div
	data-wp-interactive="nvm/tabs"
	data-wp-on-window--keydown="actions.handleKeydown"
>
```

---

## Troubleshooting

| Issue | Solution |
|-------|----------|
| Directives not working | Verify `data-wp-interactive` is on root element |
| Hydration mismatch/flicker | Align server HTML with client state; define derived state in PHP |
| State not updating | Check namespace matches between PHP and JS |
| Events not firing | Ensure `viewScriptModule` is used (not `viewScript`) |
| Multiple blocks conflicting | Use unique namespaces per block |

---

## Debug Checklist

1. Block has `"supports": { "interactivity": true }` in `block.json`
2. Using `viewScriptModule` for the client script
3. `data-wp-interactive="namespace"` present on root element
4. Namespace in JS store matches the directive namespace
5. Initial state set via `wp_interactivity_state()` in PHP
6. No JavaScript errors in console before hydration

---

## Summary

| Component | PHP | JavaScript |
|-----------|-----|------------|
| Global state | `wp_interactivity_state()` | `store( namespace, { state: {} } )` |
| Local context | `wp_interactivity_data_wp_context()` | `getContext()` |
| Derived values | Closures in state array | Getters in state object |
| Event handlers | Directives in HTML | `actions` in store |
