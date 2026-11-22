#!/usr/bin/env bash
# Runs the unittests of every example with ldc2.
# DDUI points at a ddui checkout, default ../../../ddui (next to this project).
set -euo pipefail
cd "$(dirname "$0")"
DDUI="${DDUI:-../../../ddui}"

for f in signals layout virtual panel dock undo mailbox render theme immediate; do
    echo "== $f"
    ldc2 -unittest -main -i -I. -run "$f.d"
done

echo "== builders (string import of panel.ui)"
ldc2 -unittest -main -i -I. -J. -run builders.d

echo "== widgets/button (string import of light.theme)"
ldc2 -unittest -main -i -I. -J. -run widgets/button.d

for f in panel_ddui hybrid bench; do
    echo "== $f (ddui at $DDUI)"
    ldc2 -unittest -main -i -I. -I"$DDUI/source" -run "$f.d"
done
