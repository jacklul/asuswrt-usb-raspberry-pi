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
NETWORK_FUNCTION="ecm"    # network function to use, supported: ecm (recommended), rndis, eem, ncm
VERIFY_CONNECTION=true    # verify that we can reach gateway after enabling network gadget? (recommended if using services depending on network-online.target)
SKIP_MASS_STORAGE=false    # skip adding initial mass storage gadget - instead setup network gadget right away? (useful only on Merlin firmware)
TEMP_IMAGE_FILE="/tmp/asuswrt-usb-network.img"    # temporary image file that will be created
TEMP_IMAGE_SIZE="1M"    # dd's bs parameter, might need to be increased in case router doesn't want to mount the storage
TEMP_IMAGE_COUNT=1    # dd's count parameter, might need to be increased in case router doesn't want to mount the storage
TEMP_IMAGE_FS="ext2"    # filesystem to use, must be supported by "mkfs." command and the router
TEMP_IMAGE_DELETE=true    # delete temporary image after it is no longer useful?
FAKE_ASUS_OPTWARE=false    # launch command in "script_usbmount" nvram variable through fake Asus' Optware installation? (requires SKIP_MASS_STORAGE=false)
FAKE_ASUS_OPTWARE_ARCH="arm"    # Optware architecture supported by the router (known values: arm, mipsbig, mipsel)
VERIFY_TIMEOUT=60    # maximum seconds to wait for the connection check, in seconds
VERIFY_SLEEP=1    # time to sleep between each gateway ping, in seconds
WAIT_TIMEOUT=60    # maximum seconds to wait for the router to write to the storage image file, in seconds
WAIT_SLEEP=1    # time to sleep between each image contents checks, in seconds
GADGET_ID="usbnet"    # gadget ID used in "/sys/kernel/config/usb_gadget/ID"
GADGET_PRODUCT="$(tr -d '\0' < /sys/firmware/devicetree/base/model | sed "s/^\(.*\) Rev.*$/\1/") USB Gadget"    # product name, "Raspberry Pi Zero W USB Gadget"
GADGET_MANUFACTURER="Raspberry Pi Foundation"    # product manufacturer
GADGET_SERIAL="$(grep Serial /proc/cpuinfo | sed 's/Serial\s*: 0000\(\w*\)/\1/')"    # by default uses CPU serial
GADGET_VENDOR_ID="0x1d6b"    # 0x1d6b = Linux Foundation
GADGET_PRODUCT_ID="0x0104"    # 0x0104 = Multifunction Composite Gadget
GADGET_USB_VERSION="0x0200"    # 0x0200 = USB 2.0, should be left unchanged
GADGET_DEVICE_VERSION="0x0100"    # should be incremented every time you change your setup (only Windows target systems)
GADGET_DEVICE_CLASS="0xef"    # 0xef = Multi-interface device, see https://www.usb.org/defined-class-codes
GADGET_DEVICE_SUBCLASS="0x02"    # 0x02 = Interface Association Descriptor sub class
GADGET_DEVICE_PROTOCOL="0x01"    # 0x01 = Interface Association Descriptor protocol
GADGET_MAX_PACKET_SIZE="0x40"    # declare max packet size, decimal or hex
GADGET_ATTRIBUTES="0x80"    # 0xc0 = self powered, 0x80 = bus powered
GADGET_MAX_POWER="250"    # declare max power usage, decimal or hex
GADGET_MAC_VENDOR="B8:27:EB"    # vendor MAC prefix to use in generated MAC address (B8:27:EB = Raspberry Pi Foundation)
GADGET_MAC_HOST=""    # host MAC address, if empty - MAC address is generated from GADGET_MAC_VENDOR and CPU serial
GADGET_MAC_DEVICE=""    # device MAC address, if empty - MAC address is generated from CPU serial with 02: prefix
GADGET_STORAGE_FILE=""    # path to the image file that will be mounted as mass storage, if set will add mass storage function together with network function
GADGET_STORAGE_STALL=""    # change value of stall option, empty means system default
GADGET_STORAGE_REMOVABLE=""    # change value of removable option, empty means system default
GADGET_STORAGE_CDROM=""    # change value of cdrom option, empty means system default
GADGET_STORAGE_RO=""    # change value of ro option, empty means system default
GADGET_STORAGE_NOFUA=""    # change value of nofua option, empty means system default

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
        gadget_down silent
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

    mkdir "$CONFIGFS_DEVICE_PATH/strings/0x409"
    echo "$GADGET_PRODUCT" > "$CONFIGFS_DEVICE_PATH/strings/0x409/product"
    echo "$GADGET_MANUFACTURER" > "$CONFIGFS_DEVICE_PATH/strings/0x409/manufacturer"
    echo "$GADGET_SERIAL" > "$CONFIGFS_DEVICE_PATH/strings/0x409/serialnumber"

    mkdir "$CONFIGFS_DEVICE_PATH/configs/$CONFIG"
    echo "$GADGET_ATTRIBUTES" > "$CONFIGFS_DEVICE_PATH/configs/$CONFIG/bmAttributes"
    echo "$GADGET_MAX_POWER" > "$CONFIGFS_DEVICE_PATH/configs/$CONFIG/MaxPower"
    mkdir "$CONFIGFS_DEVICE_PATH/configs/$CONFIG/strings/0x409"
}

