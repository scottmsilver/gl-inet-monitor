#!/bin/bash
# Install local public key into the Beryl AX's authorized_keys.
# Run from this laptop after a clean firmware flash.
# Prompts once for the router root password.

set -eu

ROUTER="${ROUTER:-root@192.168.8.1}"
PUBKEY="${PUBKEY:-$HOME/.ssh/beryl_ax.pub}"

if [ ! -f "$PUBKEY" ]; then
  echo "ERROR: public key not found at $PUBKEY" >&2
  exit 1
fi

KEY_LINE=$(cat "$PUBKEY")
echo "Installing key from $PUBKEY onto $ROUTER ..."
echo "  fingerprint: $(ssh-keygen -lf "$PUBKEY" | awk '{print $2}')"

ssh -o StrictHostKeyChecking=accept-new "$ROUTER" "
  mkdir -p /etc/dropbear
  touch /etc/dropbear/authorized_keys
  if grep -qxF '$KEY_LINE' /etc/dropbear/authorized_keys; then
    echo '  already present — skipping'
  else
    echo '$KEY_LINE' >> /etc/dropbear/authorized_keys
    echo '  appended'
  fi
  chmod 600 /etc/dropbear/authorized_keys
  chmod 700 /etc/dropbear
"

echo
echo "Verifying key auth..."
if ssh -i "${PUBKEY%.pub}" -o PreferredAuthentications=publickey -o PasswordAuthentication=no -o BatchMode=yes -o ConnectTimeout=5 "$ROUTER" 'echo OK'; then
  echo "Key auth working."
else
  echo "Key auth NOT working — check that ${PUBKEY%.pub} matches $PUBKEY." >&2
  exit 1
fi
