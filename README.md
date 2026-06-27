# Table Drop

A lightweight macOS app for uploading CSV files to BigQuery. It shells out to [`upload-bq-dataset`](https://pypi.org/project/upload-bq-dataset/) and reuses your existing `gcloud` / `bq` credentials — no API keys or OAuth setup in the app itself.

## Prerequisites

1. [Google Cloud SDK](https://cloud.google.com/sdk/docs/install) with `bq` and `gcloud` installed
2. `upload-bq-dataset` CLI installed (e.g. `pip install upload-bq-dataset`)
3. Authenticated CLI session:

```bash
gcloud auth login
gcloud auth application-default login   # optional, if bq asks for ADC
```

## Build & run

Open `TableDrop/TableDrop.xcodeproj` in Xcode and press **⌘R**.

Or from the command line:

```bash
cd TableDrop
xcodebuild -scheme TableDrop -configuration Release build
open build/Release/TableDrop.app
```

## Usage

1. Enter the destination as `project_id.dataset_id.table_id` (saved between launches).
2. Drop a `.csv` file onto the drop zone, or click to browse.
3. Click **Upload to BigQuery**.

The app runs:

```bash
upload-bq-dataset data.csv --project PROJECT --dataset DATASET --table TABLE [--replace]
```

Before uploading, it checks BigQuery via `bq show`:

1. Creates the dataset with `bq mk -d` if it does not exist.
2. Creates the table on upload if it does not exist (`upload-bq-dataset` autodetects schema and column names from the CSV header).
3. Passes `--replace` if the table already exists.

## Notes

- Sandbox is disabled so the app can invoke CLI tools and read files from anywhere on disk.
- If CLIs are not on the GUI app's PATH, the uploader checks common install locations (`~/.pyenv/shims`, `~/google-cloud-sdk/bin`, Homebrew, etc.).

## Genereating icons

```sh
SVG="icon.svg"
ASSETS="Assets.xcassets"
OUT="$ASSETS/AppIcon.appiconset"

rm -rf "$ASSETS"
mkdir -p "$OUT"

for PIXELS in 16 32 64 128 256 512 1024; do
  rsvg-convert \
    --keep-aspect-ratio \
    --background-color=none \
    --width="$PIXELS" \
    --height="$PIXELS" \
    --format=png \
    --output="$OUT/icon_${PIXELS}.png" \
    "$SVG"
done

cat > "$ASSETS/Contents.json" <<'JSON'
{
  "info": {
    "author": "xcode",
    "version": 1
  }
}
JSON

cat > "$OUT/Contents.json" <<'JSON'
{
  "images": [
    { "idiom": "mac", "size": "16x16",  "scale": "1x", "filename": "icon_16.png" },
    { "idiom": "mac", "size": "16x16",  "scale": "2x", "filename": "icon_32.png" },
    { "idiom": "mac", "size": "32x32",  "scale": "1x", "filename": "icon_32.png" },
    { "idiom": "mac", "size": "32x32",  "scale": "2x", "filename": "icon_64.png" },
    { "idiom": "mac", "size": "128x128", "scale": "1x", "filename": "icon_128.png" },
    { "idiom": "mac", "size": "128x128", "scale": "2x", "filename": "icon_256.png" },
    { "idiom": "mac", "size": "256x256", "scale": "1x", "filename": "icon_256.png" },
    { "idiom": "mac", "size": "256x256", "scale": "2x", "filename": "icon_512.png" },
    { "idiom": "mac", "size": "512x512", "scale": "1x", "filename": "icon_512.png" },
    { "idiom": "mac", "size": "512x512", "scale": "2x", "filename": "icon_1024.png" }
  ],
  "info": {
    "author": "xcode",
    "version": 1
  }
}
JSON

ls -lh "$OUT"/*.png
```

If dock icon isn't updated, relaunch dock:

```sh
rm -rf ~/Library/Developer/Xcode/DerivedData

# Replace com.your.bundle.id with your real bundle identifier
rm -rf ~/Library/Caches/com.apple.iconservices.store
rm -rf ~/Library/Caches/com.apple.iconservices
rm -rf /var/folders/*/*/*/com.apple.iconservices 2>/dev/null

killall Dock
killall Finder
```
