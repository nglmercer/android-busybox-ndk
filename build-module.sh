#!/bin/bash
# Build script for Android BusyBox NDK Magisk Module
# Usage: ./build-module.sh [arch] [version]

set -e

# Configuration
BUSYBOX_VERSION="${1:-1.36.1}"
NDK_PATH="${NDK_PATH:-/opt/android-ndk}"
OUT_DIR="${OUT_DIR:-./output}"
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

build_arch() {
    local arch=$1
    local triple
    local install_dir
    
    case $arch in
        arm)
            triple="arm-linux-androideabi"
            ;;
        arm64)
            triple="aarch64-linux-android"
            ;;
        x86)
            triple="i686-linux-android"
            ;;
        x86_64)
            triple="x86_64-linux-android"
            ;;
    esac
    
    log_info "Building BusyBox for ${arch}..."
    
    # Create build directory
    local build_dir="${OUT_DIR}/build-${arch}"
    mkdir -p "${build_dir}"
    
    cd "${build_dir}"
    
    # Clone BusyBox if not exists
    if [ ! -d "busybox" ]; then
        log_info "Cloning BusyBox ${BUSYBOX_VERSION}..."
        git clone --depth 1 --branch ${BUSYBOX_VERSION} https://git.busybox.net/busybox.git
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
    local cross_compile="${NDK_PATH}/toolchains/llvm/prebuilt/linux-x86_64/bin/${triple}21-"
    local sysroot="${NDK_PATH}/toolchains/llvm/prebuilt/linux-x86_64/sysroot"
    
    sed -i "s|CONFIG_CROSS_COMPILER_PREFIX=\"\"|CONFIG_CROSS_COMPILER_PREFIX=\"${cross_compile}\"|g" .config
    sed -i "s|CONFIG_SYSROOT=\"\"|CONFIG_SYSROOT=\"${sysroot}\"|g" .config
    
    # Build
    log_info "Compiling BusyBox for ${arch}..."
    export CROSS_COMPILE="${cross_compile}"
    export ARCH="${arch}"
    
    make -j$(nproc)
    make install
    
    # Copy to module directory
    install_dir="${MODULE_DIR}/system/bin/${arch}"
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

    # Create update-binary
    cat > "${MODULE_DIR}/META-INF/com/google/android/update-binary" << 'UPDATER_EOF'
#!/bin/sh
# Magisk update-binary
umask 022

ui_print() { echo "$1"; }
api_level() { cat /proc/version | grep -oE 'android.[0-9]+' | cut -d. -f2; }

ui_print "- Installing BusyBox NDK..."

# Get architecture
ARCH=$(getprop ro.product.cpu.abi | cut -d'-' -f1)
[ -z "$ARCH" ] && ARCH=$(uname -m)

case "$ARCH" in
    arm*)
        ARCH_DIR="arm"
        ;;
    aarch64*)
        ARCH_DIR="arm64"
        ;;
    x86*)
        ARCH_DIR="$ARCH"
        ;;
    *)
        ARCH_DIR="arm"
        ;;
esac

# Install binary
if [ -f "/system/bin/${ARCH_DIR}/busybox" ]; then
    cp /system/bin/${ARCH_DIR}/busybox /system/bin/busybox
    chmod 755 /system/bin/busybox
    
    # Create symlinks
    for applet in $(/system/bin/busybox --list); do
        if [ ! -e "/system/bin/$applet" ] && [ ! -e "/system/xbin/$applet" ]; then
            ln -sf /system/bin/busybox /system/xbin/$applet 2>/dev/null
        fi
    done
    
    ui_print "- BusyBox installed successfully!"
else
    ui_print "- Error: BusyBox binary not found for $ARCH_DIR"
    exit 1
fi

ui_print "- Done!"
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
# Custom installation script

# Set permissions
set_perm(0, 0, 0755, "/system/bin/busybox");

# Create symlinks
if [ -f "/system/bin/busybox" ]; then
    for applet in $(/system/bin/busybox --list); do
        if [ ! -e "/system/bin/$applet" ] && [ ! -e "/system/xbin/$applet" ]; then
            ln -sf /system/bin/busybox /system/xbin/$applet 2>/dev/null
        fi
    done
fi
EOF
    chmod 755 "${MODULE_DIR}/customize.sh"
}

package_module() {
    log_info "Packaging module..."
    
    cd "${OUT_DIR}"
    
    # Create the zip file
    local zip_name="android-busybox-ndk-v${BUSYBOX_VERSION}.zip"
    zip -r "${zip_name}" module/
    
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
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export SCRIPT_DIR

cleanup
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
