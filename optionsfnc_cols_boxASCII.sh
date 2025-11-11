#!/usr/bin/env bash

# ===============================
# Multi-column menu with auto-width and ASCII box (prompt outside)
function choose_from_menu() {
    local -r prompt="$1" outvar="$2" options=("${@:3}")

    local count=${#options[@]}
    (( count == 0 )) && return 1

    local max_rows=4
    local cols=$(( (count + max_rows - 1) / max_rows ))
    local cur=0
    local esc=$'\e'
    local first_render=true

    # compute longest option length (content width)
    local content_max=0
    for opt in "${options[@]}"; do
        (( ${#opt} > content_max )) && content_max=${#opt}
    done

    # visible width per column = content + 4 (leading space, marker, spacing, trailing space)
    local field_width=$(( content_max + 4 ))

    # actual number of printed rows (never more than max_rows)
    local rows=$(( count < max_rows ? count : max_rows ))

    # how many lines we print each frame: top border + rows + bottom border
    local printed_lines=$(( rows + 2 ))

    # print prompt above the box
    printf "\n%s\n" "$prompt"

    while true; do
        # On subsequent renders, move cursor up exactly the number of printed lines
        if ! $first_render; then
            printf "\e[%dA" "$printed_lines"
        else
            first_render=false
        fi

        # Build the full inner width for borders
        local inner_width=$(( cols * field_width ))

        # Top border (ASCII)
        printf "+"
        for (( i=0; i<inner_width; i++ )); do printf "-"; done
        printf "+\n"

        # Render each row inside the box
        for (( row=0; row<rows; row++ )); do
            printf "|"
            for (( col=0; col<cols; col++ )); do
                idx=$(( col*max_rows + row ))
                if (( idx < count )); then
                    option="${options[idx]}"
                    if (( idx == cur )); then
                        # highlighted: exactly field_width visible chars
                        # " > " = 3 chars, option padded to content_max, " " = 1 char
                        printf " > "
                        printf "${esc}[7m%-*s${esc}[27m" "$content_max" "$option"
                        printf " "
                    else
                        # non-highlighted: exactly field_width visible chars
                        printf "   %-*s " "$content_max" "$option"
                    fi
                else
                    # empty: exactly field_width spaces
                    printf "%*s" "$field_width" ""
                fi
            done
            printf "|\n"
        done

        # Bottom border (ASCII)
        printf "+"
        for (( i=0; i<inner_width; i++ )); do printf "-"; done
        printf "+\n"

        # Read key (arrow keys send ESC [ A/B/C/D)
        IFS= read -rsn1 key
        if <<< "$key" grep -q '[a-zA-Z0-9]'; then
            # Regular character, process immediately
            :
        elif [[ $key == "$esc" ]]; then
            # read the rest of the sequence
            read -rsn2 -t 0.0001 rest 2>/dev/null || rest=""
            key+="$rest"
        fi

        case "$key" in
            $esc'[A'|$'\x1b[A'|k|K)  # Up
                ((cur--))
                ((cur < 0)) && cur=$((count - 1))
                ;;
            $esc'[B'|$'\x1b[B'|j|J)  # Down
                ((cur++))
                ((cur >= count)) && cur=0
                ;;
            $esc'[C'|$'\x1b[C'|l|L)  # Right
                ((cur += max_rows))
                ((cur >= count)) && cur=$((cur % max_rows))
                ;;
            $esc'[D'|$'\x1b[D'|h|H)  # Left
                ((cur -= max_rows))
                ((cur < 0)) && cur=$((cur + max_rows * cols))
                ((cur >= count)) && cur=$((count - 1))
                ;;
            "")  # Enter
                break
                ;;
            q|Q)  # Quit
                return 1
                ;;
        esac
    done

    printf -v "$outvar" "%s" "${options[$cur]}"
    return 0
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