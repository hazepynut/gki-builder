# Kernel name
export NAME="QuartiX"

# GKI Version
export GKI_VERSION="android12-5.10"

# Build variables
export TZ="Asia/Makassar"
export KBUILD_BUILD_USER="eraselk"
export KBUILD_BUILD_HOST="$NAME"
export KBUILD_BUILD_TIMESTAMP=$(date)

# AnyKernel variables
export ANYKERNEL_REPO="https://github.com/hazepynut/anykernel"
export ANYKERNEL_BRANCH="gki"

# Kernel
export KERNEL_REPO="https://github.com/ChiseWaguri/android_kernel_xiaomi_marble"
export KERNEL_BRANCH="next-susfs"
export KERNEL_DEFCONFIG="marble_defconfig"

# Releases repository
export GKI_RELEASES_REPO="https://github.com/hazepynut/quartix-releases"

# AOSP Clang
export USE_AOSP_CLANG="false"
export AOSP_CLANG_VERSION="r547379"

# Custom clang
export USE_CUSTOM_CLANG="true"
export CUSTOM_CLANG_SOURCE=$(curl -s https://api.github.com/repos/ZyCromerZ/Clang/releases/latest | grep "browser_download_url" | cut -d '"' -f4)
export CUSTOM_CLANG_BRANCH=""

# Zip name
export BUILD_DATE=$(date -d "$KBUILD_BUILD_TIMESTAMP" +"%y%m%d%H%M")
export ZIP_NAME="$NAME-KVER-VARIANT-$BUILD_DATE.zip"
# Note: KVER and VARIANT are dummy.
# it means they will be changed in the build.sh script.