add_function() {
    local FUNCTION="$(echo "$1" | awk '{print tolower($0)}')"
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

            echo "${FUNCTION:upper}" > "$CONFIGFS_DEVICE_PATH/configs/$CONFIG/strings/0x409/configuration"

            ln -s "$CONFIGFS_DEVICE_PATH/functions/$FUNCTION.$INSTANCE" "$CONFIGFS_DEVICE_PATH/configs/$CONFIG"
        ;;
        "mass_storage")
            [ -z "$ARGUMENT" ] && { echo "Image file not provided"; exit 22; }

            mkdir "$CONFIGFS_DEVICE_PATH/functions/mass_storage.$INSTANCE"

            [ -n "$GADGET_STORAGE_STALL" ] && echo "$GADGET_STORAGE_STALL" > "$CONFIGFS_DEVICE_PATH/functions/mass_storage.$INSTANCE/stall"

            [ ! -d "$CONFIGFS_DEVICE_PATH/functions/mass_storage.$INSTANCE/lun.$LUN_INSTANCE" ] && mkdir "$CONFIGFS_DEVICE_PATH/functions/mass_storage.$INSTANCE/lun.$LUN_INSTANCE"

            if [ -n "$ARGUMENT" ] && [ -f "$ARGUMENT" ]; then
                [ ! -f "$ARGUMENT" ] && { echo "Image file does not exist: $ARGUMENT"; exit 2; }

                echo "$ARGUMENT" > "$CONFIGFS_DEVICE_PATH/functions/mass_storage.$INSTANCE/lun.$LUN_INSTANCE/file"
                [ -n "$GADGET_STORAGE_REMOVABLE" ] && echo "$GADGET_STORAGE_REMOVABLE" > "$CONFIGFS_DEVICE_PATH/functions/mass_storage.$INSTANCE/lun.$LUN_INSTANCE/removable"
                [ -n "$GADGET_STORAGE_CDROM" ] && echo "$GADGET_STORAGE_CDROM" > "$CONFIGFS_DEVICE_PATH/functions/mass_storage.$INSTANCE/lun.$LUN_INSTANCE/cdrom"
                [ -n "$GADGET_STORAGE_RO" ] && echo "$GADGET_STORAGE_RO" > "$CONFIGFS_DEVICE_PATH/functions/mass_storage.$INSTANCE/lun.$LUN_INSTANCE/ro"
                [ -n "$GADGET_STORAGE_NOFUA" ] && echo "$GADGET_STORAGE_NOFUA" > "$CONFIGFS_DEVICE_PATH/functions/mass_storage.$INSTANCE/lun.$LUN_INSTANCE/nofua"
            fi

            echo "Mass Storage" > "$CONFIGFS_DEVICE_PATH/configs/$CONFIG/strings/0x409/configuration"

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
    local ARG="$1"

    [ ! -d "$CONFIGFS_DEVICE_PATH" ] && { echo "Gadget \"$GADGET_ID\" is already down"; exit 19; }

    [ "$ARG" != "silent" ] && echo "Taking down gadget \"$GADGET_ID\"...";

    if [ -d "$CONFIGFS_DEVICE_PATH" ]; then
        [ -n "$(cat "$CONFIGFS_DEVICE_PATH/UDC")" ] && echo "" > "$CONFIGFS_DEVICE_PATH/UDC"

        local INSTANCE_NET=$(find $CONFIGFS_DEVICE_PATH/functions/ -maxdepth 2 -name "ifname" | grep -o '/*[^.]*/$' || echo "")

        if [ -n "$INSTANCE_NET" ] && [ -f "$CONFIGFS_DEVICE_PATH/functions/$INSTANCE_NET/ifname" ]; then
            local INTERFACE="$(cat "$CONFIGFS_DEVICE_PATH/functions/$INSTANCE_NET/ifname")"

            [ -d "/sys/class/net/$INTERFACE" ] && ifconfig "$INTERFACE" down
        fi

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
    local GADGET_SERIAL_LOWER="$(echo "$GADGET_SERIAL" | awk '{print tolower($0)}')"

    [ -z "$GADGET_MAC_DEVICE" ] && GADGET_MAC_DEVICE="02:$(echo "$GADGET_SERIAL_LOWER" | sed 's/\(\w\w\)/:\1/g' | cut -b 5-)"

    if [ "$(echo "$GADGET_MAC_DEVICE" | awk -F":" '{print NF-1}')" != "5" ]; then
        echo "Invalid device MAC address: $GADGET_MAC_DEVICE"
        exit 22
    fi

    if [ -z "$GADGET_MAC_HOST" ]; then
        if [ "$(echo "$GADGET_MAC_VENDOR" | awk -F":" '{print NF-1}')" != "2" ]; then
            echo "Invalid value for \"GADGET_MAC_VENDOR\" variable!"
            exit 22
        fi

        GADGET_MAC_HOST="$(echo "$GADGET_MAC_VENDOR" | awk '{print tolower($0)}'):$(echo "$GADGET_SERIAL_LOWER" | sed 's/\(\w\w\)/:\1/g' | cut -b 11-)"
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
    local FILESYSTEM="$2"
    local SIZE="$3"
    local COUNT="$4"

    command -v "mkfs.$FILESYSTEM" >/dev/null 2>&1 || { echo "Function \"mkfs.$FILESYSTEM\" not found"; exit 2; }

    echo "Creating image file \"$FILE\" ($FILESYSTEM, $COUNT*$SIZE)..."

    { DD_OUTPUT=$(dd if=/dev/zero of="$FILE" bs="$SIZE" count="$COUNT" 2>&1); } || { echo "$DD_OUTPUT"; exit 1; }
    { MKFS_OUTPUT=$("mkfs.$FILESYSTEM" "$FILE" 2>&1); } || { echo "$MKFS_OUTPUT"; exit 1; }

    if [ "$FAKE_ASUS_OPTWARE" = true ]; then
        create_fake_asus_optware "$FILE"
    fi
}

