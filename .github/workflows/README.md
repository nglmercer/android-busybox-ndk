# Magisk Module Build Workflow

This directory contains GitHub Actions workflows for building and publishing the Android BusyBox NDK Magisk module.

## Workflows

### Build and Release (`build.yml`)

The main workflow that:
1. Builds BusyBox for all architectures (arm, arm64, x86, x86_64)
2. Packages everything into a Magisk module ZIP
3. Creates a GitHub Release automatically when a tag is pushed

## Usage

### Automatic Builds (Recommended)

Push a tag with the version number to trigger a release:

```bash
git tag v1.36.1
git push origin v1.36.1
```

This will:
- Build the module for all architectures
- Create a GitHub Release
- Upload the ZIP file as a release asset

### Manual Builds

You can trigger a manual build from the GitHub Actions tab:

1. Go to Actions -> Build and Release
2. Click "Run workflow"
3. Enter the BusyBox version (e.g., 1.36.1)
4. Click "Run workflow"

## Local Development

For local builds, use the `build-module.sh` script:

```bash
# Build for all architectures
./build-module.sh 1.36.1

# Build for specific architecture
./build-module.sh 1.36.1 arm

# Build with custom NDK path
NDK_PATH=/path/to/ndk ./build-module.sh 1.36.1
```

## Module Structure

The generated Magisk module contains:

```
module.zip/
├── META-INF/
│   └── com/
│       └── google/
│           └── android/
│               ├── update-binary
│               └── updater-script
├── system/
│   └── bin/
│       ├── busybox (main binary)
│       ├── busybox-arm/
│       ├── busybox-arm64/
│       ├── busybox-x86/
│       └── busybox-x86_64/
├── module.prop
├── post-fs-data.sh
├── service.sh
└── customize.sh
```

## Requirements

- Ubuntu 22.04 or similar
- Android NDK r25c or later
- Build tools (make, gcc, etc.)
- Git
- wget/zip

## Configuration

The workflow uses:
- **BusyBox version**: 1.36.1 (configurable)
- **NDK version**: r25c
- **Target API**: 21 (Android 5.0+)
