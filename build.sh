#!/usr/bin/env bash
workdir=$(pwd)
exec > >(tee $workdir/build.log) 2>&1

# Check for required variables
set -e

required_vars=("CHAT_ID" "TOKEN" "GH_TOKEN")

for var in "${required_vars[@]}"; do
    if [[ -z ${!var:-} ]]; then
        error "$var is not set!"
    fi
done

# ---------------
# 	MAIN
# ---------------

# Import configuration
source $workdir/config.sh
# Import functions
source $workdir/functions.sh

# Set up timezone
sudo timedatectl set-timezone $TZ

# Clone needed repositories
cd $workdir

# Kernel patches source
log "Cloning kernel patch from (ChiseWaguri/kernel-patches) into $workdir/chise_patches"
git clone -q --depth=1 https://github.com/ChiseWaguri/kernel-patches chise_patches
log "Cloning kernel patch from (WildPlusKernel/kernel-patches) into $workdir/wildplus_patches"
git clone -q --depth=1 https://github.com/WildPlusKernel/kernel_patches wildplus_patches

# Kernel source
log "Cloning kernel source from ($(basename "$KERNEL_REPO")) to $workdir/common"
git clone -q --depth=1 $KERNEL_REPO -b $KERNEL_BRANCH common

# Extract kernel version
cd $workdir/common
KERNEL_VERSION=$(make kernelversion)

# Set variant
log "Setting KernelSU variant..."
declare -A KSU_VARIANTS=(
    ["Official"]="KSU"
    ["Rissu"]="RKSU"
    ["Next"]="KSUN"
    ["xx's"]="XXKSU"
)

VARIANT="${KSU_VARIANTS[$KSU]:-none}"

# Append SUSFS if enabled
[[ $USE_KSU_SUSFS == "true" && $VARIANT != "none" ]] && VARIANT+="xSUSFS"

