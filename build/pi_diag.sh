#!/usr/bin/env bash
# Run on the Raspberry Pi with sudo. Collects JTAG diagnostics and POSTs them back.
# Usage:  wget -q http://localhost:9090/pi_diag.sh -O /tmp/pi_diag.sh && sudo bash /tmp/pi_diag.sh
exec 2>&1
set +e

DEV=1-2
say() { printf '\n===== %s =====\n' "$1"; }

say "openFPGALoader version"
openFPGALoader --version

say "who is bound to each interface"
for i in 0 1; do
  p=/sys/bus/usb/devices/$DEV:1.$i
  printf 'interface %s driver: ' "$i"
  if [ -e "$p/driver" ]; then basename "$(readlink -f "$p/driver")"; else echo "(none)"; fi
  printf 'interface %s class : ' "$i"
  cat "$p/bInterfaceClass" 2>/dev/null || echo "?"
done

say "processes that might hold the device"
ps aux | grep -iE 'openfpga|hw_server|djtg|xvc|vivado' | grep -v grep || echo "(none)"

say "fuser on the raw usb node"
BUS=$(lsusb -d 0403:6010 | sed -E 's/Bus ([0-9]+) Device ([0-9]+).*/\1 \2/')
echo "bus/dev: $BUS"
NODE=/dev/bus/usb/$(echo "$BUS" | awk '{print $1"/"$2}')
echo "node: $NODE"
ls -l "$NODE" 2>/dev/null
fuser -v "$NODE" 2>&1 || echo "(fuser found nothing / not installed)"

say "lsusb -t"
lsusb -t

say "ATTEMPT 1: as-is, -c digilent"
openFPGALoader -c digilent --detect

say "ATTEMPT 2: force channel 0"
openFPGALoader -c digilent --ftdi-channel 0 --detect

say "ATTEMPT 3: force channel 1"
openFPGALoader -c digilent --ftdi-channel 1 --detect

say "unbinding ftdi_sio from $DEV:1.1"
echo -n "$DEV:1.1" > /sys/bus/usb/drivers/ftdi_sio/unbind
sleep 1
ls /sys/bus/usb/drivers/ftdi_sio/

say "ATTEMPT 4: after unbind, -c digilent"
openFPGALoader -c digilent --detect

say "ATTEMPT 5: after unbind, channel 0"
openFPGALoader -c digilent --ftdi-channel 0 --detect

say "ATTEMPT 6: after unbind, no cable flag"
openFPGALoader --detect

say "ATTEMPT 7: explicit vid/pid, channel 0"
openFPGALoader --vid 0x0403 --pid 0x6010 --ftdi-channel 0 --detect

say "dmesg tail"
dmesg | tail -25

say "restoring ftdi_sio binding"
echo -n "$DEV:1.1" > /sys/bus/usb/drivers/ftdi_sio/bind 2>/dev/null
echo "done"
