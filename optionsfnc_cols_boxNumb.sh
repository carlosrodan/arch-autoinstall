#!/usr/bin/env bash

# Simple menu function with a blank line before input
choose_from_menu() {
    local prompt="$1"
    local outvar="$2"
    shift 2
    local options=("$@")

    # Print prompt above the menu
    echo
    echo "$prompt"
    echo "======================="
    echo

    # PS3 prompt: just a space so the input line appears after a blank line
    PS3=$'\nEnter choice number: '

    local choice
    select choice in "${options[@]}"; do
        if [[ -n "$choice" ]]; then
            printf -v "$outvar" "%s" "$choice"
            break
        else
            echo "Invalid choice. Try again."
        fi
    done

    # Optional: blank line after menu ends
    echo
}

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
)

choose_from_menu "Please make a choice:" selected_choice "${selections[@]}"
echo "Selected choice: $selected_choice"
echo "============================================"
