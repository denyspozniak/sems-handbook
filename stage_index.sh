#!/usr/bin/env bash
# Local mirror of the "Stage per-language index pages" step in
# .github/workflows/docs.yml. Run before `mkdocs build` locally so the
# language-switcher links resolve the same way they do on the site.
set -euo pipefail
cd "$(dirname "$0")"

cp docs/en/README.md docs/en/index.md
cp docs/uk/README.md docs/uk/index.md

sed -i '1i---\ntitle: SEMS Handbook — English\n---\n'    docs/en/index.md
sed -i '1i---\ntitle: SEMS Handbook — Українська\n---\n' docs/uk/index.md

sed -i -e 's|href="\.\./uk/"|href="uk/"|g' \
       -e 's|href="\.\./uk/README\.md"|href="uk/"|g'  docs/en/index.md
sed -i -e 's|href="\.\./en/"|href="../"|g' \
       -e 's|href="\.\./en/README\.md"|href="../"|g'  docs/uk/index.md
