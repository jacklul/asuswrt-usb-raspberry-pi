#!/bin/sh

[ -f "/rom/jffs.json" ] || { echo "This script must run on the Asus router!"; exit 1; }

MERLIN=0
[ -f "/usr/sbin/helper.sh" ] && MERLIN=1 && echo "Merlin firmware detected"

set -e

echo "Downloading required scripts..."

[ "$MERLIN" = "0" ] && [ ! -f "/tmp/scripts-startup.sh" ] && curl -sf "https://raw.githubusercontent.com/jacklul/asuswrt-scripts/master/scripts-startup.sh" -o "/tmp/scripts-startup.sh"
[ ! -f "/tmp/usb-network.sh" ] && curl -sf "https://raw.githubusercontent.com/jacklul/asuswrt-scripts/master/scripts/usb-network.sh" -o "/tmp/usb-network.sh"
[ ! -f "/tmp/hotplug-event.sh" ] && curl -sf "https://raw.githubusercontent.com/jacklul/asuswrt-scripts/master/scripts/hotplug-event.sh" -o "/tmp/hotplug-event.sh"

COMMENT_LINE="# asuswrt-usb-raspberry-pi #"

if [ "$MERLIN" = "0" ]; then
    MODIFICATION="        $COMMENT_LINE
        {
            MOUNTED_PATHS=\"\$(df | grep /dev/sd | awk '{print \$NF}')\"

            if [ -n \"\$MOUNTED_PATHS\" ]; then
                for MOUNTED_PATH in \$MOUNTED_PATHS; do
                    [ ! -d \"\$MOUNTED_PATH/asuswrt-usb-network\" ] && continue
                    
                    logger -s -t \"\$SCRIPT_TAG\" \"Waiting for mount \$MOUNTED_PATH to be idle...\"

                    TIMER=0
                    while [ -n \"\$(lsof | grep \"\$MOUNTED_PATH\")\" ] && [ \"\$TIMER\" -lt \"60\" ] ; do
                        TIMER=\$((TIMER+1))
                        sleep 1
                    done

                    logger -s -t \"\$SCRIPT_TAG\" \"Writing mark to mount \$MOUNTED_PATH...\"
                    touch \"\$MOUNTED_PATH/asuswrt-usb-network-mark\" && sync
                    
                    if umount \"\$MOUNTED_PATH\"; then
                        rm -rf \"\$MOUNTED_PATH\"
                        logger -s -t \"\$SCRIPT_TAG\" \"Unmounted \$MOUNTED_PATH...\"
                    else
                        logger -s -t \"\$SCRIPT_TAG\" \"Failed to unmount \$MOUNTED_PATH\"
                    fi

                    break
                done
            else
                logger -s -t \"\$SCRIPT_TAG\" \"Could not find storage mount point\"
            fi
        } > /dev/null 2>&1 &
        $COMMENT_LINE
"

    echo "Modifying scripts-startup script..."

    if ! grep -q "$COMMENT_LINE" "/tmp/scripts-startup.sh"; then
        LINE="$(grep -Fn "f \"\$CHECK_FILE\" ]; then" "/tmp/scripts-startup.sh")"

        [ -z "$LINE" ] && { echo "Failed to modify /tmp/scripts-startup.sh - unable to find correct line"; exit 1; }

        LINE="$(echo "$LINE" | cut -d":" -f1)"
        LINE=$((LINE-1))
        MD5="$(md5sum "/tmp/scripts-startup.sh" | awk '{print $1}')"

        #shellcheck disable=SC2005
        echo "$({ head -n $((LINE)) /tmp/scripts-startup.sh; echo "$MODIFICATION"; tail -n +$((LINE+1)) /tmp/scripts-startup.sh; })" > /tmp/scripts-startup.sh

        [ "$MD5" = "$(md5sum "/tmp/scripts-startup.sh")" ] && { echo "Failed to modify /tmp/scripts-startup.sh - modification failed"; exit 1; }
    else
        echo "Seems like /tmp/scripts-startup.sh is already modified"
    fi
else
    [ ! -d /jffs/scripts ] && mkdir /jffs/scripts

    echo "Modifying custom scripts (/jffs/scripts/services-start and /jffs/scripts/service-event-end)..."

    if [ ! -f /jffs/scripts/services-start ]; then
        cat <<EOT > /jffs/scripts/services-start
#!/bin/sh

EOT
        chmod 0755 /jffs/scripts/services-start
    fi

    if ! grep -q "$COMMENT_LINE" /jffs/scripts/services-start; then
        echo "/jffs/scripts/usb-network.sh start $COMMENT_LINE" >> /jffs/scripts/services-start
        echo "/jffs/scripts/hotplug-event.sh start $COMMENT_LINE" >> /jffs/scripts/services-start
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
        [ -x "/jffs/scripts/usb-network.sh" ] && /jffs/scripts/usb-network.sh run $COMMENT_LINE
    ;;
esac
EOT
    fi
fi

echo "Setting permissions..."

chmod +x "/tmp/scripts-startup.sh" "/tmp/usb-network.sh" "/tmp/hotplug-event.sh"

echo "Moving files..."

mkdir -vp "/jffs/scripts"

if [ "$MERLIN" = "0" ] && [ "$(md5sum "/tmp/scripts-startup.sh" | awk '{print $1}')" != "$(md5sum "/jffs/scripts-startup.sh" | awk '{print $1}')" ]; then
    mv -v "/tmp/scripts-startup.sh" "/jffs/scripts-startup.sh"
else
    rm "/tmp/scripts-startup.sh"
fi

if [ "$(md5sum "/tmp/usb-network.sh" | awk '{print $1}')" != "$(md5sum "/jffs/scripts/usb-network.sh" | awk '{print $1}')" ]; then
    mv -v "/tmp/usb-network.sh" "/jffs/scripts/usb-network.sh"
else
    rm "/tmp/usb-network.sh"
fi

if [ "$(md5sum "/tmp/hotplug-event.sh" | awk '{print $1}')" != "$(md5sum "/jffs/scripts/hotplug-event.sh" | awk '{print $1}')" ]; then
    mv -v "/tmp/hotplug-event.sh" "/jffs/scripts/hotplug-event.sh"
else
    rm "/tmp/hotplug-event.sh"
fi

if [ "$MERLIN" = "0" ]; then
    echo "Running "scripts-startup.sh install"..."

    /jffs/scripts-startup.sh install
fi

echo "Finished!"
