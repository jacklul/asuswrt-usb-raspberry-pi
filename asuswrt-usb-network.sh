#!/bin/bash
# Made by Jack'lul <jacklul.github.io>
#
# This script allows connecting Raspberry Pi to stock
# Asus router using USB Ethernet Gadget
#
# For more information, see:
# https://github.com/jacklul/asuswrt-usb-raspberry-pi
#

# shellcheck disable=2155,1090

# Configuration variables
NETWORK_FUNCTION="ecm"
VERIFY_CONNECTION=true
SKIP_MASS_STORAGE=false
FAKE_ASUS_OPTWARE=false
FAKE_ASUS_OPTWARE_ARCH="arm"
TEMP_IMAGE_FILE="/tmp/asuswrt-usb-network.img"
TEMP_IMAGE_SIZE=1
TEMP_IMAGE_FS="ext2"
TEMP_IMAGE_DELETE=true
WAIT_TIMEOUT=90
WAIT_RETRY=0
WAIT_SLEEP=1
VERIFY_TIMEOUT=60
VERIFY_SLEEP=1
GADGET_ID="usbnet"
GADGET_PRODUCT="$(tr -d '\0' < /sys/firmware/devicetree/base/model) USB Gadget"
GADGET_MANUFACTURER="Raspberry Pi Foundation"
GADGET_SERIAL="$(grep Serial /proc/cpuinfo | sed 's/Serial\s*: 0000\(\w*\)/\1/')"
GADGET_VENDOR_ID="0x1d6b"
GADGET_PRODUCT_ID="0x0104"
GADGET_USB_VERSION="0x0200"
GADGET_DEVICE_VERSION="0x0100"
GADGET_DEVICE_CLASS="0xef"
GADGET_DEVICE_SUBCLASS="0x02"
GADGET_DEVICE_PROTOCOL="0x01"
GADGET_MAX_PACKET_SIZE="0x40"
GADGET_MAX_POWER="250"
GADGET_ATTRIBUTES="0x80"
GADGET_MAC_VENDOR="B8:27:EB"
GADGET_MAC_HOST=""
GADGET_MAC_DEVICE=""
GADGET_STORAGE_FILE=""
GADGET_STORAGE_FILE_CHECK=true
GADGET_STORAGE_STALL=""
GADGET_STORAGE_REMOVABLE=""
GADGET_STORAGE_CDROM=""
GADGET_STORAGE_RO=""
GADGET_STORAGE_NOFUA=""
GADGET_STORAGE_INQUIRY_STRING=""
GADGET_SCRIPT=""

readonly CONFIG_FILE="/etc/asuswrt-usb-network.conf"
if [ -f "$CONFIG_FILE" ]; then
    [ ! -r "$CONFIG_FILE" ] && { echo "Unable to read $CONFIG_FILE"; exit 1; }

    . "$CONFIG_FILE"
fi

readonly CONFIGFS_DEVICE_PATH="/sys/kernel/config/usb_gadget/$GADGET_ID"

##################################################

require_root() {
    [ "$UID" -eq 0 ] || { echo "This script must run as root!"; exit 1; }
}

