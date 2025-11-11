#!/usr/bin/env bash

# ===============================
# Multi-column menu with auto-width and ASCII box (prompt outside)
choose_from_menu() {
    local prompt="$1"
    local outvar="$2"
    shift 2
    local options=("$@")
    local count=${#options[@]}

    # Print prompt above the menu
    echo
    echo "$prompt"
    echo

    # Display numbered options
    for ((i=0; i<count; i++)); do
        printf " %2d) %s\n" $((i+1)) "${options[i]}"
    done
    echo

    # Get user input
    while true; do
        read -p "Enter selection [1-$count]: " choice
        if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= count )); then
            printf -v "$outvar" "%s" "${options[$((choice-1))]}"
            break
        fi
        echo "Please enter a number between 1 and $count"
    done
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