#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

# ===============================
# Multi-column menu with auto-width and ASCII box (prompt outside)
choose_from_menu() {
    local prompt="$1"
    local outvar="$2"
    shift 2
    local options=("$@")

    # Print prompt above the menu
    echo
    echo "$prompt"
    echo

    # PS3 prompt: line break before input
    local old_PS3="${PS3-}"  # Use default value if PS3 is unset
    PS3=$'\nEnter choice number: '

    local choice
    # Temporarily disable unset variable checking for the select loop
    set +u
    while true; do
        select choice in "${options[@]}"; do
            # Valid selection
            if [[ -n "$choice" ]]; then
                printf -v "$outvar" "%s" "$choice"
                break 2   # exit both select and while
            else
                echo "Invalid choice. Try again."
                echo
                break
            fi
        done
    done
    set -u  # Re-enable unset variable checking

    # Restore PS3
    PS3="$old_PS3"
    
    # Blank line after menu ends
    echo
}
# ===============================


# === Example usage ===
selections=(
"Selection A (default)"
"Selection B"
"Selection D"
"Selection E"
"Selection F"
"Selection G"
"Selection H"
"Selection I"
"Selection J"
"Selection K"
"Selection L"
"Selection M"
"Selection Ñ"
"Selection O"
)

choose_from_menu "Please make a choice:" selected_choice "${selections[@]}"
echo "Selected choice: $selected_choice"


# === Choose timezones ===
TIMEZONES=(
  "Europe/Madrid (default)"
  "Europe/Paris"
  "Europe/Amsterdam"
  "Europe/Berlin"
  "Europe/Brussels"
  "Europe/Helsinki"
  "Europe/Lisbon"
  "Europe/London"
  "Europe/Oslo"
  "Europe/Prague"
  "Europe/Rome"
  "Europe/Stockholm"
  "Europe/Vienna"
  "Europe/Warsaw"
  "America/New_York"
  "America/Los_Angeles"
  "America/Chicago"
  "America/Sao_Paulo"
  "Asia/Shanghai"
  "Asia/Tokyo"
  "Asia/Seoul"
  "Asia/Kolkata"
  "Australia/Sydney"
  "Africa/Johannesburg"
  "UTC"
)

choose_from_menu "Select timezone:" TIMEZONE "${TIMEZONES[@]}"
echo "Selected timezone: $TIMEZONE"
TIMEZONE=$(echo "$TIMEZONE" | sed 's/ (default)//')
echo $TIMEZONE
echo "============================================"