create_fake_asus_optware() {
    local DESTINATION_PATH="$1"

    echo "Creating fake Asus Optware installation..."

    mkdir "$DESTINATION_PATH-mnt"
    mount "$DESTINATION_PATH" "$DESTINATION_PATH-mnt"
    mkdir -p "$DESTINATION_PATH-mnt/asusware.$FAKE_ASUS_OPTWARE_ARCH/etc/init.d" "$DESTINATION_PATH-mnt/asusware.$FAKE_ASUS_OPTWARE_ARCH/lib/ipkg/lists" "$DESTINATION_PATH-mnt/asusware.$FAKE_ASUS_OPTWARE_ARCH/lib/ipkg/info"

    echo "dest /opt/ /" > "$DESTINATION_PATH-mnt/asusware.$FAKE_ASUS_OPTWARE_ARCH/etc/ipkg.conf"
    touch "$DESTINATION_PATH-mnt/asusware.$FAKE_ASUS_OPTWARE_ARCH/.asusrouter"

    cat <<EOT >> "$DESTINATION_PATH-mnt/asusware.$FAKE_ASUS_OPTWARE_ARCH/etc/init.d/S50asuswrt-usb-network"
#!/bin/sh
if [ "\$1" == "start" ]; then
    nvram set apps_state_autorun=4
    eval "\$(nvram get script_usbmount)"
elif [ "\$1" == "stop" ]; then
    eval "\$(nvram get script_usbumount)"
fi
EOT

    cat <<EOT >> "$DESTINATION_PATH-mnt/asusware.$FAKE_ASUS_OPTWARE_ARCH/lib/ipkg/status"
Package: asuswrt-usb-network
Version: 1.0.0.0
Status: install user installed
Architecture: $FAKE_ASUS_OPTWARE_ARCH
Installed-Time: 0
EOT

    cat <<EOT >> "$DESTINATION_PATH-mnt/asusware.$FAKE_ASUS_OPTWARE_ARCH/lib/ipkg/lists/optware.asus"
Package: asuswrt-usb-network
Version: 1.0.0.0
Architecture: $FAKE_ASUS_OPTWARE_ARCH
EOT

    cat <<EOT >> "$DESTINATION_PATH-mnt/asusware.$FAKE_ASUS_OPTWARE_ARCH/lib/ipkg/info/asuswrt-usb-network.control"
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

    # per src/router/rc/init.c mipsel does not use postfix
    if [ "$(echo "$FAKE_ASUS_OPTWARE_ARCH" | awk '{print tolower($0)}')" = "mipsel" ]; then
        mv "$DESTINATION_PATH-mnt/asusware.$FAKE_ASUS_OPTWARE_ARCH" "$DESTINATION_PATH-mnt/asusware"
    fi

    umount "$DESTINATION_PATH-mnt"
    rmdir "$DESTINATION_PATH-mnt"
}

