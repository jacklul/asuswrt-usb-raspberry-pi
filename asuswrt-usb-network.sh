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
VERIFY_CONNECTION=true    # verify that we can reach gateway after enabling network gadget
SKIP_MASS_STORAGE=false    # skip adding mass storage gadget, setup network gadget right away
COMBINE_GADGETS=false    # launch both mass storage and network gadgets at the same time, not every router will support this
VERIFY_TIMEOUT=60    # maximum seconds to wait for the connection check
VERIFY_SLEEP=1    # time to sleep between each gateway ping
WAIT_TIMEOUT=60    # maximum seconds to wait for the router to write to the storage image file
WAIT_SLEEP=1    # time to sleep between each image contents checks
TEMP_IMAGE_SIZE="1M"    # dd's bs parameter
TEMP_IMAGE_COUNT=1    # dd's count parameter
TEMP_IMAGE_FS="ext2"    # filesystem to use, must be supported by "mkfs." command and the router
FAKE_ASUS_OPTWARE=false    # launch command in "script_usbmount" nvram variable through fake Asus' Optware installation
ASUS_OPTWARE_ARCH="arm"    # Optware architecture supported by the router (known values: arm, mipsbig, mipsel)
GADGET_ID="usbnet"    # gadget ID used in "/sys/kernel/config/usb_gadget/ID"
GADGET_PRODUCT="$(tr -d '\0' < /sys/firmware/devicetree/base/model | sed "s/^\(.*\) Rev.*$/\1/") USB Gadget"    # product name, "Raspberry Pi Zero W USB Gadget"
GADGET_MANUFACTURER="Raspberry Pi Foundation"    # product manufacturer
GADGET_SERIAL="$(grep Serial /proc/cpuinfo | sed 's/Serial\s*: 0000\(\w*\)/\1/')"    # by default uses CPU serial
GADGET_VENDOR_ID="0x1d6b"    # 0x1d6b = Linux Foundation
GADGET_PRODUCT_ID="0x0104"    # 0x0104 = Multifunction Composite Gadget
GADGET_USB_VERSION="0x0200"    # 0x0200 = USB 2.0, should be left unchanged
GADGET_DEVICE_VERSION="0x0100"    # should be incremented every time you change your setup
GADGET_DEVICE_CLASS="0xef"    # 0xef = Multi-interface device, see https://www.usb.org/defined-class-codes
GADGET_DEVICE_SUBCLASS="0x02"    # 0x02 = Interface Association Descriptor sub class
GADGET_DEVICE_PROTOCOL="0x01"    # 0x01 = Interface Association Descriptor protocol
GADGET_MAX_PACKET_SIZE="0x40"    # declare max packet size, decimal or hex
GADGET_ATTRIBUTES="0x80"    # 0xc0 = self powered, 0x80 = bus powered
GADGET_MAX_POWER="250"    # declare max power usage, decimal or hex
GADGET_MAC_VENDOR="B8:27:EB"    # vendor MAC prefix to use in generated MAC address (B8:27:EB = Raspberry Pi Foundation)
GADGET_MAC_HOST=""    # host MAC address, if empty - MAC address is generated from GADGET_MAC_VENDOR and CPU serial
GADGET_MAC_DEVICE=""    # device MAC address, if empty - MAC address is generated from CPU serial with 02: prefix
GADGET_STORAGE_FILE="/tmp/$GADGET_ID.img"    # path to the temporary image file that will be created and mounted
GADGET_STORAGE_STALL=""    # change value of stall option, empty means default

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
			mkdir "$CONFIGFS_DEVICE_PATH/functions/mass_storage.$INSTANCE"

			[ -n "$GADGET_STORAGE_STALL" ] && echo "$GADGET_STORAGE_STALL" > "$CONFIGFS_DEVICE_PATH/functions/mass_storage.$INSTANCE/stall"

			[ ! -d "$CONFIGFS_DEVICE_PATH/functions/mass_storage.$INSTANCE/lun.0" ] && mkdir "$CONFIGFS_DEVICE_PATH/functions/mass_storage.$INSTANCE/lun.0"

			if [ -n "$GADGET_STORAGE_FILE" ] && [ -f "$GADGET_STORAGE_FILE" ]; then
				[ ! -f "$GADGET_STORAGE_FILE" ] && { echo "Image file does not exist: $GADGET_STORAGE_FILE"; exit 2; }

				echo "$GADGET_STORAGE_FILE" > "$CONFIGFS_DEVICE_PATH/functions/mass_storage.$INSTANCE/lun.0/file"
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
		exit 1
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
		exit 1
	fi
}

is_started() {
	if [ -d "$CONFIGFS_DEVICE_PATH" ]; then
		local NET_INSTANCE=$(find "/sys/kernel/config/usb_gadget/$GADGET_ID/functions" -maxdepth 2 -name "ifname" || echo "")

		[ -n "$NET_INSTANCE" ] && return 0
	fi

	return 1
}

