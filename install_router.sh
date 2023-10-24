#!/bin/sh

[ -f "/rom/jffs.json" ] || { echo "This script must run on the Asus router!"; exit 1; }

MERLIN=0
[ -f "/usr/sbin/helper.sh" ] && MERLIN=1 && echo "Merlin firmware detected"

set -e

echo "Downloading required scripts..."

[ "$MERLIN" = "0" ] && [ ! -f "/tmp/scripts-startup.sh" ] && curl -sf "https://raw.githubusercontent.com/jacklul/asuswrt-scripts/master/scripts-startup.sh" -o "/tmp/scripts-startup.sh"
[ ! -f "/tmp/usb-network.sh" ] && curl -sf "https://raw.githubusercontent.com/jacklul/asuswrt-scripts/master/scripts/usb-network.sh" -o "/tmp/usb-network.sh"

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
        MD5="$(md5sum "/tmp/scripts-startup.sh")"

        #shellcheck disable=SC2005
        echo "$({ head -n $((LINE)) /tmp/scripts-startup.sh; echo "$MODIFICATION"; tail -n +$((LINE+1)) /tmp/scripts-startup.sh; })" > /tmp/scripts-startup.sh

        [ "$MD5" = "$(md5sum "/tmp/scripts-startup.sh")" ] && { echo "Failed to modify /tmp/scripts-startup.sh - modification failed"; exit 1; }
    else
        echo "Seems like /tmp/scripts-startup.sh is already modified"
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

chmod +x "/tmp/scripts-startup.sh" "/tmp/usb-network.sh"

echo "Moving files..."

mv -v "/tmp/scripts-startup.sh" "/jffs/scripts-startup.sh"
mkdir -vp "/jffs/scripts"
mv -v "/tmp/usb-network.sh" "/jffs/scripts/usb-network.sh"

if [ "$MERLIN" = "0" ]; then
    echo "Running "scripts-startup.sh install"..."

    /jffs/scripts-startup.sh install
fi

echo "Finished"
