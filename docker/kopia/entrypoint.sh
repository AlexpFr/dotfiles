#!/bin/sh
set -e
if [ "$KOPIA_SERVER_START" = "true" ]; then
    # --- Environment Defaults ---
    APP_USER=${APP_USER:-kopia}
    APP_GROUP=${APP_GROUP:-kopia}
    PUID=${PUID:-1000}
    PGID=${PGID:-1000}

    # --- ASCII Banner ---
    echo "  _  __           _       "
    echo " | |/ /___   __  (_) __ _ "
    echo " | ' // _ \\/  _ \\| |/ _\` |"
    echo " | . \\ (_) | |_) | | (_| |"
    echo " |_|\\_\\___/| .__/|_|\\__,_|"
    echo "           |_|            "
    echo " :: Kopia Docker Image :: "
    echo ""

    # --- Versions Retrieval ---
    DEBIAN_VER=$(cat /etc/debian_version)
    KOPIA_VER=$(kopia --version | head -n1 | awk '{print $1}')
    RCLONE_VER=$(rclone --version | head -n1 | awk '{print $2}')

    # --- Display Versions ---
    echo "📦 Versions:"
    printf "   %-8s %s\n" "Debian" "v$DEBIAN_VER"
    printf "   %-8s %s\n" "Kopia"  "v$KOPIA_VER"
    printf "   %-8s %s\n" "Rclone" "$RCLONE_VER"
    echo ""

KOPIA_UI_ENABLE_ARG="--ui"
[ "$KOPIA_UI_ENABLE" = "false" ] && KOPIA_UI_ENABLE_ARG="--no-ui"

    # --- Group Management ---
    if ! getent group "$PGID" >/dev/null 2>&1; then
        groupadd -g "$PGID" "$APP_GROUP"
    else
        APP_GROUP=$(getent group "$PGID" | cut -d: -f1)
    fi

    # --- User Management ---
    if ! id "$APP_USER" >/dev/null 2>&1; then
        useradd \
            -u "$PUID" \
            -g "$PGID" \
            -M \
            -s /usr/sbin/nologin \
            "$APP_USER"
    fi

    echo "───────────────────────────"
    echo "👤  User: $APP_USER ($(id -u "$APP_USER"))"
    echo "👥  Group: $APP_GROUP ($(id -g "$APP_GROUP"))"

    # Check if certificates exist
    if [ ! -f "$KOPIA_TLS_CERT_FILE" ] || [ ! -f "$KOPIA_TLS_KEY_FILE" ]; then
        echo "⚠️  Missing TLS certificates, starting server with --tls-generate-cert"
        echo "───────────────────────────"

        # echo "📁  Creating TLS certificate directory: $SSL_CERTS_DIR"
        chown -R "$PUID:$PGID" "$SSL_CERTS_DIR"
        chmod 700 "$SSL_CERTS_DIR"

        # Start server temporarily to generate certs
        # We use a subshell or temporary argument list to avoid polluting the final exec
        # gosu "$PUID:$PGID" /usr/local/bin/kopia server start $KOPIA_SERVER_ARGS --tls-generate-cert &
        CMD="gosu \"${PUID}:${PGID}\" /usr/local/bin/kopia server start $KOPIA_SERVER_ARGS $KOPIA_UI_ENABLE_ARG --address=$KOPIA_SERVER_LISTEN_ADRESS --tls-cert-file=$KOPIA_TLS_CERT_FILE --tls-key-file=${KOPIA_TLS_KEY_FILE}  --server-username=${KOPIA_SERVER_UI_USERNAME} --server-password=${KOPIA_SERVER_UI_PASSWORD} --tls-generate-cert > /dev/null &"
        eval "$CMD"
        KOPIA_PID=$!
        
        sleep 1
        
        # Wait for certificate generation log
        while ! kopia server status 2>&1 | grep -q -F "certificate"; do
            echo "🔄  TLS certificate not ready yet, waiting for generation..."
            sleep 5
        done

        echo "✅  Certificates generated, stopping server..."
        kill $KOPIA_PID 2>/dev/null || true
        wait $KOPIA_PID 2>/dev/null || true
        echo "🏁  Server stopped. Please restart the container if auto-restart is not enabled."
		echo ""
    else
        # --- Extract certificate fingerprint ---
        CERT_FINGERPRINT=$(openssl x509 -in "$KOPIA_TLS_CERT_FILE" -noout -fingerprint -sha256 2>/dev/null | sed 's/://g' | cut -f 2 -d =)
        
        if [ -n "$CERT_FINGERPRINT" ]; then
            export KOPIA_SERVER_CERT_FINGERPRINT="$CERT_FINGERPRINT"
            echo "🔑  Certificate fingerprint: $KOPIA_SERVER_CERT_FINGERPRINT"
            
            # Persist fingerprint for other processes (BASH_ENV trick)
            echo "export KOPIA_SERVER_CERT_FINGERPRINT='$KOPIA_SERVER_CERT_FINGERPRINT'" > "$BASH_ENV"
            chmod 644 "$BASH_ENV"
            
            echo "───────────────────────────"
            echo "🚀  Starting Kopia server..."
            # exec gosu "$PUID:$PGID" /usr/local/bin/kopia server start $KOPIA_SERVER_ARGS
            CMD="exec gosu \"${PUID}:${PGID}\" /usr/local/bin/kopia server start $KOPIA_SERVER_ARGS $KOPIA_UI_ENABLE_ARG --address=$KOPIA_SERVER_LISTEN_ADRESS --tls-cert-file=$KOPIA_TLS_CERT_FILE --tls-key-file=${KOPIA_TLS_KEY_FILE} --server-username=${KOPIA_SERVER_UI_USERNAME} --server-password=${KOPIA_SERVER_UI_PASSWORD}"
            echo "🔍 Executing: kopia server start $KOPIA_SERVER_ARGS" >&2
            eval "$CMD"
        else
            echo "❌  Could not extract certificate fingerprint, please check your TLS certificate."
            echo "───────────────────────────"
            echo "❌  Stopping container - Certificate error."
            exit 1
        fi
    fi
else
    exec "$@"
fi

# Notes:
# # Web UI (Browser) - EXPLICIT configuration until PR #4435 is merged
# # Using flags ensures this overrides any ambiguous env vars.
# --server-username=${KOPIA_SERVER_UI_USERNAME:?KOPIA_SERVER_UI_USERNAME is required}
# --server-password=${KOPIA_SERVER_UI_PASSWORD:?KOPIA_SERVER_UI_PASSWORD is required}