# Set ZIP_NAME with replacements
ZIP_NAME=${ZIP_NAME//KVER/$KERNEL_VERSION}

# Handle VARIANT replacement in ZIP_NAME
if [[ $VARIANT == "none" ]]; then
    ZIP_NAME=${ZIP_NAME//-VARIANT/} # Remove "-VARIANT" if no variant
else
    ZIP_NAME=${ZIP_NAME//VARIANT/$VARIANT} # Replace VARIANT placeholder
fi

# Download Toolchains
cd $workdir

# Determine Clang source
if [[ $USE_AOSP_CLANG == "true" ]]; then
    if [[ $AOSP_CLANG_SOURCE =~ ^https?:// ]]; then
        CLANG_URL="$AOSP_CLANG_SOURCE"
    else
        CLANG_URL="https://android.googlesource.com/platform/prebuilts/clang/host/linux-x86/+archive/refs/heads/main/clang-${AOSP_CLANG_SOURCE}.tar.gz"
    fi
elif [[ $USE_CUSTOM_CLANG == "true" ]]; then
    CLANG_URL="$CUSTOM_CLANG_SOURCE"
else
    error "❌ No Clang toolchain selected. Set USE_AOSP_CLANG or USE_CUSTOM_CLANG."
fi

# Set CLANG_INFO
CLANG_INFO="$CLANG_URL"
if [[ $CLANG_URL != *.tar.* && -n $CUSTOM_CLANG_BRANCH ]]; then
    CLANG_INFO+=" | $CUSTOM_CLANG_BRANCH"
fi
log "Clang used is $CLANG_INFO..."

# Check if Clang is already installed
CLANG_PATH="$workdir/tc"

if [[ ! -x $CLANG_PATH/bin/clang || ! -f $CLANG_PATH/VERSION || "$(cat $CLANG_PATH/VERSION)" != "$CLANG_INFO" ]]; then
    log "Cache of $CLANG_INFO is not found."
    log "🔽 Downloading Clang from ($CLANG_INFO)..."
    rm -rf "$CLANG_PATH"

    if [[ $USE_AOSP_CLANG == "true" || $CLANG_URL == *.tar.* ]]; then
        mkdir -p "$CLANG_PATH"
        wget -qO clang-tarball "$CLANG_URL" || error "Failed to download Clang."
        tar -xf clang-tarball -C "$CLANG_PATH/" || error "Failed to extract Clang."
        rm -f clang-tarball
        while [ "$(find "$CLANG_PATH" -mindepth 1 -maxdepth 1 -type d | wc -l)" -eq 1 ]; do
            single_dir=$(find "$CLANG_PATH" -mindepth 1 -maxdepth 1 -type d)
            mv "$single_dir"/* "$CLANG_PATH"/
            rmdir "$single_dir"
        done
    else
        git clone -q --depth=1 -b "$CUSTOM_CLANG_BRANCH" "$CLANG_URL" "$CLANG_PATH" || error "Clang download failed."
    fi

    echo "$CLANG_INFO" >"$CLANG_PATH/VERSION"
else
    log "✅ Using cached Clang: $CLANG_INFO."
fi

# Set Clang as compiler
export CC="ccache clang"
export CXX="ccache clang++"
export HOSTCC="$CC"
export HOSTCXX="$CXX"

# Set $PATH
export PATH="$CLANG_PATH/bin:$PATH"

# Ensure binutils (aarch64-linux-gnu) is available
if ! find "$CLANG_PATH/bin" -name "aarch64-linux-gnu-*" | grep -q .; then
    if find "$CLANG_PATH/binutils" -name "aarch64-linux-gnu-*" | grep -q .; then
        log "✅ aarch64-linux-gnu found in $CLANG_PATH/binutils."
    else
        log "🔍 aarch64-linux-gnu not found. Cloning binutils..."
        git clone -q --depth=1 https://android.googlesource.com/platform/prebuilts/gas/linux-x86 "$CLANG_PATH/binutils" || error "❌ Failed to clone binutils."
    fi
    export PATH="$CLANG_PATH/binutils:$PATH"
else
    log "✅ aarch64-linux-gnu found in $CLANG_PATH."
fi

# Extract clang version
COMPILER_STRING=$(clang -v 2>&1 | head -n 1 | sed 's/(https..*//' | sed 's/ version//')

# Apply LineageOS maphide patch (thanks to @backslashxx and @WildPlusKernel)
cd $workdir/common
log "Patching LineageOS maphide patch..."
if ! patch -p1 <$workdir/wildplus_patches/69_hide_stuff.patch; then
    log "Patch rejected. Reverting patch..."
    mv -f fs/proc/task_mmu.c.orig fs/proc/task_mmu.c
    mv -f fs/proc/base.c.orig fs/proc/base.c
fi

# Apply extra tmpfs config
log "Applying extra tmpfs config..."
config --file $DEFCONFIG_FILE --enable CONFIG_TMPFS_XATTR
config --file $DEFCONFIG_FILE --enable CONFIG_TMPFS_POSIX_ACL

## KernelSU setup
# Remove KernelSU in driver in kernel source if exist
cd "$workdir/common" || exit 1

if [[ $KSU != "None" ]]; then
    for ksupath in "drivers/staging/kernelsu" "drivers/kernelsu" "KernelSU"; do
        if [[ -d $ksupath ]]; then
            log "KernelSU driver found in $ksupath, Removing..."
            parent_dir="${ksupath%/*}"

            [[ -f "$parent_dir/Kconfig" ]] && sed -i '/kernelsu/d' "$parent_dir/Kconfig"
            [[ -f "$parent_dir/Makefile" ]] && sed -i '/kernelsu/d' "$parent_dir/Makefile"

            rm -rf $ksupath
        fi
    done
fi

# Apply config for KernelSU manual hook (Requires supported KernelSU)
if [[ $USE_KSU_MANUAL_HOOK == "true" ]]; then
    config --file $DEFCONFIG_FILE --enable CONFIG_KSU_MANUAL_HOOK
    config --file $DEFCONFIG_FILE --disable CONFIG_KSU_WITH_KPROBE
    config --file $DEFCONFIG_FILE --disable CONFIG_KSU_SUSFS_SUS_SU

    if [[ $KSU == "Official" ]]; then
        error "Official KernelSU has dropped manual hook support. Exiting..."
    fi

    if grep -q "CONFIG_KSU" fs/exec.c; then
        log "Manual hook code already present in fs/exec.c. Skipping patch..."
    else
        log "Applying manual-hook patch to the kernel source..."
        if ! patch -p1 <"$workdir/wildplus_patches/hooks/new_hooks.patch"; then
            log "❌ Patch rejected. Reverting changes..."
            for file in fs/exec.c fs/open.c fs/read_write.c fs/stat.c \
                drivers/input/input.c drivers/tty/pty.c; do
                [[ -f "$file.orig" ]] && mv -f "$file.orig" "$file"
            done
            log "Using KPROBE HOOK instead..."
            config --file $DEFCONFIG_FILE --disable CONFIG_KSU_MANUAL_HOOK
            config --file $DEFCONFIG_FILE --enable CONFIG_KSU_WITH_KPROBE
            config --file $DEFCONFIG_FILE --enable CONFIG_KSU_SUSFS_SUS_SU

        fi
    fi
fi

# Install KernelSU driver
cd $workdir
if [[ $KSU != "None" ]]; then
    log "Installing KernelSU..."

    case "$KSU" in
    "Official") install_ksu tiann/KernelSU ;;
    "Rissu") install_ksu rsuntk/KernelSU $([[ $USE_KSU_SUSFS == true ]] && echo susfs-v1.5.5 || echo main) ;;
    "Next") install_ksu rifsxd/KernelSU-Next $([[ $USE_KSU_SUSFS == true ]] && echo next-susfs || echo next) ;;
    "xx's") install_ksu backslashxx/KernelSU $([[ $USE_KSU_SUSFS == true ]] && echo 12069+sus155 || echo magic) ;;
    *) error "Invalid KSU value: $KSU" ;;
    esac
