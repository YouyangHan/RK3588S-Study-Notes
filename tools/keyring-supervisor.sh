#!/bin/bash
# Keep a gnome-keyring daemon started with --login (unlocked login keyring)
# running and serving org.freedesktop.secrets.
systemctl --user stop --no-block gnome-keyring-daemon.service gnome-keyring-daemon.socket
sleep 1

COLLECTION=/org/freedesktop/secrets/collection/login

while true; do
    killall -q gnome-keyring-daemon 2>/dev/null
    sleep 1

    printf '%s\n' "$KEYRING_PASSWORD" | \
        /usr/bin/gnome-keyring-daemon --foreground --login \
            --components=pkcs11,secrets \
            --control-directory="$XDG_RUNTIME_DIR/keyring" &
    pid=$!

    ok=0
    for i in $(seq 1 10); do
        sleep 1
        kill -0 "$pid" 2>/dev/null || break
        locked=$(busctl --user get-property org.freedesktop.secrets "$COLLECTION" \
                     org.freedesktop.Secret.Collection Locked 2>/dev/null)
        if [ "$locked" = "b false" ]; then
            ok=1
            break
        fi
    done

    if [ "$ok" = "1" ]; then
        # keyring ready and unlocked -> let RDP pick up fresh credentials
        systemctl --user restart gnome-remote-desktop.service
        wait "$pid"
    else
        kill "$pid" 2>/dev/null
    fi
    sleep 1
done