init_gadget() {
    local CONFIG="$1"

    if [ -d "$CONFIGFS_DEVICE_PATH" ]; then
        [ -n "$(cat "$CONFIGFS_DEVICE_PATH/UDC")" ] && { echo "Gadget \"$GADGET_ID\" is already up"; exit 16; }

        echo "Cleaning up old gadget \"$GADGET_ID\"...";
        gadget_down silent && gadget_cleanup silent
    fi

    modprobe libcomposite

    mkdir "$CONFIGFS_DEVICE_PATH"

    echo "$GADGET_VENDOR_ID" > "$CONFIGFS_DEVICE_PATH/idVendor"
    echo "$GADGET_PRODUCT_ID" > "$CONFIGFS_DEVICE_PATH/idProduct"
    echo "$GADGET_USB_VERSION" > "$CONFIGFS_DEVICE_PATH/bcdUSB"
    echo "$GADGET_DEVICE_VERSION" > "$CONFIGFS_DEVICE_PATH/bcdDevice"
    echo "$GADGET_DEVICE_CLASS" > "$CONFIGFS_DEVICE_PATH/bDeviceClass"
    echo "$GADGET_DEVICE_SUBCLASS" > "$CONFIGFS_DEVICE_PATH/bDeviceSubClass"
    echo "$GADGET_DEVICE_PROTOCOL" > "$CONFIGFS_DEVICE_PATH/bDeviceProtocol"
    echo "$GADGET_MAX_PACKET_SIZE" > "$CONFIGFS_DEVICE_PATH/bMaxPacketSize0"

    # 0x409 = english
    mkdir "$CONFIGFS_DEVICE_PATH/strings/0x409"
    echo "$GADGET_PRODUCT" > "$CONFIGFS_DEVICE_PATH/strings/0x409/product"
    echo "$GADGET_MANUFACTURER" > "$CONFIGFS_DEVICE_PATH/strings/0x409/manufacturer"
    echo "$GADGET_SERIAL" > "$CONFIGFS_DEVICE_PATH/strings/0x409/serialnumber"

    mkdir "$CONFIGFS_DEVICE_PATH/configs/$CONFIG"
    echo "$GADGET_MAX_POWER" > "$CONFIGFS_DEVICE_PATH/configs/$CONFIG/MaxPower"
    echo "$GADGET_ATTRIBUTES" > "$CONFIGFS_DEVICE_PATH/configs/$CONFIG/bmAttributes"
    mkdir "$CONFIGFS_DEVICE_PATH/configs/$CONFIG/strings/0x409"
}

set_configuration_string() {
    local CONFIG="$1"
    local STRING="$2"
    local CURRENT="$(cat "$CONFIGFS_DEVICE_PATH/configs/$CONFIG/strings/0x409/configuration")"

    if [ ! -f "$CONFIGFS_DEVICE_PATH/configs/$CONFIG/strings/0x409/configuration" ] || [ -z "$CURRENT" ]; then
        echo "$STRING" > "$CONFIGFS_DEVICE_PATH/configs/$CONFIG/strings/0x409/configuration"
    else
        echo "$CURRENT + $STRING" > "$CONFIGFS_DEVICE_PATH/configs/$CONFIG/strings/0x409/configuration"
    fi
}

