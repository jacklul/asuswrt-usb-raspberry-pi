#!/bin/sh

[ -f "/rom/jffs.json" ] || { echo "This script must run on the Asus router!"; exit 1; }

set -e

echo "Installing required scripts..."

if [ ! -f /jffs/scripts/jas.sh ]; then
    curl -fsS "https://raw.githubusercontent.com/jacklul/asuswrt-scripts/master/install.sh" | sh
    /bin/sh /jffs/scripts/jas.sh setup
fi

/jffs/scripts/jas.sh install usb-network service-event hotplug-event

echo "Starting..."
/jffs/scripts/jas.sh usb-network start
/jffs/scripts/jas.sh service-event start
/jffs/scripts/jas.sh hotplug-event start

echo "Finished!"