fi

# SUSFS for KSU setup
if [[ $USE_KSU_SUSFS == "true" && -z $KSU ]]; then
    error "You can't use SuSFS without KernelSU!"
elif [[ -n $KSU && $USE_KSU_SUSFS == "true" ]]; then
    log "Cloning susfs4ksu..."
    git clone -q --depth=1 https://gitlab.com/simonpunk/susfs4ksu -b gki-$GKI_VERSION $workdir/susfs4ksu
    SUSFS_PATCHES="$workdir/susfs4ksu/kernel_patches"

    # Copy susfs files (Kernel Side)
    log "Copying susfs files..."
    cd $workdir/common
    cp $SUSFS_PATCHES/include/linux/* ./include/linux/
    cp $SUSFS_PATCHES/fs/* ./fs/
    SUSFS_VERSION=$(grep -E '^#define SUSFS_VERSION' ./include/linux/susfs.h | cut -d' ' -f3 | sed 's/"//g')

    # Apply kernel-side susfs patch
    log "Patching kernel-side susfs patch"
    if ! patch -p1 <"$SUSFS_PATCHES/50_add_susfs_in_gki-$GKI_VERSION.patch" 2>&1 | tee ./patch.log; then
        grep -q "*FAILED*fs/devpts/inode.c*" ./patch.log || error "❌ Patch failed (not due to legacy KSU manual hook)."
        log "⚠️ Kernel susfs patch failed on fs/devpts/inode.c."
        if [[ $USE_KSU_MANUAL_HOOK != "true" ]]; then
            # WIP. this will be uncommented later... or never...
            # patch -p1 /path/to/devpts_fix.patch || error "Fix patch failed."
            error "❌ Your kernel-source is using manual hook but you dont enable it, sus_su would not work. exiting..."
        fi

        log "⏩ Using manual hook, skipping patching."
        mv -f fs/devpts/inode.c.orig fs/devpts/inode.c
    fi
    rm -f ./patch.log

    # Apply patch to KernelSU (KSU Side)
    if [[ $KSU == "Official" ]]; then
        cd ../KernelSU
        log "Applying KernelSU-side susfs patch"
        patch -p1 <$SUSFS_PATCHES/KernelSU/10_enable_susfs_for_ksu.patch || error "KernelSU-side susfs patch failed."
    fi
fi

cd $workdir/common
# Remove unnecessary code from scripts/setlocalversion
if grep -q '[-]dirty' scripts/setlocalversion; then
    sed -i 's/-dirty//' scripts/setlocalversion
fi
if grep -q 'echo "+"' scripts/setlocalversion; then
    sed -i 's/echo "+"/# echo "+"/g' scripts/setlocalversion
fi

# Set localversion to the KERNEL_NAME variable
config --file $DEFCONFIG_FILE \
    --set-str LOCALVERSION "-$KERNEL_NAME"

text=$(
    cat <<EOF
*~~~ $KERNEL_NAME CI ~~~*
*GKI Version*: \`$GKI_VERSION\`
*Kernel Version*: \`$KERNEL_VERSION\`
*Build Status*: \`$STATUS\`
*Date*: \`$KBUILD_BUILD_TIMESTAMP\`
*KSU Variant*: \`$VARIANT\`$([[ $KSU != "None" ]] && echo "
*KSU Version*: \`$KSU_VERSION\`")
*SUSFS*: \`$([[ $USE_KSU_SUSFS == "true" ]] && echo "$SUSFS_VERSION" || echo "none")\`
*Compiler*: \`$COMPILER_STRING\`
EOF
)

send_msg "$text"

# Define make args
MAKE_ARGS="
-j$(nproc --all)
ARCH=arm64
LLVM=1
LLVM_IAS=1
O=$workdir/out
CROSS_COMPILE=aarch64-linux-gnu-
CROSS_COMPILE_COMPAT=arm-linux-gnueabi-
"
KERNEL_IMAGE=$workdir/out/arch/arm64/boot/Image

# Build GKI
cd $workdir/common

build_kernel() {
    log "Building kernel..."
    set -x # Enable debugging

    log "Generating config..."
    make $MAKE_ARGS $KERNEL_DEFCONFIG || error "❌ Generating defconfig from $KERNEL_DEFCONFIG failed!"

    # Merge additional configs
    if [[ -n $DEFCONFIGS ]]; then
        for CONFIG in $DEFCONFIGS; do
            log "Merging $CONFIG into the config file..."
            make $MAKE_ARGS scripts/kconfig/merge_config.sh $CONFIG || error "❌ Config merge failed!"
        done
    fi

    # Ensure valid config
    log "Ensuring config is valid..."
    make $MAKE_ARGS olddefconfig || error "❌ olddefconfig failed!"

    # Upload config file
    if [[ $GENERATE_DEFCONFIG == "true" ]]; then
        log "Uploading defconfig..."
        upload_file $workdir/out/.config
        exit 0
    fi

    # Build the actual kernel
    build_targets="Image"
    [[ $BUILD_BOOTIMG == "true" ]] && build_targets+=" Image.lz4 Image.gz"

    log "Building kernel image(s)..."
    make $MAKE_ARGS $build_targets || error "❌ Kernel build failed!"

    # Build kernel modules
    if [[ $BUILD_LKMS == "true" ]]; then
        log "Building kernel modules..."
        make $MAKE_ARGS modules
    fi

    set +x # Disable debugging after the function
}

set -o pipefail # Ensure errors in pipelines cause failure
build_kernel
exit_code=${PIPESTATUS[0]} # Capture the exit code of build_kernel

if [[ $exit_code -ne 0 ]]; then
    exit $exit_code # Exit only if an error occurred
fi

if [[ ! -f $KERNEL_IMAGE ]]; then
    send_msg "❌ Build failed!"
    # Upload log and config for debugging
    upload_file "$workdir/out/.config"
    error "Kernel Image does not exist at $KERNEL_IMAGE"
fi

## Post-compiling stuff
cd $workdir

mkdir -p artifacts || error "Creating artifacts directory failed"

# Clone AnyKernel
log "Cloning anykernel from $(basename "$ANYKERNEL_REPO") | $ANYKERNEL_BRANCH"
git clone -q --depth=1 $ANYKERNEL_REPO -b $ANYKERNEL_BRANCH anykernel

# Set kernel string in anykernel
sed -i "s/kernel.string=.*/kernel.string=${KERNEL_NAME} ${KERNEL_VERSION} (${BUILD_DATE}) ${VARIANT}/g" $workdir/anykernel/anykernel.sh
if [[ $VARIANT == "none" ]]; then
    OLD=$(grep 'kernel.string' $workdir/anykernel/anykernel.sh | cut -f2 -d '=')
    NEW=$(
        echo "$OLD" |
            sed "s/none//g"
    )
    sed -i "s/kernel.string=.*/kernel.string=${NEW}/g" anykernel/anykernel.sh
