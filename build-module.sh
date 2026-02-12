#!/bin/bash
# Build script for Android BusyBox NDK Magisk Module
# Usage: ./build-module.sh [version] [arch]

set -e

# Script directory (must be at top)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export SCRIPT_DIR

# Configuration
BUSYBOX_VERSION="${1:-1.36.1}"
NDK_VERSION="r25c"
NDK_PATH="${NDK_PATH:-${SCRIPT_DIR}/android-ndk-${NDK_VERSION}}"
OUT_DIR="${OUT_DIR:-${SCRIPT_DIR}/output}"
MODULE_DIR="${OUT_DIR}/module"

# Architectures to build
ARCHS="${2:-arm arm64 x86 x86_64}"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

cleanup() {
    log_info "Cleaning up..."
    rm -rf "${OUT_DIR}"
}

detect_ndk_prebuilt() {
    # Detect the prebuilt directory based on OS and architecture
    local os=$(uname -s | tr '[:upper:]' '[:lower:]')
    local arch=$(uname -m)
    
    case "${os}-${arch}" in
        linux-x86_64)
            echo "linux-x86_64"
            ;;
        linux-aarch64|linux-arm64)
            echo "linux-aarch64"
            ;;
        darwin-x86_64)
            echo "darwin-x86_64"
            ;;
        darwin-arm64|darwin-aarch64)
            echo "darwin-arm64"
            ;;
        *)
            log_warn "Unknown platform: ${os}-${arch}, defaulting to linux-x86_64"
            echo "linux-x86_64"
            ;;
    esac
}

download_ndk() {
    if [ ! -d "${NDK_PATH}" ]; then
        log_info "Downloading Android NDK ${NDK_VERSION}..."
        local os=$(uname -s | tr '[:upper:]' '[:lower:]')
        local ndk_zip="android-ndk-${NDK_VERSION}-${os}.zip"
        
        if [ ! -f "${ndk_zip}" ]; then
            wget -q "https://dl.google.com/android/repository/${ndk_zip}"
        fi
        
        log_info "Extracting NDK..."
        unzip -q "${ndk_zip}"
        
        # Rename to expected path if needed
        if [ -d "android-ndk-${NDK_VERSION}" ] && [ "android-ndk-${NDK_VERSION}" != "${NDK_PATH}" ]; then
            mv "android-ndk-${NDK_VERSION}" "${NDK_PATH}"
        fi
    else
        log_info "NDK already exists at ${NDK_PATH}"
    fi
}

