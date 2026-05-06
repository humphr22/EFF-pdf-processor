#!/bin/bash

# --- TERMINAL AUTO-OPENER ---
if [ ! -t 0 ]; then
    x-terminal-emulator -e "$0"
    exit 0
fi

TARGET_DIR="$HOME/Documents/scans"
CROPPED_DIR="$TARGET_DIR/cropped"
mkdir -p "$CROPPED_DIR"

# --- PRE-FLIGHT CHECK: PDF ARRANGER ---
echo "--- Initial Review ---"
if ls "$TARGET_DIR"/*.pdf 1> /dev/null 2>&1; then
    read -p "Would you like to open the source PDF(s) in pdfarranger to review/edit? (y/n): " review_choice
    if [[ "$review_choice" == "y" ]]; then
        echo "Launching pdfarranger..."
        if command -v pdfarranger &> /dev/null; then
            nohup pdfarranger "$TARGET_DIR"/*.pdf > /dev/null 2>&1 &
            disown
        elif flatpak list 2>/dev/null | grep -q -i "pdfarranger"; then
            FLATPAK_ID=$(flatpak list --app --columns=application | grep -i "pdfarranger" | head -n 1)
            nohup flatpak run "$FLATPAK_ID" "$TARGET_DIR"/*.pdf > /dev/null 2>&1 &
            disown
        else
            echo "Warning: pdfarranger not found."
        fi
        echo "Please review, save your changes, and close pdfarranger when done."
    fi
else
    echo "Error: No PDF files found in $TARGET_DIR!"
    read -p "Press [ENTER] to exit..."
    exit 1
fi

echo ""
read -p "Are you ready to start the automated processing? (y/n): " ready_choice
if [[ "$ready_choice" != "y" ]]; then
    echo "Exiting script."
    sleep 2
    exit 0
fi

# --- STEP 1: PDF DECOMPILE ---
if cd "$TARGET_DIR"; then
    echo "-----------------------------------"
    for file in *.pdf; do
        [ -e "$file" ] || break
        if [[ "$file" == *_page_*.pdf ]]; then continue; fi
        filename="${file%.pdf}"
        echo "Decompiling: $file..."
        pdfseparate "$file" "${filename}_page_%03d.pdf"
    done
fi
echo "Step 1 Complete!"

# --- STEP 2: PDF TO JPG CONVERSION ---
echo "Starting conversion to JPG..."
for file in *_page_*.pdf; do
    [ -e "$file" ] || break
    echo "Converting: $file..."
    pdftoppm -jpeg -r 300 "$file" "${file%.pdf}"
done
echo "Step 2 Complete!"

# --- GIMP COORDINATE CHECK ---
reference_image=$(ls -1 *.jpg 2>/dev/null | head -n 1)
if [ -n "$reference_image" ]; then
    echo "-----------------------------------"
    echo "Opening '$reference_image' in GIMP for crop coordinates."
    
    if command -v gimp &> /dev/null; then
        GIMP_CMD="gimp"
    elif flatpak list 2>/dev/null | grep -q -i "org.gimp.GIMP"; then
        GIMP_CMD="flatpak run org.gimp.GIMP"
    else
        GIMP_CMD=""
    fi

    if [ -n "$GIMP_CMD" ]; then
        nohup $GIMP_CMD "$reference_image" > /dev/null 2>&1 &
        disown
        echo ""
        read -p "Press [ENTER] here once you have your coordinates from GIMP..."
    fi
fi

# --- STEP 2.5: BATCH CROP ---
while true; do
    echo "--- Crop Configuration ---"
    read -p "Enter X position (Left offset): " X
    read -p "Enter Y position (Top offset): " Y
    read -p "Enter Width: " W
    read -p "Enter Height: " H
    CROP_ZONE="${W}x${H}+${X}+${Y}"

    echo ""
    read -p "Enter the new filename stem: " STEM
    
    count=1
    for file in *.jpg; do
        [ -e "$file" ] || continue
        suffix=$(printf "%03d" $count)
        convert "$file" -crop "$CROP_ZONE" +repage "cropped/${STEM}_${suffix}.jpg"
        ((count++))
    done
    
    echo "Batch complete! Files are in $CROPPED_DIR"
    read -p "Another crop round? (y/n): " choice
    [[ "$choice" != "y" ]] && break
done

# --- STEP 3: MULTI-PAGE ASSEMBLY ---
cd "$CROPPED_DIR" || { echo "Error: Could not enter $CROPPED_DIR"; exit 1; }

echo "--- Assembly Configuration ---"
echo "How many images per page? (e.g., 4):"
read -r rows
rows=$(echo "$rows" | tr -dc '0-9')
[[ -z "$rows" ]] && rows=4

echo "1) In Order (Chronological)"
echo "2) Randomly (Shuffled)"
read -p "Selection (1 or 2): " order_choice

# Gather files
if [ "$order_choice" == "2" ]; then
    mapfile -t FILES < <(shuf -e *.jpg)
else
    FILES=(*.jpg)
fi

TOTAL_FILES=${#FILES[@]}
OUTPUT_PDF="contact_sheet_$(date +%Y%m%d_%H%M%S).pdf"
TEMP_DIR=$(mktemp -d)

if [ "$TOTAL_FILES" -eq 0 ]; then
    echo "ERROR: No JPG files found."
else
    echo "Processing $TOTAL_FILES images into pages..."

    page_num=1
    for (( i=0; i<TOTAL_FILES; i+=rows )); do
        chunk=("${FILES[@]:i:rows}")
        
        echo "Generating Page $page_num..."
        
        # 1. Create a temporary montage for this chunk
        montage "${chunk[@]}" -background none -tile 1x -geometry +5+5 "$TEMP_DIR/page.png"
        
        # 2. Format for Top Half with 1-inch (72pt) Margin
        # -resize "450x324>": Height restricted to 324 to leave exactly 1/2 page clear
        # -splice 0x72: Creates the 1-inch top margin
        convert "$TEMP_DIR/page.png" -background none -resize "450x324>" \
                -gravity North -splice 0x72 -extent 612x792 \
                "$TEMP_DIR/page_$(printf "%03d" $page_num).pdf"
        
        ((page_num++))
    done

    echo "Combining pages..."
    pdfunite "$TEMP_DIR"/page_*.pdf "$OUTPUT_PDF"
    rm -rf "$TEMP_DIR"
    
    echo "Document generated with 1-inch margin: $OUTPUT_PDF"
fi
echo "-----------------------------------"

# --- STEP 3.5: APPLY PDF LETTERHEAD TO ALL PAGES ---
if [ -f "$OUTPUT_PDF" ]; then
    echo "Do you want to apply your PDF letterhead to EVERY page? (y/n)"
    read -p "Selection: " template_choice

    if [[ "$template_choice" == "y" ]]; then
        if ! command -v pdftk &> /dev/null; then
            echo "ERROR: 'pdftk' is not installed. Run 'sudo apt install pdftk'."
        else
            echo "Drag and drop your PDF letterhead here: "
            read -e LETTERHEAD_PDF
            LETTERHEAD_PDF=$(echo "$LETTERHEAD_PDF" | tr -d "'\"")
            
            if [ -f "$LETTERHEAD_PDF" ]; then
                BRANDED_PDF="${OUTPUT_PDF%.pdf}_branded.pdf"
                
                # pdftk applies a 1-page background to all pages of the input PDF automatically
                pdftk "$OUTPUT_PDF" background "$LETTERHEAD_PDF" output "$BRANDED_PDF"
                
                if [ -f "$BRANDED_PDF" ]; then
                    echo "Success! Letterhead applied to all pages."
                    OUTPUT_PDF="$BRANDED_PDF"
                fi
            else
                echo "Letterhead not found."
            fi
        fi
    fi
fi

# --- STEP 4: OPEN IN XOURNAL ---
if [ -f "$OUTPUT_PDF" ]; then
    echo "Opening your final document in Xournal..."

    if command -v xournalpp &> /dev/null; then
        nohup xournalpp "$OUTPUT_PDF" > /dev/null 2>&1 &
        disown
    elif command -v xournal &> /dev/null; then
        nohup xournal "$OUTPUT_PDF" > /dev/null 2>&1 &
        disown
    elif flatpak list 2>/dev/null | grep -q -i "xournalpp"; then
        XOURNAL_FLATPAK=$(flatpak list --app --columns=application | grep -i "xournalpp" | head -n 1)
        nohup flatpak run "$XOURNAL_FLATPAK" "$OUTPUT_PDF" > /dev/null 2>&1 &
        disown
    elif flatpak list 2>/dev/null | grep -q -i "xournal"; then
        XOURNAL_FLATPAK=$(flatpak list --app --columns=application | grep -i "xournal" | head -n 1)
        nohup flatpak run "$XOURNAL_FLATPAK" "$OUTPUT_PDF" > /dev/null 2>&1 &
        disown
    else
        echo "Warning: Xournal command not found."
    fi
fi

echo ""
read -p "Process complete. Press [ENTER] to close the terminal..."
