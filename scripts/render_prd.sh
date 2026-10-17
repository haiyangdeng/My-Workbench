#!/bin/zsh
set -eu
PROJECT_ROOT="${0:A:h:h}"
RUNTIME_ROOT="/Users/ocean/.cache/codex-runtimes/codex-primary-runtime/dependencies"
mkdir -p "$PROJECT_ROOT/work/font-cache"
cat > "$PROJECT_ROOT/work/fonts.conf" <<XML
<?xml version="1.0"?>
<!DOCTYPE fontconfig SYSTEM "urn:fontconfig:fonts.dtd">
<fontconfig>
<dir>/System/Library/Fonts</dir>
<dir>/System/Library/Fonts/Supplemental</dir>
<dir>$RUNTIME_ROOT/native/libreoffice-headless/libreoffice/LibreOfficeDev.app/Contents/Resources/fonts/truetype</dir>
<cachedir>$PROJECT_ROOT/work/font-cache</cachedir>
</fontconfig>
XML
FONTCONFIG_FILE="$PROJECT_ROOT/work/fonts.conf" "$RUNTIME_ROOT/python/bin/python3" "/Users/ocean/.codex/plugins/cache/openai-primary-runtime/documents/26.905.11957/skills/documents/render_docx.py" "$PROJECT_ROOT/docs/AI员工工作台_PRD_v0.3.docx" --output_dir "$PROJECT_ROOT/work/prd-v03-render" --emit_pdf
