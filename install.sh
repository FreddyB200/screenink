#!/bin/bash
# Compila ScreenInk, lo instala en ~/bin y lo registra para arrancar solo al iniciar sesión.
# Se puede volver a ejecutar cada vez que cambies el código (reemplaza la versión anterior).
set -e

DIR="$(cd "$(dirname "$0")" && pwd)"
BIN="$HOME/bin/ScreenInk"
LABEL="local.screenink"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"

cd "$DIR"
swiftc -O *.swift -o ScreenInk.build

mkdir -p "$HOME/bin" "$HOME/Library/LaunchAgents"
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
pkill -x ScreenInk 2>/dev/null || true
sleep 0.5
mv -f ScreenInk.build "$BIN"

cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>$LABEL</string>
    <key>ProgramArguments</key><array><string>$BIN</string></array>
    <key>RunAtLoad</key><true/>
    <key>KeepAlive</key><dict><key>SuccessfulExit</key><false/></dict>
    <key>ProcessType</key><string>Interactive</string>
</dict>
</plist>
EOF

launchctl bootstrap "gui/$(id -u)" "$PLIST"
echo "Listo: ScreenInk instalado en $BIN y activo al iniciar sesión."
