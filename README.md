# Asus Router <=> USB <=> Raspberry Pi
### Connecting Raspberry Pi to LAN through USB port on Asus router

This makes any Raspberry Pi capable of becoming USB Gadget to connect to LAN network through router's USB port.

Great way to run [Pi-hole](https://pi-hole.net) in your network on a budget Raspberry Pi Zero!

> [!WARNING]
> This cannot be used together with Optware / Asus Download Master on stock firmware.

## How it works

Asus routers have the capability to run a script when USB storage device is mounted.

This is how this magic is happening:

- Router is booting, at one point USB port gets powered and Pi starts booting as well
- Pi pretends to be USB storage device, router mounts it and triggers the script
- The script on the router writes a file to the mass storage device
- The script on the Pi detects that and transforms itself into USB Ethernet gadget
- The script on the router waits for the new network interface to become available and then enables it and adds it to the LAN bridge interface
- The Pi is now a member of your LAN network

The script on the router also is monitoring for the interface changes in case the Raspberry Pi reboots.

## Installation

### On the Raspberry Pi:

> [!IMPORTANT]
> Make sure you have `debugfs` command available - if not install it with `apt-get install e2fsprogs`.

Add `dtoverlay=dwc2` to **/boot/config.txt** and `modules-load=dwc2` to **/boot/cmdline.txt** after `rootwait`.

Install `asuswrt-usb-network` script:

```bash
wget -O - "https://raw.githubusercontent.com/jacklul/asuswrt-usb-raspberry-pi/master/install_pi.sh" | sudo bash
```

Then enable it:
```bash
sudo systemctl enable asuswrt-usb-network.service
```

Modify configuration - `sudo nano /etc/asuswrt-usb-network.conf`:

- If you're running [Asuswrt-Merlin](https://www.asuswrt-merlin.net) set `SKIP_MASS_STORAGE=true`
  - _We are using `services-start` script on router side - no need to use command startup method_

- If you're running stock firmware in most cases you will need to set `FAKE_ASUS_OPTWARE=true`
    - _Newer firmware versions dropped support for `script_usbmount` NVRAM variable so we need a workaround_
    - You might also need to change `ASUS_OPTWARE_ARCH` to reflect architecture of the router
    - By default `/jffs/scripts-startup.sh` script is executed on the router - you can change this with `FAKE_ASUS_OPTWARE_CMD` variable

For the full list of configuration variables - [look below](#configuration).

### On the Asus router:

Enable the SSH access in the router, connect to it and then execute this command to install required scripts:

```sh
curl -fsSL "https://raw.githubusercontent.com/jacklul/asuswrt-usb-raspberry-pi/master/install_router.sh" | sh
```

_This command will install required scripts from [jacklul/asuswrt-scripts](https://github.com/jacklul/asuswrt-scripts) repository and apply required modifications._

_On Merlin firmware it will use `services-start` scripts instead of `scripts-startup.sh`._

### Finish

Power off the router, connect your Pi to the router's USB port and then turn it on - in a few minutes it should all be working smoothly!

If it does not work and you're running stock firmware then make sure you are using build-in workaround - [see "Modify configuration" step above](#on-the-raspberry-pi).

## Configuration

You can set configuration variables in `/etc/asuswrt-usb-network.conf`.

| Variable | Default | Description |
| --- | --- | --- |
| NETWORK_FUNCTION | "ecm" | Network gadget function to use<br>Supported values are: `rndis, ecm (recommended), eem, ncm` |
| VERIFY_CONNECTION | true | Verify that we can reach gateway after enabling network gadget?<br>Recommended if using services depending on systemd's `network-online.target` |
| SKIP_MASS_STORAGE | false | Skip adding initial mass storage gadget - instead setup network gadget right away?<br>This is only useful on Merlin firmware |
| FAKE_ASUS_OPTWARE | false | Launch startup command through fake Asus' Optware installation?<br>(requires `SKIP_MASS_STORAGE=false`) |
| FAKE_ASUS_OPTWARE_ARCH | "arm" | Optware architecture supported by the router<br>Known values are: `arm, mipsbig, mipsel` |
| FAKE_ASUS_OPTWARE_CMD | "/bin/sh /jffs/scripts-startup.sh start" | Command to execute when fake Asus' Optware starts<br>Setting this to empty value will use `script_usbmount` NVRAM variable |
| TEMP_IMAGE_FILE | "/tmp/asuswrt-usb-network.img" | Temporary image file that will be created |
| TEMP_IMAGE_SIZE | 1 | Image size in MB, might need to be increased in case your router doesn't want to mount the storage due to partition size errors |
| TEMP_IMAGE_FS | "ext2" | Filesystem to use, must be supported by `mkfs.` command and the router, `ext2` should be fine in most cases |
| TEMP_IMAGE_DELETE | true | Delete temporary image after it is no longer useful? |
| WAIT_TIMEOUT | 90 | Maximum seconds to wait for the router to write to the storage image file<br>After this time is reached the script will continue as normal |
| WAIT_RETRY | 0 | How many seconds to wait before recreating the gadget device<br>Must be set to at least 10 and lower than `WAIT_TIMEOUT` to work<br>Gadget restart can happen multiple times if `WAIT_TIMEOUT / WAIT_RETRY` is 2 or bigger |
| WAIT_SLEEP | 1 | Time to sleep between each image contents checks, in seconds |
| VERIFY_TIMEOUT | 60 | Maximum seconds to wait for the connection check |
| VERIFY_SLEEP | 1 | Time to sleep between each gateway ping, in seconds |
| GADGET_ID | "usbnet" | Gadget ID used in configfs path `/sys/kernel/config/usb_gadget/[ID]` |
| GADGET_PRODUCT | `(generated)` | Product name, for example: "Raspberry Pi Zero W USB Gadget"<br>(generated from `/sys/firmware/devicetree/base/model`) |
| GADGET_MANUFACTURER | "Raspberry Pi Foundation" | Product manufacturer |
| GADGET_SERIAL | `(generated)` | Device serial number, by default uses CPU serial<br>(generated from `/proc/cpuinfo`) |
| GADGET_VENDOR_ID | "0x1d6b" | `0x1d6b` = Linux Foundation |
| GADGET_PRODUCT_ID | "0x0104" | `0x0104` = Multifunction Composite Gadget |
| GADGET_USB_VERSION | "0x0200" | `0x0200` = USB 2.0, should be left unchanged |
| GADGET_DEVICE_VERSION | "0x0100" | Should be incremented every time you change your setup<br>This only matters for Windows, no need to change it when plugging into Linux machines |
| GADGET_DEVICE_CLASS | "0xef" | `0xef` = Multi-interface device<br>see https://www.usb.org/defined-class-codes |
| GADGET_DEVICE_SUBCLASS | "0x02" | `0x02` = Interface Association Descriptor sub class |
| GADGET_DEVICE_PROTOCOL | "0x01" | `0x01` = Interface Association Descriptor protocol |
| GADGET_MAX_PACKET_SIZE | "0x40" | Declare max packet size, decimal or hex |
| GADGET_MAX_POWER | "250" | Declare max power usage, decimal or hex |
| GADGET_ATTRIBUTES | "0x80" | `0xc0` = self powered, `0x80` = bus powered, should be left as bus powered |
| GADGET_MAC_VENDOR | "B8:27:EB" | Vendor MAC prefix to use in generated MAC address (`B8:27:EB` = Raspberry Pi Foundation) |
| GADGET_MAC_HOST | " " | Host MAC address, if empty - MAC address is generated from `GADGET_MAC_VENDOR` and CPU serial |
| GADGET_MAC_DEVICE | " " | Device MAC address, if empty - MAC address is generated from CPU serial with `02:` prefix |
| GADGET_STORAGE_FILE | " " | Path to the image file that will be mounted as mass storage together with network function |
| GADGET_STORAGE_FILE_CHECK | true | Whenever to run **e2fsck** (check and repair) on image file with each mount |
| GADGET_STORAGE_STALL | " " | Change value of `stall` option, empty means system default |
| GADGET_STORAGE_REMOVABLE | " " | Change value of `removable` option, empty means system default<br>Automatically set to 1 when attaching image file |
| GADGET_STORAGE_CDROM | " " | Change value of `cdrom` option, empty means system default |
| GADGET_STORAGE_RO | " " | Change value of `ro` option, empty means system default |
| GADGET_STORAGE_NOFUA | " " | Change value of `nofua` option, empty means system default |
| GADGET_STORAGE_INQUIRY_STRING | " " | Change value of `inquiry_string`, empty means system default<br>Must be in this format: `vendor(len 8) + model(len 16) + rev(len 4)` |
| GADGET_SCRIPT | " " | Run custom script just before gadget creation, must be a valid path to executable script file, receives argument with device's `configfs` path |

## Recommended setup for Pi-hole on a Pi (Zero)

Install [`force-dns.sh`](https://github.com/jacklul/asuswrt-scripts#user-content-force-dnssh) script to force LAN and Guest WiFi clients to use the Pi-hole:

```sh
curl -fsSL "https://raw.githubusercontent.com/jacklul/asuswrt-scripts/master/scripts/force-dns.sh" -o /jffs/scripts/force-dns.sh && chmod +x /jffs/scripts/force-dns.sh
```

Edit `/jffs/scripts/force-dns.conf` and paste the following:
```
PERMIT_MAC="01:02:03:04:05:06"
#PERMIT_IP="192.168.1.251-192.168.1.254"
REQUIRE_INTERFACE="usb*"
BLOCK_ROUTER_DNS=true
#FALLBACK_DNS_SERVER="9.9.9.9"
```

Replace `01:02:03:04:05:06` with the MAC address of the `usb0` interface on the Pi - to grab it execute the following command on the Pi:
```bash
sudo asuswrt-usb-network status
```
The `Host MAC` is the value you want to pick.

You can add IPs or IP ranges to `PERMIT_IP` variable to prevent that IPs from having their DNS server forced.
Use `FALLBACK_DNS_SERVER` in case the Pi disconnects from the router, it can also be set to the router's IP address.

**When running Pi-hole on the Pi it will be beneficial to run `force-dns.sh` right after Pi connect to the router** - edit `/jffs/scripts/usb-network.conf` and paste the following:
```
EXECUTE_COMMAND="/jffs/scripts/force-dns.sh run"
```

## Running Entware

Create an image that will serve as storage:
```bash
sudo dd if=/dev/zero of=/mass_storage.img bs=1M count=1024
# OR use fallocate which is faster
sudo fallocate -l 1G /mass_storage.img

# format as ext2 for compatibility
sudo mkfs.ext2 /mass_storage.img
```

Modify the configuration in `/etc/asuswrt-usb-network.conf`:
```
GADGET_STORAGE_FILE="/mass_storage.img"
```

Then you will need to install few scripts from [jacklul/asuswrt-scripts repository](https://github.com/jacklul/asuswrt-scripts) on the router:
```bash
curl -fsSL "https://raw.githubusercontent.com/jacklul/asuswrt-scripts/master/scripts/usb-mount.sh" -o /jffs/scripts/usb-mount.sh
curl -fsSL "https://raw.githubusercontent.com/jacklul/asuswrt-scripts/master/scripts/entware.sh" -o /jffs/scripts/entware.sh
chmod +x /jffs/scripts/usb-mount.sh /jffs/scripts/entware.sh
```

Reboot the Pi, wait for the storage to be mounted by `usb-mount.sh` script then install Entware by using this command:
```bash
/jffs/scripts/entware.sh install
```

It will now automatically mount and boot Entware after scripts are started.
