#!/usr/bin/env bash
set -ex

ret=0
if [[ -z $CHAT_ID ]]; then
    echo "error: please fill CHAT_ID secret!"
    ((ret++))
fi

if [[ -z $TOKEN ]]; then
    echo "error: please fill TOKEN secret!"
    ((ret++))
fi

if [[ -z $GH_TOKEN ]]; then
    echo "error: please fill GH_TOKEN secret!"
    ((ret++))
fi

[[ $ret -gt 0 ]] && exit $ret

mkdir -p android-kernel && cd android-kernel

WORKDIR=$(pwd)
BUILDERDIR=$WORKDIR/..
source $BUILDERDIR/config.sh

# ------------------
# Telegram functions
# ------------------

upload_file() {
    local file="$1"

    if [[ -f $file ]]; then
        chmod 777 "$file"
    else
        echo "[ERROR] file $file doesn't exist"
        exit 1
    fi

    curl -s -F document=@"$file" "https://api.telegram.org/bot$TOKEN/sendDocument" \
        -F chat_id="$CHAT_ID" \
        -F "disable_web_page_preview=true" \
        -F "parse_mode=markdown" \
        -o /dev/null
}

send_msg() {
    local msg="$1"
    curl -s -X POST "https://api.telegram.org/bot$TOKEN/sendMessage" \
        -d chat_id="$CHAT_ID" \
        -d "disable_web_page_preview=true" \
        -d "parse_mode=markdown" \
        -d text="$msg" \
        -o /dev/null
}

# ---------------
# 	MAIN
# ---------------

# Kernel variant
if [[ $USE_KSU == "yes" ]]; then
    # ksu
    VARIANT="KSU"
elif [[ $USE_KSU_NEXT == "yes" ]]; then
    # ksu next
    VARIANT="KSUN"
else
    # vanilla
    VARIANT="none"
fi

# Clone the kernel source
git clone --depth=1 $KERNEL_REPO -b $KERNEL_BRANCH $WORKDIR/common

# Extract kernel version
cd $WORKDIR/common
KERNEL_VERSION=$(make kernelversion)
cd $WORKDIR

# Download Toolchains
mkdir $WORKDIR/clang
if [[ $USE_AOSP_CLANG == "true" ]]; then
    wget -qO $WORKDIR/clang.tar.gz https://android.googlesource.com/platform/prebuilts/clang/host/linux-x86/+archive/refs/heads/main/clang-$AOSP_CLANG_VERSION.tar.gz
    tar -xf $WORKDIR/clang.tar.gz -C $WORKDIR/clang/
    rm -f $WORKDIR/clang.tar.gz
elif [[ $USE_CUSTOM_CLANG == "true" ]]; then
    if [[ $CUSTOM_CLANG_SOURCE =~ git ]]; then
        if [[ $CUSTOM_CLANG_SOURCE == *'.tar.'* ]]; then
            wget -q $CUSTOM_CLANG_SOURCE
            tar -C $WORKDIR/clang/ -xf $WORKDIR/*.tar.*
            rm -f $WORKDIR/*.tar.*
        else
            rm -rf $WORKDIR/clang
            git clone $CUSTOM_CLANG_SOURCE -b $CUSTOM_CLANG_BRANCH $WORKDIR/clang --depth=1
        fi
    else
        echo "error: Clang source other than git is not supported."
        exit 1
    fi
elif [[ $USE_AOSP_CLANG == "true" ]] && [[ $USE_CUSTOM_CLANG == "true" ]]; then
    echo "error: You have to choose one, AOSP Clang or Custom Clang!"
    exit 1
else
    echo "stfu."
    exit 1
fi

# Clone binutils if they don't exist
if ! echo $WORKDIR/clang/bin/* | grep -q 'aarch64-linux-gnu'; then
    git clone --depth=1 https://android.googlesource.com/platform/prebuilts/gas/linux-x86 -b main $WORKDIR/binutils
    export PATH="$WORKDIR/clang/bin:$WORKDIR/binutils:$PATH"
else
    export PATH="$WORKDIR/clang/bin:$PATH"
fi

# Extract clang version
COMPILER_STRING=$(clang -v 2>&1 | head -n 1 | sed 's/(https..*//' | sed 's/ version//')

