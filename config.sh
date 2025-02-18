# Kernel name
export KERNEL_NAME="QuartiX"

# GKI Version
export GKI_VERSION="android15-6.6"

# Build variables
export TZ="Asia/Makassar"
export KBUILD_BUILD_USER="eraselk"
export KBUILD_BUILD_HOST="$KERNEL_NAME"
export KBUILD_BUILD_TIMESTAMP=$(date)

# AnyKernel variables
export ANYKERNEL_REPO="https://github.com/hazepynut/anykernel"
export ANYKERNEL_BRANCH="gki-android15-6.6"

# Kernel
export KERNEL_REPO="https://android.googlesource.com/kernel/common"
export KERNEL_BRANCH="android15-6.6-lts"
export KERNEL_DEFCONFIG="gki_defconfig"
# Defconfigs would be merge in the compiling processes
DEFCONFIGS= # Leave this empty if you don't need to merge any configs


# Releases repository
export GKI_RELEASES_REPO="https://github.com/hazepynut/quartix-releases"

# AOSP Clang
export USE_AOSP_CLANG="false"
export AOSP_CLANG_VERSION="r547379"

# Custom clang
export USE_CUSTOM_CLANG="true"
export CUSTOM_CLANG_SOURCE="https://gitlab.com/rvproject27/RvClang"
export CUSTOM_CLANG_BRANCH="release/19.x"

# Zip name
export BUILD_DATE=$(date -d "$KBUILD_BUILD_TIMESTAMP" +"%y%m%d%H%M")
export ZIP_NAME="$KERNEL_NAME-KVER-VARIANT-$BUILD_DATE.zip"
# Note: KVER and VARIANT are dummy.
# it means they will be changed in the build.sh script.
