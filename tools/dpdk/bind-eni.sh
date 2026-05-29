#!/usr/bin/env bash
# bind-eni.sh — bind a secondary ENA NIC to vfio-pci so DPDK's
# net_ena PMD can attach it.
#
# Runs ON the c5n perf box, AFTER aws-perf-up.sh's user-data has
# finished and AFTER you've attached a secondary ENI to the instance
# (one extra NIC; default is one — leave it alone for SSH and bind
# the second one).
#
# Idempotent: if the target NIC is already bound to vfio-pci, the
# script reports it and exits 0.
#
# Refuses to bind a NIC that has a default route through it (that's
# the SSH path); if you only have one NIC, attach a second first.
#
# Usage:
#   sudo ./bind-eni.sh                # bind the first non-primary ENA
#   sudo ./bind-eni.sh eth1           # bind the named device
#   sudo ./bind-eni.sh 0000:01:00.0   # bind by PCI BDF

set -euo pipefail

need_root() {
    if [[ $EUID -ne 0 ]]; then
        echo "ERR: must run as root (sudo ./bind-eni.sh)" >&2
        exit 1
    fi
}
need_root

DEVBIND=$(command -v dpdk-devbind.py || true)
if [[ -z "$DEVBIND" ]]; then
    echo "ERR: dpdk-devbind.py not found; install dpdk + dpdk-tools." >&2
    exit 1
fi

# ── Load vfio-pci ───────────────────────────────────────────────────
if ! lsmod | grep -q '^vfio_pci\b'; then
    echo "[bind-eni] loading vfio-pci kernel module"
    modprobe vfio-pci
fi

# When the instance lacks an IOMMU (rare on Nitro but possible on
# nested virt), vfio-pci needs unsafe interrupts. Setting this is a
# no-op on hardware that doesn't need it.
echo 1 > /sys/module/vfio_iommu_type1/parameters/allow_unsafe_interrupts 2>/dev/null || true

# ── Pick the target NIC ─────────────────────────────────────────────
TARGET="${1:-}"

# Identify the primary route NIC — never touch this one, it's SSH.
PRIMARY_IF=$(ip -o -4 route show default | awk '{print $5; exit}')
PRIMARY_BDF=$(readlink -f "/sys/class/net/$PRIMARY_IF/device" 2>/dev/null | awk -F/ '{print $NF}' || echo "")

if [[ -z "$TARGET" ]]; then
    # Auto-pick: first ENA NIC that's NOT the primary.
    for d in /sys/class/net/*; do
        iface=$(basename "$d")
        [[ "$iface" == "$PRIMARY_IF" ]] && continue
        driver=$(readlink -f "$d/device/driver" 2>/dev/null | awk -F/ '{print $NF}')
        if [[ "$driver" == "ena" ]]; then
            TARGET="$iface"
            break
        fi
    done
    if [[ -z "$TARGET" ]]; then
        cat >&2 <<EOM
ERR: no candidate ENA NIC found. The instance has only the primary
NIC ($PRIMARY_IF), which we won't touch (that's SSH). Attach a
secondary ENI via the AWS console (or 'aws ec2 attach-network-interface')
and re-run.
EOM
        exit 1
    fi
fi

# Resolve TARGET → BDF.
if [[ "$TARGET" =~ ^[0-9a-f]{4}:[0-9a-f]{2}:[0-9a-f]{2}\.[0-9]+$ ]]; then
    BDF="$TARGET"
    IFACE=""
else
    IFACE="$TARGET"
    BDF=$(readlink -f "/sys/class/net/$IFACE/device" 2>/dev/null | awk -F/ '{print $NF}' || true)
    if [[ -z "$BDF" ]]; then
        echo "ERR: cannot resolve $IFACE to a PCI BDF" >&2
        exit 1
    fi
fi

# Refuse the primary.
if [[ "$BDF" == "$PRIMARY_BDF" ]]; then
    echo "ERR: refusing to bind $IFACE / $BDF — that's the SSH path." >&2
    exit 1
fi

echo "[bind-eni] target: ${IFACE:-(by BDF)} @ $BDF"

# ── Bind ────────────────────────────────────────────────────────────
CURRENT_DRIVER=$("$DEVBIND" --status-dev net | awk -v bdf="$BDF" '$0 ~ bdf {for (i=1;i<=NF;i++) if ($i ~ /^drv=/) {sub("drv=","",$i); print $i}}')
if [[ "$CURRENT_DRIVER" == "vfio-pci" ]]; then
    echo "[bind-eni] $BDF already bound to vfio-pci — nothing to do"
    exit 0
fi

if [[ -n "$IFACE" ]]; then
    echo "[bind-eni] bringing $IFACE down"
    ip link set "$IFACE" down || true
fi

echo "[bind-eni] binding $BDF to vfio-pci (current=$CURRENT_DRIVER)"
"$DEVBIND" --bind=vfio-pci "$BDF"

# Verify.
NEW_DRIVER=$("$DEVBIND" --status-dev net | awk -v bdf="$BDF" '$0 ~ bdf {for (i=1;i<=NF;i++) if ($i ~ /^drv=/) {sub("drv=","",$i); print $i}}')
if [[ "$NEW_DRIVER" != "vfio-pci" ]]; then
    echo "ERR: bind failed — driver is now '$NEW_DRIVER'" >&2
    exit 1
fi

cat <<EOM

[bind-eni] $BDF is now on vfio-pci.

Run the port probe against it:
  /usr/local/bin/port_probe -l 0-3 --proc-type=primary -a $BDF -- --duration=10

To revert later:
  sudo $DEVBIND --bind=ena $BDF
  sudo ip link set $IFACE up
EOM
