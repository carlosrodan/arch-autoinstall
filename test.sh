#!/bin/bash

echog(){ printf "\n==> %s\n\n" "$*"; }

# ====== User name and host prompts ========
echo
read -rp "Type your desired username: " USERNAME
echog "Username chosen: $USERNAME"

# ====== User name prompt ========
read -rp "Type your desired computer (host) name (ex.: arch): " HOSTNAME
echog "Computer name chosen: $HOSTNAME"
