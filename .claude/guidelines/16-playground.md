# WordPress Playground

> Disposable WordPress instances for rapid development and testing.

---

## Overview

WordPress Playground runs WordPress entirely in the browser or locally via CLI using WebAssembly and SQLite. It provides instant, ephemeral environments for testing plugins, themes, and demonstrations.

**Requirements**: Node.js 20.18+

---

## Quick Start

### Launch with Auto-Mount

From your plugin or theme directory:

```bash
npx @wp-playground/cli@latest server --auto-mount
```

Opens at `http://localhost:9400` with your plugin/theme automatically installed.

### Specify WordPress/PHP Versions

```bash
npx @wp-playground/cli@latest server \
	--auto-mount \
	--wp=6.5 \
	--php=8.2
```

---

## CLI Commands

### `server` — Local Development

```bash
# Basic server with auto-detection.
npx @wp-playground/cli@latest server --auto-mount

# Custom port.
npx @wp-playground/cli@latest server --auto-mount --port=8080

# Mount multiple plugins.
npx @wp-playground/cli@latest server \
	--mount=./my-plugin:/wordpress/wp-content/plugins/my-plugin \
	--mount=./another-plugin:/wordpress/wp-content/plugins/another-plugin
```

### `run-blueprint` — Execute Configuration

```bash
# Run a local blueprint.
npx @wp-playground/cli@latest run-blueprint --blueprint=./blueprint.json

# Run from URL.
npx @wp-playground/cli@latest run-blueprint --blueprint=https://example.com/blueprint.json
```

### `build-snapshot` — Create Shareable ZIP

```bash
npx @wp-playground/cli@latest build-snapshot \
	--blueprint=./blueprint.json \
	--outfile=./demo-site.zip
```

---

## Blueprints

Blueprints are JSON files that declaratively configure WordPress environments.

### Basic Blueprint

```json
{
	"$schema": "https://playground.wordpress.net/blueprint-schema.json",
	"landingPage": "/wp-admin/plugins.php",
	"preferredVersions": {
		"php": "8.2",
		"wp": "6.5"
	},
	"steps": [
		{
			"step": "login",
			"username": "admin",
			"password": "password"
		}
	]
}
```

### Install Plugin from Directory

```json
{
	"$schema": "https://playground.wordpress.net/blueprint-schema.json",
	"preferredVersions": {
		"php": "8.2",
		"wp": "latest"
	},
	"steps": [
		{
			"step": "installPlugin",
			"pluginData": {
				"resource": "url",
				"url": "https://downloads.wordpress.org/plugin/woocommerce.latest-stable.zip"
			}
		},
		{
			"step": "installPlugin",
			"pluginData": {
				"resource": "directory",
				"path": "."
			}
		},
		{
			"step": "login"
		}
	]
}
```

### Install Theme

```json
{
	"steps": [
		{
			"step": "installTheme",
			"themeData": {
				"resource": "wordpress.org/themes",
				"slug": "twentytwentyfour"
			}
		},
		{
			"step": "activateTheme",
			"themeFolderName": "twentytwentyfour"
		}
	]
}
```

### Configure WordPress Options

```json
{
	"steps": [
		{
			"step": "setSiteOptions",
			"options": {
				"blogname": "Test Site",
				"permalink_structure": "/%postname%/"
			}
		}
	]
}
```

### Import Database/Content

```json
{
	"steps": [
		{
			"step": "importWxr",
			"file": {
				"resource": "url",
				"url": "https://example.com/demo-content.xml"
			}
		}
	]
}
```

### Run PHP Code

```json
{
	"steps": [
		{
			"step": "runPHP",
			"code": "<?php update_option( 'woocommerce_currency', 'EUR' ); ?>"
		}
	]
}
```

---

## Project Blueprint Setup

Create `.wp-playground/blueprint.json` in your plugin root:

