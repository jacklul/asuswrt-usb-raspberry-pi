#!/bin/sh

[ -f "/rom/jffs.json" ] || { echo "This script must run on the Asus router!"; exit 1; }

BRANCH="master"
TMP_DIR="/tmp/asuswrt-usb-raspberry-pi"

[ -n "$1" ] && BRANCH="$1"
[ -f "/usr/sbin/helper.sh" ] && MERLIN=1 && echo "Asuswrt-Merlin firmware detected"

set -e

[ ! -d "$TMP_DIR" ] && mkdir -vp "$TMP_DIR"

echo "Downloading required scripts..."

if [ -z "$MERLIN" ]; then
    [ ! -f "$TMP_DIR/scripts-startup.sh" ] && curl -fsS "https://raw.githubusercontent.com/jacklul/asuswrt-scripts/$BRANCH/scripts-startup.sh" -o "$TMP_DIR/scripts-startup.sh"
fi

[ ! -f "$TMP_DIR/usb-network.sh" ] && curl -fsS "https://raw.githubusercontent.com/jacklul/asuswrt-scripts/$BRANCH/scripts/usb-network.sh" -o "$TMP_DIR/usb-network.sh"
[ ! -f "$TMP_DIR/hotplug-event.sh" ] && curl -fsS "https://raw.githubusercontent.com/jacklul/asuswrt-scripts/$BRANCH/scripts/hotplug-event.sh" -o "$TMP_DIR/hotplug-event.sh"

echo "Setting permissions..."

chmod +x "$TMP_DIR/scripts-startup.sh" "$TMP_DIR/usb-network.sh" "$TMP_DIR/hotplug-event.sh"

echo "Moving files to /jffs..."

mkdir -vp "/jffs/scripts"

if [ -z "$MERLIN" ] && [ "$(md5sum "$TMP_DIR/scripts-startup.sh" | awk '{print $1}')" != "$(md5sum "/jffs/scripts-startup.sh" 2> /dev/null | awk '{print $1}')" ]; then
    cp -v "$TMP_DIR/scripts-startup.sh" "/jffs/scripts-startup.sh"
fi

if [ "$(md5sum "$TMP_DIR/usb-network.sh" | awk '{print $1}')" != "$(md5sum "/jffs/scripts/usb-network.sh" 2> /dev/null | awk '{print $1}')" ]; then
    cp -v "$TMP_DIR/usb-network.sh" "/jffs/scripts/usb-network.sh"
fi

if [ "$(md5sum "$TMP_DIR/hotplug-event.sh" | awk '{print $1}')" != "$(md5sum "/jffs/scripts/hotplug-event.sh" 2> /dev/null | awk '{print $1}')" ]; then
    cp -v "$TMP_DIR/hotplug-event.sh" "/jffs/scripts/hotplug-event.sh"
fi

if [ -z "$MERLIN" ]; then
    sh /jffs/scripts-startup.sh install
else
    COMMENT_LINE="# asuswrt-usb-raspberry-pi"

    echo "Adding entries to /jffs/scripts/services-start and /jffs/scripts/service-event-end)..."

    if [ ! -f /jffs/scripts/services-start ]; then
        cat <<EOT > /jffs/scripts/services-start
#!/bin/sh

EOT
        chmod 0755 /jffs/scripts/services-start
    fi

    if ! grep -q "$COMMENT_LINE" /jffs/scripts/services-start; then
        echo "/jffs/scripts/usb-network.sh start & $COMMENT_LINE" >> /jffs/scripts/services-start
        echo "/jffs/scripts/hotplug-event.sh start & $COMMENT_LINE" >> /jffs/scripts/services-start
    fi

    if [ ! -f /jffs/scripts/service-event-end ]; then
        cat <<EOT > /jffs/scripts/service-event-end
#!/bin/sh
# \$1 = event, \$2 = target

EOT
        chmod 0755 /jffs/scripts/service-event-end
    fi

    if ! grep -q "$COMMENT_LINE" /jffs/scripts/service-event-end; then
        cat <<EOT >> /jffs/scripts/service-event-end
case "\$2" in
    "allnet"|"net_and_phy"|"net"|"multipath"|"subnet"|"wan"|"wan_if"|"dslwan_if"|"dslwan_qis"|"dsl_wireless"|"wan_line"|"wan6"|"wan_connect"|"wan_disconnect"|"isp_meter")
        [ -x "/jffs/scripts/usb-network.sh" ] && /jffs/scripts/usb-network.sh run & $COMMENT_LINE
    ;;
esac
EOT
    fi
fi

rm -fr "$TMP_DIR"

echo "Finished!"
