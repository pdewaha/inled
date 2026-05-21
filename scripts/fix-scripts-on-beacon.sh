#!/bin/bash
# Run ON beacon once: strips Windows CRLF from all scripts/*.sh
DIR="$(cd "$(dirname "$0")" && pwd)"
for f in "$DIR"/*.sh; do
  sed -i 's/\r$//' "$f"
  chmod +x "$f"
done
echo "Fixed: $DIR/*.sh"
