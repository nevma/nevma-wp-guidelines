#!/bin/bash
#
# Add AI guidelines as a git submodule to a project
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/mocassinis/ai-guidelines/main/setup.sh | bash
#
# Or from local clone:
#   ./setup.sh /path/to/your-project

set -e

REPO="git@github.com:mocassinis/ai-guidelines.git"
SUBMODULE_DIR=".claude-guidelines"
SYMLINK=".claude"

# Determine target directory
TARGET="${1:-.}"

# Resolve to absolute path
TARGET="$(cd "$TARGET" && pwd)"

echo "Setting up AI guidelines in: $TARGET"

# Check if target is a git repo
if [ ! -d "$TARGET/.git" ]; then
    echo "Error: $TARGET is not a git repository"
    exit 1
fi

cd "$TARGET"

# Check if already set up
if [ -d "$SUBMODULE_DIR" ]; then
    echo "Submodule already exists. Updating..."
    cd "$SUBMODULE_DIR"
    git pull origin main
    cd ..
    echo "Updated to latest version."
    exit 0
fi

# Check if .claude already exists
if [ -e "$SYMLINK" ]; then
    echo "Error: $SYMLINK already exists. Remove it first."
    exit 1
fi

# Add submodule
echo "Adding submodule..."
git submodule add "$REPO" "$SUBMODULE_DIR"

# Create symlink
echo "Creating symlink..."
ln -s "$SUBMODULE_DIR/.claude" "$SYMLINK"

# Stage symlink
git add "$SYMLINK"

echo ""
echo "Done! AI guidelines installed."
echo ""
echo "Files added:"
echo "  $SUBMODULE_DIR/  (submodule)"
echo "  $SYMLINK         (symlink)"
echo ""
echo "Next steps:"
echo "  git commit -m 'Add AI guidelines submodule'"
echo ""
echo "To update later:"
echo "  cd $SUBMODULE_DIR && git pull origin main"