add_function() {
    local FUNCTION="${1,,}"
    local CONFIG="c.1"
    local INSTANCE="0"
    local LUN_INSTANCE="0"
    local ARGUMENT="$2"

    if [ ! -d "$CONFIGFS_DEVICE_PATH/functions" ]; then
        init_gadget "$CONFIG"
    fi

    case "$FUNCTION" in
        "ecm"|"rndis"|"eem"|"ncm")
            mkdir "$CONFIGFS_DEVICE_PATH/functions/$FUNCTION.$INSTANCE"

            generate_mac_addresses

            echo "$GADGET_MAC_HOST"  > "$CONFIGFS_DEVICE_PATH/functions/$FUNCTION.$INSTANCE/dev_addr"
            echo "$GADGET_MAC_DEVICE" > "$CONFIGFS_DEVICE_PATH/functions/$FUNCTION.$INSTANCE/host_addr"

            set_configuration_string "$CONFIG" "${FUNCTION^^}"

            ln -s "$CONFIGFS_DEVICE_PATH/functions/$FUNCTION.$INSTANCE" "$CONFIGFS_DEVICE_PATH/configs/$CONFIG"
        ;;
        "mass_storage")
            [ -z "$ARGUMENT" ] && { echo "Image file not provided"; exit 22; }
            [ ! -f "$ARGUMENT" ] && { echo "Image file does not exist: $ARGUMENT"; exit 2; }

            mkdir "$CONFIGFS_DEVICE_PATH/functions/mass_storage.$INSTANCE"

            [ -n "$GADGET_STORAGE_STALL" ] && echo "$GADGET_STORAGE_STALL" > "$CONFIGFS_DEVICE_PATH/functions/mass_storage.$INSTANCE/stall"

            [ ! -d "$CONFIGFS_DEVICE_PATH/functions/mass_storage.$INSTANCE/lun.$LUN_INSTANCE" ] && mkdir "$CONFIGFS_DEVICE_PATH/functions/mass_storage.$INSTANCE/lun.$LUN_INSTANCE"

            echo "$ARGUMENT" > "$CONFIGFS_DEVICE_PATH/functions/mass_storage.$INSTANCE/lun.$LUN_INSTANCE/file"

            [ -n "$GADGET_STORAGE_REMOVABLE" ] && echo "$GADGET_STORAGE_REMOVABLE" > "$CONFIGFS_DEVICE_PATH/functions/mass_storage.$INSTANCE/lun.$LUN_INSTANCE/removable"
            [ -n "$GADGET_STORAGE_CDROM" ] && echo "$GADGET_STORAGE_CDROM" > "$CONFIGFS_DEVICE_PATH/functions/mass_storage.$INSTANCE/lun.$LUN_INSTANCE/cdrom"
            [ -n "$GADGET_STORAGE_RO" ] && echo "$GADGET_STORAGE_RO" > "$CONFIGFS_DEVICE_PATH/functions/mass_storage.$INSTANCE/lun.$LUN_INSTANCE/ro"
            [ -n "$GADGET_STORAGE_NOFUA" ] && echo "$GADGET_STORAGE_NOFUA" > "$CONFIGFS_DEVICE_PATH/functions/mass_storage.$INSTANCE/lun.$LUN_INSTANCE/nofua"
            [ -n "$GADGET_STORAGE_REMOVABLE" ] && echo "$GADGET_STORAGE_INQUIRY_STRING" > "$CONFIGFS_DEVICE_PATH/functions/mass_storage.$INSTANCE/lun.$LUN_INSTANCE/inquiry_string"

            set_configuration_string "$CONFIG" "Mass Storage"

            ln -s "$CONFIGFS_DEVICE_PATH/functions/mass_storage.$INSTANCE" "$CONFIGFS_DEVICE_PATH/configs/$CONFIG"
        ;;
        *)
            echo "Invalid function specified: $FUNCTION"
            exit 22
        ;;
    esac
}

gadget_up() {
    udevadm settle -t 5 || :
    ls /sys/class/udc > "$CONFIGFS_DEVICE_PATH/UDC"

    local INSTANCE_NET=$(find $CONFIGFS_DEVICE_PATH/functions/ -maxdepth 2 -name "ifname" | grep -o '/*[^.]*/$' || echo "")

    if [ -n "$INSTANCE_NET" ] && [ -f "$CONFIGFS_DEVICE_PATH/functions/$INSTANCE_NET/ifname" ]; then
        local INTERFACE="$(cat "$CONFIGFS_DEVICE_PATH/functions/$INSTANCE_NET/ifname")"

        ifconfig "$INTERFACE" up
    fi
}

gadget_down() {
    if [ -d "$CONFIGFS_DEVICE_PATH" ]; then
        [ "$1" != "silent" ] && echo "Taking down gadget \"$GADGET_ID\"...";

        [ -n "$(cat "$CONFIGFS_DEVICE_PATH/UDC")" ] && echo "" > "$CONFIGFS_DEVICE_PATH/UDC"

        local INSTANCE_NET=$(find $CONFIGFS_DEVICE_PATH/functions/ -maxdepth 2 -name "ifname" | grep -o '/*[^.]*/$' || echo "")

        if [ -n "$INSTANCE_NET" ] && [ -f "$CONFIGFS_DEVICE_PATH/functions/$INSTANCE_NET/ifname" ]; then
            local INTERFACE="$(cat "$CONFIGFS_DEVICE_PATH/functions/$INSTANCE_NET/ifname")"

            [ -d "/sys/class/net/$INTERFACE" ] && ifconfig "$INTERFACE" down
        fi
    else
        echo "Gadget \"$GADGET_ID\" is already down"
        return 19
    fi
}

