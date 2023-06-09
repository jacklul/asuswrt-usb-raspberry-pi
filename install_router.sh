#!/bin/sh

[ -f "/rom/jffs.json" ] || { echo "This script must run on the Asus router!"; exit 1; }

MERLIN=0
[ -f "/usr/sbin/helper.sh" ] && MERLIN=1 && echo "Merlin firmware detected"

set -e

echo "Downloading required scripts..."

[ "$MERLIN" = "0" ] && [ ! -f "/tmp/startup.sh" ] && curl -sf "https://raw.githubusercontent.com/jacklul/asuswrt-scripts/master/startup.sh" -o "/tmp/startup.sh"
[ ! -f "/tmp/usb-network.sh" ] && curl -sf "https://raw.githubusercontent.com/jacklul/asuswrt-scripts/master/scripts/usb-network.sh" -o "/tmp/usb-network.sh"

COMMENT_LINE="# asuswrt-usb-raspberry-pi #"

if [ "$MERLIN" = "0" ]; then
    MODIFICATION="        $COMMENT_LINE
        MOUNTED_PATHS=\"\$(df | grep /dev/sd | awk '{print \$NF}')\"

        if [ -n \"\$MOUNTED_PATHS\" ]; then
            for MOUNTED_PATH in \$MOUNTED_PATHS; do
                touch \"\$MOUNTED_PATH/txt\"
            done
        else
            logger -s -t \"\$SCRIPT_NAME\" \"Could not find storage mount point\"
        fi

        sync
        ejusb -1 0
        $COMMENT_LINE
"

    echo "Modifying startup script..."

    if ! grep -q "$COMMENT_LINE" "/tmp/startup.sh"; then
        LINE="$(grep -Fn "f \"\$CHECK_FILE\" ]; then" "/tmp/startup.sh")"

        [ -z "$LINE" ] && { echo "Failed to modify /tmp/startup.sh - unable to find correct line"; exit 1; }

        LINE="$(echo "$LINE" | cut -d":" -f1)"
        LINE=$((LINE-1))
        MD5="$(md5sum "/tmp/startup.sh")"

        #shellcheck disable=SC2005
        echo "$({ head -n $((LINE)) /tmp/startup.sh; echo "$MODIFICATION"; tail -n +$((LINE+1)) /tmp/startup.sh; })" > /tmp/startup.sh

        [ "$MD5" = "$(md5sum "/tmp/startup.sh")" ] && { echo "Failed to modify /tmp/startup.sh - modification failed"; exit 1; }
    else
        echo "Seems like /tmp/startup.sh is already modified"
    fi
else
    [ ! -d /jffs/scripts ] && mkdir /jffs/scripts

    echo "Modifying custom scripts (/jffs/scripts/services-start and /jffs/scripts/service-event-end)..."

    SERVICES_START_LINE="/jffs/scripts/usb-network.sh start $COMMENT_LINE"
    SERVICE_EVENT_END_LINE="echo \"\$2\" | grep -q \"allnet\|net_and_phy\|net\|multipath\|subnet\|wan\|wan_if\|dslwan_if\|dslwan_qis\|dsl_wireless\|wan_line\|wan6\|wan_connect\|wan_disconnect\|isp_meter\" && /jffs/scripts/usb-network.sh start $COMMENT_LINE"

    if [ -f /jffs/scripts/services-start ]; then
        if ! grep -q "$COMMENT_LINE" /jffs/scripts/services-start; then
            echo "$SERVICES_START_LINE" >> /jffs/scripts/services-start
        fi
    else
        {
            echo "#!/bin/sh"
            echo ""
        } > /jffs/scripts/services-start
        echo "$SERVICES_START_LINE" >> /jffs/scripts/services-start
        chmod 0755 /jffs/scripts/services-start
    fi

    if [ -f /jffs/scripts/service-event-end ]; then
        if ! grep -q "$COMMENT_LINE" /jffs/scripts/service-event-end; then
            echo "$SERVICE_EVENT_END_LINE" >> /jffs/scripts/service-event-end
        fi
    else
        {
            echo "#!/bin/sh";
            echo "# \$1 = event, \$2 = target";
            echo "";
        } > /jffs/scripts/service-event-end

        echo "$SERVICE_EVENT_END_LINE" >> /jffs/scripts/service-event-end
        chmod 0755 /jffs/scripts/service-event-end
    fi
fi

echo "Setting permissions..."

chmod +x "/tmp/startup.sh" "/tmp/usb-network.sh"

echo "Moving files..."

mv -v "/tmp/startup.sh" "/jffs/startup.sh"
mkdir -vp "/jffs/scripts"
mv -v "/tmp/usb-network.sh" "/jffs/scripts/usb-network.sh"

if [ "$MERLIN" = "0" ]; then
    echo "Running "startup.sh install"..."

    /jffs/startup.sh install
fi

echo "Finished"
