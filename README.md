# Asus Router <=> USB <=> Raspberry Pi
### Connecting Raspberry Pi to LAN through USB port on Asus router

This makes any Raspberry Pi capable of becoming USB Gadget to connect to LAN network through router's USB port.

Great way to run [Pi-hole](https://pi-hole.net) in your network on a budget Raspberry Pi Zero!

**Warning: This cannot be used together with Entware/Optware/Asus Download Master on stock firmware.**

Everything here was tested on **RT-AX58U v2** on official **388.2** firmware.

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

### **On the Raspberry Pi:**

Add `dtoverlay=dwc2` to **/boot/config.txt** and `modules-load=dwc2` to **/boot/cmdline.txt** after `rootwait`.

Install `asuswrt-usb-network` script:

```bash
wget -O - "https://raw.githubusercontent.com/jacklul/asuswrt-usb-raspberry-pi/master/install_pi.sh" | sudo bash
```

Then enable it:
```bash
sudo systemctl enable asuswrt-usb-network.service
```

If you're running [Asuswrt-Merlin](https://www.asuswrt-merlin.net) set `SKIP_MASS_STORAGE=true` in `/etc/asuswrt-usb-network.conf`.

### **On the Asus router:**

Enable the SSH access in the router, connect to it and then execute this command to install required scripts:

```sh
curl -fsSL "https://raw.githubusercontent.com/jacklul/asuswrt-usb-raspberry-pi/master/install_router.sh" | sh
```

_This will install [usb-network.sh](https://github.com/jacklul/asuswrt-scripts/blob/master/scripts/usb-network.sh) and modified [startup.sh](https://github.com/jacklul/asuswrt-scripts/blob/master/startup.sh) scripts from [jacklul/asuswrt-scripts](https://github.com/jacklul/asuswrt-scripts) repository._

_On Merlin firmware it will use `services-start` scripts instead of `startup.sh`._

## Configuration

You can override configuration variables in `/etc/asuswrt-usb-network.conf`.

To see the list of possible variables peek into [asuswrt-usb-network.sh](asuswrt-usb-network.sh).

### **Finish**

Power off the router, connect your Pi to router's USB port and then turn the router on - in a few minutes it should all be working smoothly!

If it does not then your router might be missing support for executing command in `script_usbmount` NVRAM variable on USB mount - in that case set `FAKE_ASUS_OPTWARE=true` in the configuration, you might also need to change `ASUS_OPTWARE_ARCH` to reflect architecture of the router.

## Recommended setup for Pi-hole on a Pi (Zero)

I recommended to also install [`force-dns.sh`](https://github.com/jacklul/asuswrt-scripts/blob/master/scripts/force-dns.sh) script to force LAN and Guest WiFi clients to use the Pi-hole:

```sh
curl -fsSL "https://raw.githubusercontent.com/jacklul/asuswrt-scripts/master/scripts/force-dns.sh" -o /jffs/scripts/force-dns.sh && chmod +x /jffs/scripts/force-dns.sh
```

_There are also other useful scripts so make sure to check [jacklul/asuswrt-scripts repository](https://github.com/jacklul/asuswrt-scripts)._

Edit `force-dns.conf`:
```sh
vi /jffs/scripts/force-dns.conf
```

And paste the following:
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
The `Host MAC` is the value you want to use.

You can add IPs or IP ranges to `PERMIT_IP` variable to prevent that IPs from having their DNS server forced.
Use `FALLBACK_DNS_SERVER` in case the Pi disconnects from the router, it can also be set to the router's IP address.