create_image() {
	local FILE="$1"
	local FILESYSTEM="$2"
	local SIZE="$3"
	local COUNT="$4"

	command -v "mkfs.$FILESYSTEM" >/dev/null 2>&1 || { echo "Function \"mkfs.$FILESYSTEM\" not found"; exit 22; }

	echo "Creating image file \"$FILE\" ($FILESYSTEM, $COUNT*$SIZE)..."

	{ DD_OUTPUT=$(dd if=/dev/zero of="$FILE" bs="$SIZE" count="$COUNT" 2>&1); } || { echo "$DD_OUTPUT"; exit 1; }
	{ MKFS_OUTPUT=$("mkfs.$FILESYSTEM" "$FILE" 2>&1); } || { echo "$MKFS_OUTPUT"; exit 1; }

	if [ "$FAKE_ASUS_OPTWARE" = true ]; then
		echo "Creating fake Asus Optware installation..."

		mkdir "${FILE}-mnt"
		mount "$FILE" "${FILE}-mnt"
		mkdir -p "${FILE}-mnt/asusware.$ASUS_OPTWARE_ARCH/etc/init.d" "${FILE}-mnt/asusware.$ASUS_OPTWARE_ARCH/lib/ipkg/lists" "${FILE}-mnt/asusware.$ASUS_OPTWARE_ARCH/lib/ipkg/info"

		echo "dest /opt/ /" > "${FILE}-mnt/asusware.$ASUS_OPTWARE_ARCH/etc/ipkg.conf"
		touch "${FILE}-mnt/asusware.$ASUS_OPTWARE_ARCH/.asusrouter"

		cat <<EOT >> "${FILE}-mnt/asusware.$ASUS_OPTWARE_ARCH/etc/init.d/S50asuswrt-usb-network"
#!/bin/sh
[ "\$1" == "start" ] && eval "\$(nvram get script_usbmount)"
[ "\$1" == "stop" ] && eval "\$(nvram get script_usbumount)"
EOT

		cat <<EOT >> "${FILE}-mnt/asusware.$ASUS_OPTWARE_ARCH/lib/ipkg/status"
Package: asuswrt-usb-network
Version: 1.0.0.0
Status: install user installed
Architecture: $ASUS_OPTWARE_ARCH
Installed-Time: 0
EOT

		cat <<EOT >> "${FILE}-mnt/asusware.$ASUS_OPTWARE_ARCH/lib/ipkg/lists/optware.asus"
Package: asuswrt-usb-network
Version: 1.0.0.0
Architecture: $ASUS_OPTWARE_ARCH
EOT

		cat <<EOT >> "${FILE}-mnt/asusware.$ASUS_OPTWARE_ARCH/lib/ipkg/info/asuswrt-usb-network.control"
Package: asuswrt-usb-network
Architecture: $ASUS_OPTWARE_ARCH
Priority: optional
Section: libs
Version: 1.0.0.0
Depends:
Suggests:
Conflicts:
Enabled: yes
Installed-Size: 1
EOT

		umount "${FILE}-mnt" && rmdir "${FILE}-mnt" 2> /dev/null
	fi
}

interrupt() {
	echo -e "\rInterrupt by user, cleaning up..."

	is_started || gadget_down silent
	rm -f "$GADGET_STORAGE_FILE"
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
			if [ "$COMBINE_GADGETS" = true ]; then
				echo "Setting up gadget \"$GADGET_ID\" with combined functions (mass_storage and $NETWORK_FUNCTION)..."
				
				add_function "$NETWORK_FUNCTION"
			else
				echo "Setting up gadget \"$GADGET_ID\" with function \"mass_storage\"..."
			fi

			create_image "$GADGET_STORAGE_FILE" "$TEMP_IMAGE_FS" "$TEMP_IMAGE_SIZE" "$TEMP_IMAGE_COUNT"

			add_function "mass_storage"
			gadget_up

			MS_INSTANCE=$(find "/sys/kernel/config/usb_gadget/$GADGET_ID/functions" -maxdepth 1 -name "mass_storage.*" | grep -o '[^.]*$' || echo "")
			LUN_INSTANCE=$(find "/sys/kernel/config/usb_gadget/$GADGET_ID/functions/mass_storage.$MS_INSTANCE" -maxdepth 1 -name "lun.*" | grep -o '[^.]*$' || echo "")

			{ [ -z "$MS_INSTANCE" ] || [ -z "$LUN_INSTANCE" ]; } && { echo "Could not find function or LUN instance"; exit 2; }

			echo "Waiting for the router to write to the image (timeout: ${WAIT_TIMEOUT}s)...."

			_TIMER=0
			_TIMEOUT=$WAIT_TIMEOUT
			while ! debugfs -R "ls -l ." "$GADGET_STORAGE_FILE" 2>/dev/null | grep -q txt && [ "$_TIMER" -lt "$_TIMEOUT" ]; do
				_TIMER=$((_TIMER+WAIT_SLEEP))
				sleep $WAIT_SLEEP
			done

			[ "$_TIMER" -ge "$_TIMEOUT" ] && echo "Timeout reached, continuing anyway..."

			if [ "$COMBINE_GADGETS" = false ]; then
				gadget_down
				rm -f "$GADGET_STORAGE_FILE"
			fi
		fi

		if [ "$COMBINE_GADGETS" = false ] || [ "$SKIP_MASS_STORAGE" = true ]; then
			echo "Setting up gadget \"$GADGET_ID\" with function \"$NETWORK_FUNCTION\"..."

			add_function "$NETWORK_FUNCTION"
			gadget_up
		fi

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