interrupt() {
    echo -e "\rInterrupt by user, cleaning up..."

    is_started || gadget_down silent

    [ "$TEMP_IMAGE_DELETE" = true ] && rm -f "$TEMP_IMAGE_FILE"
}

##################################################

case "$1" in
    "start")
        require_root
        is_started && { echo "Startup already complete"; exit; }

        trap interrupt SIGINT SIGTERM SIGQUIT
        set -e

        [ -d "$CONFIGFS_DEVICE_PATH" ] && gadget_down

        if [ "$SKIP_MASS_STORAGE" = false ]; then
            [ -z "$TEMP_IMAGE_FILE" ] && { echo "Temporary image file is not set"; exit 22; }

            echo "Setting up gadget \"$GADGET_ID\" with function \"mass_storage\"..."

            create_image "$TEMP_IMAGE_FILE" "$TEMP_IMAGE_FS" "$TEMP_IMAGE_SIZE" "$TEMP_IMAGE_COUNT"

            add_function "mass_storage" "$TEMP_IMAGE_FILE"
            gadget_up

            MS_INSTANCE=$(find "/sys/kernel/config/usb_gadget/$GADGET_ID/functions" -maxdepth 1 -name "mass_storage.*" | grep -o '[^.]*$' || echo "")
            LUN_INSTANCE=$(find "/sys/kernel/config/usb_gadget/$GADGET_ID/functions/mass_storage.$MS_INSTANCE" -maxdepth 1 -name "lun.*" | grep -o '[^.]*$' || echo "")

            { [ -z "$MS_INSTANCE" ] || [ -z "$LUN_INSTANCE" ]; } && { echo "Could not find function or LUN instance"; exit 2; }

            echo "Waiting for the router to write mark to the image (timeout: ${WAIT_TIMEOUT}s)...."

            _TIMER=0
            _TIMEOUT=$WAIT_TIMEOUT
            while ! debugfs -R "ls -l ." "$TEMP_IMAGE_FILE" 2>/dev/null | grep -q "asuswrt-usb-network" && [ "$_TIMER" -lt "$_TIMEOUT" ]; do
                _TIMER=$((_TIMER+WAIT_SLEEP))
                sleep $WAIT_SLEEP
            done

            [ "$_TIMER" -ge "$_TIMEOUT" ] && echo "Timeout reached, continuing anyway..."

            gadget_down
            [ "$TEMP_IMAGE_DELETE" = true ] && rm -f "$TEMP_IMAGE_FILE"
        fi

        if [ -z "$GADGET_STORAGE_FILE" ]; then
            echo "Setting up gadget \"$GADGET_ID\" with function \"$NETWORK_FUNCTION\"..."
        else
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

            [ "$_TIMER" -ge "$_TIMEOUT" ] && { echo "Completed but couldn't determine network status (timeout reached)"; exit 124; }
        fi

        echo "Completed successfully"
    ;;
    "stop")
        require_root
        gadget_down
    ;;
    "status")
        if [ -d "$CONFIGFS_DEVICE_PATH" ] && [ -n "$(cat "$CONFIGFS_DEVICE_PATH/UDC")" ]; then
            echo "Gadget \"$GADGET_ID\" is running."
        else
            echo "Gadget \"$GADGET_ID\" is not running."
        fi

        FUNCTION="$(echo "$NETWORK_FUNCTION" | awk '{print tolower($0)}')"
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

        if [ -n "$MAC_ADDRESS" ] && [ "$MAC_ADDRESS" != "$GADGET_MAC_HOST" ]; then
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