```json
{
	"$schema": "https://playground.wordpress.net/blueprint-schema.json",
	"landingPage": "/wp-admin/admin.php?page=nvm-inventory",
	"preferredVersions": {
		"php": "8.2",
		"wp": "6.5"
	},
	"steps": [
		{
			"step": "installPlugin",
			"pluginData": {
				"resource": "wordpress.org/plugins",
				"slug": "woocommerce"
			}
		},
		{
			"step": "installPlugin",
			"pluginData": {
				"resource": "directory",
				"path": "."
			}
		},
		{
			"step": "runPHP",
			"code": "<?php require_once 'wp-load.php'; update_option( 'woocommerce_onboarding_profile', [ 'skipped' => true ] ); ?>"
		},
		{
			"step": "login",
			"username": "admin",
			"password": "password"
		}
	]
}
```

Launch with:

```bash
npx @wp-playground/cli@latest server \
	--blueprint=./.wp-playground/blueprint.json \
	--mount=.:/wordpress/wp-content/plugins/nvm-inventory
```

---

## Debugging with Xdebug

```bash
npx @wp-playground/cli@latest server --auto-mount --xdebug
```

Configure your IDE (VS Code/PhpStorm) to connect to the displayed host/port.

---

## Browser-Only Usage

### URL Fragment

```
https://playground.wordpress.net/#{"preferredVersions":{"wp":"6.5"},"steps":[{"step":"login"}]}
```

### Query Parameter

```
https://playground.wordpress.net/?blueprint-url=https://example.com/blueprint.json
```

### Interactive Editor

Visit [playground.wordpress.net](https://playground.wordpress.net/) and use the Blueprint editor for visual configuration.

---

## Common Use Cases

### Testing Across WP Versions

```bash
# Test on WordPress 6.4.
npx @wp-playground/cli@latest server --auto-mount --wp=6.4

# Test on WordPress 6.5.
npx @wp-playground/cli@latest server --auto-mount --wp=6.5
```

### Testing Across PHP Versions

```bash
# Test on PHP 8.1.
npx @wp-playground/cli@latest server --auto-mount --php=8.1

# Test on PHP 8.2.
npx @wp-playground/cli@latest server --auto-mount --php=8.2
```

### Create Bug Report Demo

```bash
# Build a snapshot demonstrating the bug.
npx @wp-playground/cli@latest build-snapshot \
	--blueprint=./bug-demo.json \
	--outfile=./bug-report.zip
```

### CI/CD Testing

```yaml
# GitHub Actions example.
- name: Test in Playground
  run: |
    npx @wp-playground/cli@latest run-blueprint \
      --blueprint=./test-blueprint.json
```

---

## Troubleshooting

| Issue | Solution |
|-------|----------|
| Node version error | Verify `node -v` returns 20.18+ |
| Plugin not detected | Use absolute paths with `--mount` |
| Assets not loading | Add `--blueprint-may-read-adjacent-files` |
| Port in use | Specify `--port=<available-port>` |
| Blueprint errors | Validate JSON against schema |

---

## Limitations

Playground is designed for rapid testing, not production:

- Uses SQLite instead of MySQL (some queries may behave differently)
- No persistent storage (data lost on restart)
- Limited PHP extension support
- No external network access by default
- Cannot replicate complex server configurations

For full MySQL/production parity, use `wp-env` or Docker-based setups.

---

## npm Scripts Integration

Add to `package.json`:

```json
{
	"scripts": {
		"playground": "npx @wp-playground/cli@latest server --auto-mount",
		"playground:wc": "npx @wp-playground/cli@latest server --blueprint=./.wp-playground/blueprint.json --mount=.:/wordpress/wp-content/plugins/nvm-inventory",
		"playground:snapshot": "npx @wp-playground/cli@latest build-snapshot --blueprint=./.wp-playground/blueprint.json --outfile=./demo.zip"
	}
}
```

Usage:

```bash
npm run playground
npm run playground:wc
npm run playground:snapshot
```
