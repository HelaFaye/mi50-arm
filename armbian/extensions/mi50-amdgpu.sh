# Armbian build extension: enable amdgpu + KFD (ROCm) for an MI50 on rockchip64.
#
# Install (from your armbian/build checkout):
#   mkdir -p userpatches/extensions
#   cp /path/to/mi50-arm/armbian/extensions/mi50-amdgpu.sh userpatches/extensions/
#   # the coherency patch goes in the family's patch dir for your kernel version,
#   # e.g. edge = 7.3, current = 6.18 (see config/sources/families/include/rockchip64_common.inc):
#   mkdir -p userpatches/kernel/archive/rockchip64-7.3
#   cp /path/to/mi50-arm/patches/0001-*.patch userpatches/kernel/archive/rockchip64-7.3/
#   ./compile.sh kernel BOARD=orangepi5plus BRANCH=edge ENABLE_EXTENSIONS=mi50-amdgpu
#
# Stock Armbian rockchip64 kernels do not build amdgpu at all, so this is required.

function custom_kernel_config__mi50_amdgpu() {
	opts_m+=("DRM_AMDGPU")
	opts_y+=("DRM_AMDGPU_USERPTR" "HSA_AMD")
	# Optional HMM-based SVM (HIP managed memory). Armbian leaves memory hotplug off,
	# so its ZONE_DEVICE/DEVICE_PRIVATE dependencies must be enabled explicitly.
	opts_y+=("MEMORY_HOTPLUG" "MEMORY_HOTREMOVE" "ZONE_DEVICE" "DEVICE_PRIVATE" "HSA_AMD_SVM")
	# Not needed for compute; keeps the module smaller.
	opts_n+=("DRM_AMDGPU_SI" "DRM_AMDGPU_CIK")
}

function extension_prepare_config__mi50_amdgpu_firmware() {
	# amdgpu needs amdgpu/vega20_*.bin at probe time.
	display_alert "mi50-amdgpu" "full firmware package for vega20 blobs" "info"
	declare -g BOARD_FIRMWARE_INSTALL="-full"
}