setup_ndk_symlinks() {
    log_info "Setting up NDK symlinks..."
    local prebuilt_dir=$(detect_ndk_prebuilt)
    local ndk_bin="${NDK_PATH}/toolchains/llvm/prebuilt/${prebuilt_dir}/bin"
    cd "${ndk_bin}"
    
    # Create symlinks for cross-compilation tools (using llvm tools)
    for tool in llvm-ar llvm-as llvm-nm llvm-objcopy llvm-objdump llvm-ranlib llvm-strip; do
        base=$(basename "$tool")
        tool_name=${base#llvm-}  # Remove 'llvm-' prefix
        for target in aarch64-linux-android21 armv7a-linux-androideabi21 i686-linux-android21 x86_64-linux-android21; do
            if [ -f "${tool}" ] && [ ! -f "${target}-${tool_name}" ]; then
                ln -sf "${PWD}/${tool}" "${target}-${tool_name}"
            fi
        done
    done
}

build_arch() {
    local arch=$1
    local triple
    local install_dir
    
    case $arch in
        arm)
            triple="armv7a-linux-androideabi21-"
            ;;
        arm64)
            triple="aarch64-linux-android21-"
            ;;
        x86)
            triple="i686-linux-android21-"
            ;;
        x86_64)
            triple="x86_64-linux-android21-"
            ;;
    esac
    
    log_info "Building BusyBox for ${arch}..."
    
    # Create build directory
    local build_dir="${OUT_DIR}/build-${arch}"
    mkdir -p "${build_dir}"
    
    cd "${build_dir}"
    
    # Clone BusyBox if not exists
    if [ ! -d "busybox" ]; then
        log_info "Downloading BusyBox ${BUSYBOX_VERSION}..."
        wget -q https://busybox.net/downloads/busybox-${BUSYBOX_VERSION}.tar.bz2
        tar -xjf busybox-${BUSYBOX_VERSION}.tar.bz2
        mv busybox-${BUSYBOX_VERSION} busybox
    fi
    
    cd busybox
    
    # Copy config
    cp "${SCRIPT_DIR}/osm0sis-basic-unified.config" .config
    
    # Apply patches
    for patch in "${SCRIPT_DIR}/patches/"*.patch; do
        if [ -f "$patch" ]; then
            log_info "Applying patch: $(basename $patch)"
            git am --whitespace=nowarn "$patch" 2>/dev/null || true
        fi
    done
    
    # Configure
    local prebuilt_dir=$(detect_ndk_prebuilt)
    local cross_compile="${NDK_PATH}/toolchains/llvm/prebuilt/${prebuilt_dir}/bin/${triple}"
    local sysroot="${NDK_PATH}/toolchains/llvm/prebuilt/${prebuilt_dir}/sysroot"
    
    sed -i "s|CONFIG_CROSS_COMPILER_PREFIX=\"\"|CONFIG_CROSS_COMPILER_PREFIX=\"${cross_compile}\"|g" .config
    sed -i 's|CONFIG_EXTRA_CFLAGS=.*|CONFIG_EXTRA_CFLAGS="-DANDROID -D__ANDROID__ -D__ANDROID_API__=21 -Os"|g' .config
    sed -i 's|CONFIG_EXTRA_LDFLAGS=.*|CONFIG_EXTRA_LDFLAGS="-Wl,-z,max-page-size=16384"|g' .config
    sed -i 's|CONFIG_STATIC=y|# CONFIG_STATIC is not set|g' .config
    sed -i 's|CONFIG_STATIC_LIBGCC=y|# CONFIG_STATIC_LIBGCC is not set|g' .config
    sed -i "s|CONFIG_SYSROOT=\"\"|CONFIG_SYSROOT=\"${sysroot}\"|g" .config
    
    # Build
    log_info "Compiling BusyBox for ${arch}..."
    export CROSS_COMPILE="${cross_compile}"
    export ARCH="${arch}"
    
    make -j$(nproc)
    make install
    
    # Copy to module directory (use a temp path for architecture selection)
    install_dir="${MODULE_DIR}/custom/${arch}"
    mkdir -p "${install_dir}"
    cp -r _install/* "${install_dir}/"
    
    log_info "Completed ${arch} build"
}

create_module() {
    log_info "Creating Magisk module structure..."
    
    mkdir -p "${MODULE_DIR}/META-INF/com/google/android"
    mkdir -p "${MODULE_DIR}/system/bin"
    
    # Create module.prop
    cat > "${MODULE_DIR}/module.prop" << EOF
id=android-busybox-ndk
name=Android BusyBox NDK
version=${BUSYBOX_VERSION}
versionCode=1
author=Build Script
description=BusyBox ${BUSYBOX_VERSION} compiled with Android NDK for Magisk
EOF

    # Create update-binary (standard Magisk boilerplate)
    cat > "${MODULE_DIR}/META-INF/com/google/android/update-binary" << 'UPDATER_EOF'
#!/stow/bin/sh
# Magisk update-binary (dummy, customize.sh handles the work)
exit 0
UPDATER_EOF
    chmod 755 "${MODULE_DIR}/META-INF/com/google/android/update-binary"

    # Create updater-script
    cat > "${MODULE_DIR}/META-INF/com/google/android/updater-script" << 'EOF'
# Magisk updater-script
ui_print(" BusyBox NDK Module");
EOF

    # Create post-fs-data.sh
    cat > "${MODULE_DIR}/post-fs-data.sh" << 'EOF'
#!/system/bin/sh
# Post-fs-data script
# Add any post-mount configurations here
EOF
    chmod 755 "${MODULE_DIR}/post-fs-data.sh"

    # Create service.sh
    cat > "${MODULE_DIR}/service.sh" << 'EOF'
#!/system/bin/sh
# Service script
# Add any service configurations here
EOF
    chmod 755 "${MODULE_DIR}/service.sh"

    # Create customize.sh
    cat > "${MODULE_DIR}/customize.sh" << 'EOF'
#!/system/bin/sh
# Custom installation script for Magisk

# Detect architecture
case $ARCH in
  arm)     ARCH_DIR="arm" ;;
  arm64)   ARCH_DIR="arm64" ;;
  x86)     ARCH_DIR="x86" ;;
  x64)     ARCH_DIR="x86_64" ;;
  *)       ARCH_DIR="arm64" ;; # Default
esac

ui_print "- Architecture detected: $ARCH"
ui_print "- Installing BusyBox for $ARCH_DIR..."

if [ ! -d "$MODPATH/custom/$ARCH_DIR" ]; then
    ui_print "! Error: Binary for $ARCH_DIR not found in module"
    abort
fi

# Move content to system/bin
mkdir -p "$MODPATH/system/bin"
cp -af "$MODPATH/custom/$ARCH_DIR/." "$MODPATH/system/bin/"
rm -rf "$MODPATH/custom"

# Set permissions
set_perm 0 0 0755 "$MODPATH/system/bin/busybox"

# Create symlinks
ui_print "- Creating applet symlinks..."
for applet in "$MODPATH/system/bin/busybox" --list; do
    # We use the binary directly to get the list
    appList=$("$MODPATH/system/bin/busybox" --list)
    for a in $appList; do
        if [ "$a" != "busybox" ]; then
            ln -sf busybox "$MODPATH/system/bin/$a"
        fi
    done
    break
done
EOF
    chmod 755 "${MODULE_DIR}/customize.sh"
}

package_module() {
    log_info "Packaging module..."
    
    # Create the zip file from inside the module directory
    local zip_name="android-busybox-ndk-v${BUSYBOX_VERSION}.zip"
    cd module
    zip -r "../${zip_name}" .
    cd ..
    
    log_info "Module created: ${zip_name}"
    
    # Print summary
    echo ""
    log_info "=== Build Summary ==="
    log_info "Version: ${BUSYBOX_VERSION}"
    log_info "Architectures: ${ARCHS}"
    log_info "Output: ${zip_name}"
    echo ""
    log_info "To install: Copy the ZIP to your device and install via Magisk"
}

# Main execution
cleanup
download_ndk
setup_ndk_symlinks
mkdir -p "${OUT_DIR}"

# Build each architecture
for arch in $ARCHS; do
    build_arch $arch
done

# Create module structure
create_module

# Package
package_module

log_info "Build complete!"
