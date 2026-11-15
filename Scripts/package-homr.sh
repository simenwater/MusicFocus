#!/bin/sh
set -eu

dest="$TARGET_BUILD_DIR/$UNLOCALIZED_RESOURCES_FOLDER_PATH/ScoreRecognitionModels"
case "$MUSICFOCUS_INCLUDE_HOMR" in
    NO)
        # An incremental build may reuse the previous recognition-enabled app.
        if [ -d "$dest" ]; then rm -r "$dest"; fi
        ;;
    YES)
        mkdir -p "$dest"
        for asset in segnet.onnx encoder.onnx decoder.onnx vocabulary.json YDP-GrandPiano.sf2 HOMR-LICENSE.txt YDP-GrandPiano-LICENSE.txt; do
            if [ ! -s "$SCRIPT_INPUT_FILE_1/$asset" ]; then
                echo "error: Missing recognition resource $asset" >&2
                exit 1
            fi
            cp -p "$SCRIPT_INPUT_FILE_1/$asset" "$dest/$asset"
        done
        ;;
    *)
        echo "error: MUSICFOCUS_INCLUDE_HOMR must be YES or NO" >&2
        exit 1
        ;;
esac