gadget_cleanup() {
    if [ -d "$CONFIGFS_DEVICE_PATH" ]; then
        [ "$1" != "silent" ] && echo "Cleaning up gadget \"$GADGET_ID\"...";

        find $CONFIGFS_DEVICE_PATH/configs/*/* -maxdepth 0 -type l -exec rm {} \; 2> /dev/null || true
        find $CONFIGFS_DEVICE_PATH/configs/*/strings/* -maxdepth 0 -type d -exec rmdir {} \; 2> /dev/null || true
        find $CONFIGFS_DEVICE_PATH/os_desc/* -maxdepth 0 -type l -exec rm {} \; 2> /dev/null || true
        find $CONFIGFS_DEVICE_PATH/functions/* -maxdepth 0 -type d -exec rmdir {} \; 2> /dev/null || true
        find $CONFIGFS_DEVICE_PATH/strings/* -maxdepth 0 -type d -exec rmdir {} \; 2> /dev/null || true
        find $CONFIGFS_DEVICE_PATH/configs/* -maxdepth 0 -type d -exec rmdir {} \; 2> /dev/null || true

        rmdir "$CONFIGFS_DEVICE_PATH" 2> /dev/null
    fi
}

generate_mac_addresses() {
    local GADGET_SERIAL="${GADGET_SERIAL^^}"

    [ -z "$GADGET_MAC_DEVICE" ] && GADGET_MAC_DEVICE="02:$(echo "$GADGET_SERIAL" | sed 's/\(\w\w\)/:\1/g' | cut -b 5-)"

    if [ "$(echo "$GADGET_MAC_DEVICE" | awk -F":" '{print NF-1}')" != "5" ]; then
        echo "Invalid device MAC address: $GADGET_MAC_DEVICE"
        exit 22
    fi

    if [ -z "$GADGET_MAC_HOST" ]; then
        if [ "$(echo "$GADGET_MAC_VENDOR" | awk -F":" '{print NF-1}')" != "2" ]; then
            echo "Invalid value for \"GADGET_MAC_VENDOR\" variable!"
            exit 22
        fi

        GADGET_MAC_HOST="${GADGET_MAC_VENDOR^^}:$(echo "$GADGET_SERIAL" | sed 's/\(\w\w\)/:\1/g' | cut -b 11-)"
    fi

    if [ "$(echo "$GADGET_MAC_HOST" | awk -F":" '{print NF-1}')" != "5" ]; then
        echo "Invalid host MAC address: $GADGET_MAC_HOST"
        exit 22
    fi
}

is_started() {
    if [ -d "$CONFIGFS_DEVICE_PATH" ]; then
        local INSTANCE_NET=$(find "/sys/kernel/config/usb_gadget/$GADGET_ID/functions" -maxdepth 2 -name "ifname" || echo "")

        [ -n "$INSTANCE_NET" ] && return 0
    fi

    return 1
}

create_image() {
    local FILE="$1"
    local SIZE="$2"
    local FILESYSTEM="$3"

    command -v "mkfs.$FILESYSTEM" >/dev/null 2>&1 || { echo "Function \"mkfs.$FILESYSTEM\" not found"; exit 2; }

    echo "Creating image file \"$FILE\" ($FILESYSTEM, ${SIZE}M)..."

    { DD_OUTPUT=$(dd if=/dev/zero of="$FILE" bs="1M" count="$SIZE" 2>&1); } || { echo "$DD_OUTPUT"; exit 1; }
    { MKFS_OUTPUT=$("mkfs.$FILESYSTEM" "$FILE" 2>&1); } || { echo "$MKFS_OUTPUT"; exit 1; }

    mkdir -p "$FILE-mnt"
    mount "$FILE" "$FILE-mnt"

    mkdir "$FILE-mnt/asuswrt-usb-network"

    if [ "$FAKE_ASUS_OPTWARE" = true ]; then
        create_fake_asus_optware "$FILE-mnt"
    fi

    umount "$FILE-mnt"
    rmdir "$FILE-mnt"
}

create_fake_asus_optware() {
    local DESTINATION_PATH="$1"

    [ ! -d "$DESTINATION_PATH" ] && { echo "Destination path does not exist"; exit 2; }

    echo "Creating fake Asus Optware installation..."

    mkdir -p "$DESTINATION_PATH/asusware.$FAKE_ASUS_OPTWARE_ARCH/etc/init.d" "$DESTINATION_PATH/asusware.$FAKE_ASUS_OPTWARE_ARCH/lib/ipkg/lists" "$DESTINATION_PATH/asusware.$FAKE_ASUS_OPTWARE_ARCH/lib/ipkg/info"

    echo "dest /opt/ /" > "$DESTINATION_PATH/asusware.$FAKE_ASUS_OPTWARE_ARCH/etc/ipkg.conf"
    touch "$DESTINATION_PATH/asusware.$FAKE_ASUS_OPTWARE_ARCH/.asusrouter"

    # list of state vars taken from src/router/rc/services.c
    # we reset some apps_ vars to not end up with random bugs (web UI persistently trying to install apps in a loop)
    cat <<EOT >> "$DESTINATION_PATH/asusware.$FAKE_ASUS_OPTWARE_ARCH/etc/init.d/S50asuswrt-usb-network"
#!/bin/sh

if [ "\$1" = "start" ]; then
    SCRIPT="\$(nvram get script_usbmount)"
    [ -n "\$SCRIPT" ] && eval "\$SCRIPT" || true

    {
        sleep 10
        nvram set apps_state_autorun=
        nvram set apps_state_install=
        nvram set apps_state_remove=
        nvram set apps_state_switch=
        nvram set apps_state_stop=
        nvram set apps_state_enable=
        nvram set apps_state_update=
        nvram set apps_state_upgrade=
        nvram set apps_state_cancel=
        nvram set apps_state_error=
        nvram set apps_state_action=
        nvram set apps_mounted_path=
        nvram set apps_dev=
    } &
fi
EOT

    chmod +x "$DESTINATION_PATH/asusware.$FAKE_ASUS_OPTWARE_ARCH/etc/init.d/S50asuswrt-usb-network"

    cat <<EOT >> "$DESTINATION_PATH/asusware.$FAKE_ASUS_OPTWARE_ARCH/lib/ipkg/status"
Package: asuswrt-usb-network
Version: 1.0.0.0
Status: install user installed
Architecture: $FAKE_ASUS_OPTWARE_ARCH
Installed-Time: 0
EOT

    cat <<EOT >> "$DESTINATION_PATH/asusware.$FAKE_ASUS_OPTWARE_ARCH/lib/ipkg/lists/optware.asus"
Package: asuswrt-usb-network
Version: 1.0.0.0
Architecture: $FAKE_ASUS_OPTWARE_ARCH
EOT

    cat <<EOT >> "$DESTINATION_PATH/asusware.$FAKE_ASUS_OPTWARE_ARCH/lib/ipkg/info/asuswrt-usb-network.control"
Package: asuswrt-usb-network
Architecture: $FAKE_ASUS_OPTWARE_ARCH
Priority: optional
Section: libs
Version: 1.0.0.0
Depends:
Suggests:
Conflicts:
Enabled: yes
Installed-Size: 1
EOT

    # per src/router/rc/init.c and src/router/rom/apps_scripts/ mipsel does not use a postfix
    if [ "${FAKE_ASUS_OPTWARE_ARCH,,}" = "mipsel" ]; then
        mv "$DESTINATION_PATH/asusware.$FAKE_ASUS_OPTWARE_ARCH" "$DESTINATION_PATH/asusware"
    fi
}

check_filesystem_in_image() {
    local IMAGE="$1"

    [ ! -f "$IMAGE" ] && { echo "Image file does not exist"; exit 2; }

    if ! fdisk -l "$IMAGE" | grep -q "Device" | grep -q "Blocks" | grep -q "Boot"; then
        # occasionally e2fsck will exit with a fail code, we need to ignore it to continue
        e2fsck -pf "$IMAGE" || true
    else
        echo "Skipping filesystem check because the image file contains partition table"
    fi
}

interrupt() {
    echo -e "\rInterrupt by user, cleaning up..."

    is_started || { gadget_down silent && gadget_cleanup silent; }

    [ "$TEMP_IMAGE_DELETE" = true ] && rm -f "$TEMP_IMAGE_FILE"
}

##################################################

case "$1" in
    "start")
        require_root
        is_started && { echo "Startup already complete"; exit; }

        trap interrupt SIGINT SIGTERM SIGQUIT
        set -e

        [ -d "$CONFIGFS_DEVICE_PATH" ] && { gadget_down && gadget_cleanup silent; }

        if [ "$SKIP_MASS_STORAGE" = false ]; then
            [ -z "$TEMP_IMAGE_FILE" ] && { echo "Temporary image file is not set"; exit 22; }

            echo "Setting up gadget \"$GADGET_ID\" with function \"mass_storage\"..."

            create_image "$TEMP_IMAGE_FILE" "$TEMP_IMAGE_SIZE" "$TEMP_IMAGE_FS"

            add_function "mass_storage" "$TEMP_IMAGE_FILE"
            gadget_up

            MS_INSTANCE=$(find "/sys/kernel/config/usb_gadget/$GADGET_ID/functions" -maxdepth 1 -name "mass_storage.*" | grep -o '[^.]*$' || echo "")
            LUN_INSTANCE=$(find "/sys/kernel/config/usb_gadget/$GADGET_ID/functions/mass_storage.$MS_INSTANCE" -maxdepth 1 -name "lun.*" | grep -o '[^.]*$' || echo "")

            { [ -z "$MS_INSTANCE" ] || [ -z "$LUN_INSTANCE" ]; } && { echo "Could not find function or LUN instance"; exit 2; }

            echo "Waiting for the router to write mark to the image (timeout: ${WAIT_TIMEOUT}s)...."

            [ "$WAIT_RETRY" -ge "$WAIT_TIMEOUT" ] && WAIT_RETRY=0

            _TIMER=0
            _RETRY=0
            _TIMEOUT=$WAIT_TIMEOUT
            while ! debugfs -R "ls -l ." "$TEMP_IMAGE_FILE" 2>/dev/null | grep -q "asuswrt-usb-network-mark" && [ "$_TIMER" -lt "$_TIMEOUT" ]; do
                if [ "$WAIT_RETRY" -ge 10 ] && [ "$((_TIMER-_RETRY))" -ge "$WAIT_RETRY" ]; then
                    _RETRY=$((_RETRY+WAIT_RETRY))
                    echo "Recreating gadget \"$GADGET_ID\"..."
                    gadget_down silent && gadget_up silent
                fi

                _TIMER=$((_TIMER+WAIT_SLEEP))
                sleep $WAIT_SLEEP
            done

            [ "$_TIMER" -ge "$_TIMEOUT" ] && echo "Timeout reached, continuing anyway..."

            gadget_down && gadget_cleanup silent
            [ "$TEMP_IMAGE_DELETE" = true ] && rm -f "$TEMP_IMAGE_FILE"
        fi

        if [ -z "$GADGET_STORAGE_FILE" ]; then
            echo "Setting up gadget \"$GADGET_ID\" with function \"$NETWORK_FUNCTION\"..."
        else
            if [ -n "$GADGET_STORAGE_FILE" ] && [ -f "$GADGET_STORAGE_FILE" ] && [ "$GADGET_STORAGE_FILE_CHECK" = true ]; then
                echo "Checking filesystem in storage file \"$GADGET_STORAGE_FILE\"..."
                check_filesystem_in_image "$GADGET_STORAGE_FILE"
            fi

            echo "Setting up gadget \"$GADGET_ID\" with combined functions (mass_storage and $NETWORK_FUNCTION)..."
        fi

        add_function "$NETWORK_FUNCTION"

        if [ -n "$GADGET_STORAGE_FILE" ]; then
            if [ -f "$GADGET_STORAGE_FILE" ]; then
                add_function "mass_storage" "$GADGET_STORAGE_FILE"
            else
                echo "Image file \"$GADGET_STORAGE_FILE\" does not exist, skipping adding mass storage function..."
            fi
        fi

        if [ -n "$GADGET_SCRIPT" ] && [ -x "$GADGET_SCRIPT" ]; then
            $GADGET_SCRIPT "$CONFIGFS_DEVICE_PATH"
        fi

        gadget_up

        NET_INSTANCE=$(find "/sys/kernel/config/usb_gadget/$GADGET_ID/functions" -maxdepth 1 -name "$NETWORK_FUNCTION.*" | grep -o '[^.]*$' || echo "")
        NET_INTERFACE=$(cat "/sys/kernel/config/usb_gadget/$GADGET_ID/functions/$NETWORK_FUNCTION.$NET_INSTANCE/ifname")

        { [ -z "$NET_INSTANCE" ] || [ -z "$NET_INTERFACE" ]; } && { echo "Could not find function instance or read assigned network interface"; exit 2; }

        trap - SIGINT SIGTERM SIGQUIT

        if [ "$VERIFY_CONNECTION" = true ]; then
            echo "Checking if router is reachable (timeout: ${VERIFY_TIMEOUT}s)..."

            _TIMER=0
            _TIMEOUT=$VERIFY_TIMEOUT
            while [ "$_TIMER" -lt "$_TIMEOUT" ]; do
                GATEWAY="$(ip route show | grep "$NET_INTERFACE" | grep default | awk '{print $3}')"

                [ -n "$GATEWAY" ] && ping -c1 -W1 "$GATEWAY" >/dev/null 2>&1 && break

                _TIMER=$((_TIMER+VERIFY_SLEEP))
                sleep $VERIFY_SLEEP
            done

            [ "$_TIMER" -ge "$_TIMEOUT" ] && { echo "Completed but couldn't determine network status (timeout reached)"; exit; }
        fi

        echo "Completed successfully"
    ;;
    "stop")
        require_root
        gadget_down && gadget_cleanup
    ;;
    "status")
        if [ -d "$CONFIGFS_DEVICE_PATH" ] && [ -n "$(cat "$CONFIGFS_DEVICE_PATH/UDC")" ]; then
            echo "Gadget \"$GADGET_ID\" is running."
        else
            echo "Gadget \"$GADGET_ID\" is not running."
        fi

        FUNCTION="${NETWORK_FUNCTION,,}"
        if [ -f "$CONFIGFS_DEVICE_PATH/functions/$FUNCTION.0/ifname" ]; then
            INTERFACE="$(cat "$CONFIGFS_DEVICE_PATH/functions/$FUNCTION.0/ifname")"
            IP_ADDRESS="$(ip -f inet addr show "$INTERFACE" | sed -En -e 's/.*inet ([0-9.]+).*/\1/p')"
            MAC_ADDRESS="$(ip -f link addr show "$INTERFACE" | sed -En -e 's/.*link.*([0-9a-fA-F:]{17}) .*/\1/p')"
        else
            echo "No such function: $CONFIGFS_DEVICE_PATH/functions/$FUNCTION.0"
        fi

        echo ""
        generate_mac_addresses

        [ -n "$IP_ADDRESS" ] && echo "IP address: $IP_ADDRESS"
        [ -n "$GADGET_MAC_DEVICE" ] && echo "Device MAC address: $GADGET_MAC_DEVICE"

        if [ -n "$MAC_ADDRESS" ] && [ "${MAC_ADDRESS^^}" != "${GADGET_MAC_HOST^^}" ]; then
            echo "Host MAC address (actual): $MAC_ADDRESS"
            echo "Host MAC address (config): $GADGET_MAC_HOST"
        else
            echo "Host MAC address: $GADGET_MAC_HOST"
        fi
    ;;
    *)
        echo "Usage: $0 start|stop|status"
        exit 1
    ;;
esac