# KSU or KSU-Next setup
if [[ $USE_KSU_NEXT == "yes" ]]; then
    if [[ $USE_KSU_SUSFS == "yes" ]]; then
        curl -LSs https://raw.githubusercontent.com/rifsxd/KernelSU-Next/refs/heads/next/kernel/setup.sh | bash -s next-susfs
    else
        curl -LSs https://raw.githubusercontent.com/rifsxd/KernelSU-Next/refs/heads/next/kernel/setup.sh | bash -
    fi
    cd $WORKDIR/KernelSU-Next
    KSU_VERSION=$(git describe --abbrev=0 --tags)
elif [[ $USE_KSU == "yes" ]]; then
    curl -LSs "https://raw.githubusercontent.com/tiann/KernelSU/refs/heads/main/kernel/setup.sh" | bash -
    cd $WORKDIR/KernelSU
    KSU_VERSION=$(git describe --abbrev=0 --tags)
elif [[ $USE_KSU_NEXT == "yes" ]] && [[ $USE_KSU == "yes" ]]; then
    echo
    echo "error: You have to choose one, KSU or KSUN!"
    exit 1
fi

cd $WORKDIR

git config --global user.email "kontol@example.com"
git config --global user.name "Your Name"

# SUSFS4KSU setup
if [[ $USE_KSU == "yes" ]] || [[ $USE_KSU_NEXT == "yes" ]] && [[ $USE_KSU_SUSFS == "yes" ]]; then
    git clone --depth=1 https://gitlab.com/simonpunk/susfs4ksu -b gki-$GKI_VERSION $WORKDIR/susfs4ksu
    SUSFS_PATCHES="$WORKDIR/susfs4ksu/kernel_patches"

    if [[ $USE_KSU == "yes" ]]; then
        VARIANT="KSUxSuSFS"
    elif [[ $USE_KSU_NEXT == "yes" ]]; then
        VARIANT="KSUNxSuSFS"
    fi

    # Copy header files (Kernel Side)
    cd $WORKDIR/common
    cp $SUSFS_PATCHES/include/linux/* ./include/linux/
    cp $SUSFS_PATCHES/fs/* ./fs/

    # Apply patch to KernelSU (KSU Side)
    if [[ $USE_KSU == "yes" ]]; then
        cd $WORKDIR/KernelSU
        cp $SUSFS_PATCHES/KernelSU/10_enable_susfs_for_ksu.patch .
        patch -p1 <10_enable_susfs_for_ksu.patch || exit 1
    fi

    # Apply patch to kernel (Kernel Side)
    cd $WORKDIR/common
    cp $SUSFS_PATCHES/50_add_susfs_in_gki-$GKI_VERSION.patch .
    patch -p1 <50_add_susfs_in_gki-$GKI_VERSION.patch || exit 1

    SUSFS_VERSION=$(grep -E '^#define SUSFS_VERSION' ./include/linux/susfs.h | cut -d' ' -f3 | sed 's/"//g')
elif [[ $USE_KSU_SUSFS == "yes" ]] && [[ $USE_KSU != "yes" ]] && [[ $USE_KSU_NEXT != "yes" ]]; then
    echo "error: You can't use SuSFS without KSU enabled!"
    exit 1
fi

# Kernel patches for 6.6
git clone --depth=1 https://github.com/hazepynut/android15-6.6 $WORKDIR/kp
cd $WORKDIR/common
for i in $WORKDIR/kp/*.patch; do
    if ! git am <$i; then
        patch -p1 <$i || {
            echo "failed to apply $i"
            exit 1
        }
        git am --continue
    fi
done

cd $WORKDIR

text=$(
    cat <<EOF
*~~~ $KERNEL_NAME CI ~~~*
*GKI Version*: \`$GKI_VERSION\`
*Kernel Version*: \`$KERNEL_VERSION\`
*Build Status*: \`$STATUS\`
*Date*: \`$KBUILD_BUILD_TIMESTAMP\`
*KSU Variant*: \`$(echo "$VARIANT")\`$(echo "$VARIANT" | grep -qi 'KSU' && echo "
*KSU Version*: \`$KSU_VERSION\`")
*SUSFS*: \`$([[ $USE_KSU_SUSFS == "yes" ]] && echo "$SUSFS_VERSION" || echo "none")\`
*Compiler*: \`$COMPILER_STRING\`
EOF
)

send_msg "$text"

cd $WORKDIR/common
# Build GKI
if [[ $BUILD_KERNEL == "yes" ]]; then
    set +e
    (
        make \
            ARCH=arm64 \
            LLVM=1 \
            LLVM_IAS=1 \
            O=$WORKDIR/out \
            CROSS_COMPILE=aarch64-linux-gnu- \
            CROSS_COMPILE_COMPAT=arm-linux-gnueabi- \
            $KERNEL_DEFCONFIG

        make \
            ARCH=arm64 \
            LLVM=1 \
            LLVM_IAS=1 \
            O=$WORKDIR/out \
            CROSS_COMPILE=aarch64-linux-gnu- \
            CROSS_COMPILE_COMPAT=arm-linux-gnueabi- \
            -j$(nproc --all) \
            Image $([ $STATUS == "STABLE" ] && echo "Image.lz4 Image.gz")
    ) 2>&1 | tee $WORKDIR/build.log
    set -e
elif [[ $GENERATE_DEFCONFIG == "yes" ]]; then
    make \
        ARCH=arm64 \
        LLVM=1 \
        LLVM_IAS=1 \
        O=$WORKDIR/out \
        CROSS_COMPILE=aarch64-linux-gnu- \
        CROSS_COMPILE_COMPAT=arm-linux-gnueabi- \
        $KERNEL_DEFCONFIG

    mv $WORKDIR/out/.config $WORKDIR/config
    ret=$(curl -s bashupload.com -T $WORKDIR/config)
    send_msg "$ret"
    exit 0
fi
cd $WORKDIR

KERNEL_IMAGE="$WORKDIR/out/arch/arm64/boot/Image"
if ! [[ -f $KERNEL_IMAGE ]]; then
    send_msg "❌ Build failed!"
    upload_file "$WORKDIR/build.log"
    exit 1
else
    # Clone AnyKernel
    git clone --depth=1 "$ANYKERNEL_REPO" -b "$ANYKERNEL_BRANCH" $WORKDIR/anykernel

    ZIP_NAME=$(
        echo "$ZIP_NAME" |
            sed "s/KVER/$KERNEL_VERSION/g" |
            if [[ $VARIANT == "none" ]]; then
                sed "s/VARIANT-//g"
            else
                sed "s/VARIANT/$VARIANT/g"
            fi
    )

    sed -i "s/kernel.string=.*/kernel.string=${KERNEL_NAME} ${KERNEL_VERSION} (${BUILD_DATE}) ${VARIANT}/g" $WORKDIR/anykernel/anykernel.sh
    if [[ $VARIANT == "none" ]]; then
        OLD=$(grep 'kernel.string' $WORKDIR/anykernel/anykernel.sh | cut -f2 -d '=')
        NEW=$(
            echo "$OLD" |
                sed "s/none//g"
        )
        sed -i "s/kernel.string=.*/kernel.string=${NEW}/g" $WORKDIR/anykernel/anykernel.sh
    fi

    if [[ $STATUS == "STABLE" ]]; then
        # Clone tools
        AOSP_MIRROR=https://android.googlesource.com
        BRANCH=main-kernel-build-2024
        git clone $AOSP_MIRROR/kernel/prebuilts/build-tools -b $BRANCH --depth=1 $WORKDIR/build-tools
        git clone $AOSP_MIRROR/platform/system/tools/mkbootimg -b $BRANCH --depth=1 $WORKDIR/mkbootimg

        # Variables
        KERNEL_IMAGES=$(echo $WORKDIR/out/arch/arm64/boot/Image*)
        AVBTOOL=$WORKDIR/build-tools/linux-x86/bin/avbtool
        MKBOOTIMG=$WORKDIR/mkbootimg/mkbootimg.py
        UNPACK_BOOTIMG=$WORKDIR/mkbootimg/unpack_bootimg.py
        BOOT_SIGN_KEY_PATH=$BUILDERDIR/key/verifiedboot.pem
        BOOTIMG_NAME="${ZIP_NAME%.zip}-boot-dummy.img"
        # Note: dummy is the Image format

        # Function
        generate_bootimg() {
            local kernel="$1"
            local output="$2"

            # Create boot image
            $MKBOOTIMG --header_version 4 \
                --kernel "$kernel" \
                --output "$output" \
                --ramdisk out/ramdisk \
                --os_version 12.0.0 \
                --os_patch_level $(date +"%Y-%m")

            sleep 1

            # Sign the boot image
            $AVBTOOL add_hash_footer \
                --partition_name boot \
                --partition_size $((64 * 1024 * 1024)) \
                --image "$output" \
                --algorithm SHA256_RSA2048 \
                --key $BOOT_SIGN_KEY_PATH
        }

        # Prepare boot image
        mkdir -p $WORKDIR/bootimg && cd $WORKDIR/bootimg
        cp $KERNEL_IMAGES .

        # Download and unpack GKI
        wget -qO gki.zip https://dl.google.com/android/gki/gki-certified-boot-android12-5.10-2023-01_r1.zip
        unzip -q gki.zip && rm gki.zip
        $UNPACK_BOOTIMG --boot_img="$(pwd)/boot-5.10.img"
        rm "$(pwd)/boot-5.10.img"

        # Generate and sign boot images
        for format in raw lz4 gz; do

            case $format in
            raw)
                kernel="./Image"
                output="${BOOTIMG_NAME/dummy/raw}"
                ;;
            lz4)
                kernel="./Image.lz4"
                output="${BOOTIMG_NAME/dummy/lz4}"
                ;;
            gz)
                kernel="./Image.gz"
                output="${BOOTIMG_NAME/dummy/gz}"
                ;;
            esac

            # Generate and sign
            generate_bootimg "$kernel" "$output"
            mv "$output" "$WORKDIR"
        done
        cd $WORKDIR
    fi

    # Zipping
    cd $WORKDIR/anykernel
    cp $KERNEL_IMAGE .
    zip -r9 $WORKDIR/$ZIP_NAME ./* -x LICENSE
    cd $WORKDIR

    if [[ $STATUS == "STABLE" ]]; then
        ## Upload into GitHub Release
        TAG="$BUILD_DATE"
        RELEASE_MESSAGE="${ZIP_NAME%.zip}"
        URL="$GKI_RELEASES_REPO/releases/$TAG"
        GITHUB_USERNAME=$(echo "$GKI_RELEASES_REPO" | awk -F'https://github.com/' '{print $2}' | awk -F'/' '{print $1}')
        REPO_NAME=$(echo "$GKI_RELEASES_REPO" | awk -F'https://github.com/' '{print $2}' | awk -F'/' '{print $2}')

        # Clone repository
        git clone --depth=1 "https://${GITHUB_USERNAME}:${GH_TOKEN}@github.com/${GITHUB_USERNAME}/${REPO_NAME}.git" "$WORKDIR/rel" || {
            echo "❌ Failed to clone GKI releases repository"
            exit 1
        }

        cd "$WORKDIR/rel" || exit 1

        # Create release
        if ! gh release create "$TAG" -t "$RELEASE_MESSAGE"; then
            echo "❌ Failed to create release $TAG"
            exit 1
        fi

        sleep 2

        # Upload files to release
        for release_file in "$WORKDIR"/*.zip "$WORKDIR"/*.img; do
            if [[ -f $release_file ]]; then
                if ! gh release upload "$TAG" "$release_file"; then
                    echo "❌ Failed to upload $release_file"
                    exit 1
                fi
                sleep 2
            fi
        done
    fi
    if [[ $STATUS == "STABLE" ]]; then
        send_msg "📦 [$RELEASE_MESSAGE]($URL)"
    else
        mv $WORKDIR/$ZIP_NAME $BUILDERDIR
        send_msg "✅ Build Succedded"
    fi
    exit 0
fi