fi

# Zipping
cd anykernel
log "Zipping anykernel..."
cp $KERNEL_IMAGE .
zip -r9 $workdir/artifacts/$ZIP_NAME ./*
cd ..

if [[ $BUILD_BOOTIMG == "true" ]]; then
    # Clone tools
    AOSP_MIRROR=https://android.googlesource.com
    BRANCH=main-kernel-build-2024
    log "Cloning build tools into $(pwd)/build-tools"
    git clone -q --depth=1 $AOSP_MIRROR/kernel/prebuilts/build-tools -b $BRANCH build-tools
    log "Cloning mkbootimg into $(pwd)/mkbootimg..."
    git clone -q --depth=1 $AOSP_MIRROR/platform/system/tools/mkbootimg -b $BRANCH mkbootimg

    # Variables
    KERNEL_IMAGES=$(echo $workdir/out/arch/arm64/boot/Image*)
    AVBTOOL=$workdir/build-tools/linux-x86/bin/avbtool
    MKBOOTIMG=$workdir/mkbootimg/mkbootimg.py
    UNPACK_BOOTIMG=$workdir/mkbootimg/unpack_bootimg.py
    BOOT_SIGN_KEY_PATH=$workdir/key/verifiedboot.pem
    BOOTIMG_NAME="${ZIP_NAME%.zip}-boot-dummy.img"
    # Note: dummy is placeholder that would be replace the Image format later

    # Function
    generate_bootimg() {
        local kernel="$1"
        local output="$2"

        # Create boot image
        log "Creating $output"
        $MKBOOTIMG --header_version 4 \
            --kernel "$kernel" \
            --output "$output" \
            --ramdisk out/ramdisk \
            --os_version 12.0.0 \
            --os_patch_level $(date +"%Y-%m")

        sleep 1

        # Sign the boot image
        log "Signing $output"
        $AVBTOOL add_hash_footer \
            --partition_name boot \
            --partition_size $((64 * 1024 * 1024)) \
            --image "$output" \
            --algorithm SHA256_RSA2048 \
            --key $BOOT_SIGN_KEY_PATH
    }

    # Prepare boot image
    mkdir -p bootimg && cd bootimg
    cp $KERNEL_IMAGES .

    # Download and unpack GKI
    log "Downloading GKI..."
    wget -qO gki.zip https://dl.google.com/android/gki/gki-certified-boot-android12-5.10-2023-01_r1.zip
    log "Unpacking GKI..."
    unzip -q gki.zip && rm gki.zip
    $UNPACK_BOOTIMG --boot_img=./boot-5.10.img
    rm ./boot-5.10.img

    # Generate and sign boot images in multiple formats (raw, lz4, gz)
    for format in raw lz4 gz; do
        # Initialize kernel variable
        kernel="./Image"
        [ "$format" != "raw" ] && kernel+=".$format"

        log "Using kernel: $kernel"
        output="${BOOTIMG_NAME/dummy/$format}"
        generate_bootimg "$kernel" "$output"

        log "Moving $output to artifacts directory"
        mv -f "$output" $workdir/artifacts/ || error "Move $output to artifacts failed."
    done
    cd $workdir
fi

if [[ $BUILD_LKMS == "true" ]]; then
    mkdir lkm && cd lkm
    find "$workdir/out" -type f -name "*.ko" -exec cp {} . \; || true
    [[ -n "$(ls -A ./*.ko 2>/dev/null)" ]] && zip -r9 "$workdir/artifacts/lkm-$KERNEL_VERSION.zip" ./*.ko || log "No LKMs found."
    cd ..
fi

echo "BASE_NAME=$KERNEL_NAME-$VARIANT" >>$GITHUB_ENV

if [[ $LAST_BUILD == "true" ]]; then
    (
        echo "KERNEL_VERSION=$KERNEL_VERSION"
        echo "SUSFS_VERSION=$(curl -s https://gitlab.com/simonpunk/susfs4ksu/-/raw/gki-${GKI_VERSION}/kernel_patches/include/linux/susfs.h | grep -E '^#define SUSFS_VERSION' | cut -d' ' -f3 | sed 's/"//g')"
        echo "KSU_OFC_VERSION=$(gh api repos/tiann/KernelSU/tags --jq '.[0].name')"
        echo "KSU_NEXT_VERSION=$(gh api repos/rifsxd/KernelSU-Next/tags --jq '.[0].name')"
        echo "RELEASE_NAME=$KERNEL_NAME-$BUILD_DATE"
        echo "KERNEL_NAME=$KERNEL_NAME"
        echo "GKI_VERSION=$GKI_VERSION"
        echo "RELEASE_REPO=$(echo "$GKI_RELEASES_REPO" | sed 's|https://github.com/||')"
        cd $workdir
        echo "BUILDER_REPO=$(git remote get-url origin)"
        echo "BUILDER_LAST_COMMIT=$(git remote get-url origin)/commit/$(git log -1 --format="%H")"
        echo "BUILDER_CURRENT_BRANCH=$(git branch --show-current)"
        cd $workdir/common
        echo "KERNEL_REPO=$(git remote get-url origin)"
        echo "KERNEL_LAST_COMMIT=$(git remote get-url origin)/commit/$(git log -1 --format="%H")"
    ) >>$workdir/artifacts/info.txt
fi

if [[ $STATUS == "BETA" ]]; then
    send_msg "✅ Build Succeeded"
    send_msg "📦 [Download]($NIGHTLY_LINK)"
fi

exit 0
