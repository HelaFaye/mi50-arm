cmake_minimum_required(VERSION 3.20)
project(mi50_gfx906_experiments LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

find_path(LIBDRM_INCLUDE_DIR NAMES xf86drm.h PATH_SUFFIXES libdrm REQUIRED)
find_path(LIBDRM_UAPI_INCLUDE_DIR NAMES drm.h PATH_SUFFIXES libdrm REQUIRED)
find_library(DRM_LIBRARY NAMES drm REQUIRED)
find_library(DRM_AMDGPU_LIBRARY NAMES drm_amdgpu REQUIRED)
find_package(Threads REQUIRED)

add_library(hsa_drm_shim SHARED hsa_drm_shim.cpp)
target_include_directories(hsa_drm_shim PRIVATE "${LIBDRM_INCLUDE_DIR}" "${LIBDRM_UAPI_INCLUDE_DIR}")
target_link_libraries(hsa_drm_shim PRIVATE "${DRM_AMDGPU_LIBRARY}" "${DRM_LIBRARY}" Threads::Threads)
target_compile_options(hsa_drm_shim PRIVATE -Wall -Wextra -Wpedantic)
set_target_properties(hsa_drm_shim PROPERTIES OUTPUT_NAME hsa-drm-shim)

add_executable(dispatch_gfx906 dispatch_gfx906.cpp)
target_include_directories(dispatch_gfx906 PRIVATE "${LIBDRM_INCLUDE_DIR}" "${LIBDRM_UAPI_INCLUDE_DIR}")
target_link_libraries(dispatch_gfx906 PRIVATE "${DRM_AMDGPU_LIBRARY}" "${DRM_LIBRARY}")
target_compile_options(dispatch_gfx906 PRIVATE -Wall -Wextra -Wpedantic)

include(CTest)
if(BUILD_TESTING)
  add_executable(test_gfx906_pm4 ../../tests/test-gfx906-pm4.cpp)
  target_compile_options(test_gfx906_pm4 PRIVATE -Wall -Wextra -Wpedantic)
  add_test(NAME gfx906_pm4_packet_encoding COMMAND test_gfx906_pm4)

  add_executable(test_gfx906_code_object_v5 ../../tests/test-gfx906-code-object-v5.cpp)
  target_compile_options(test_gfx906_code_object_v5 PRIVATE -Wall -Wextra -Wpedantic)
  add_test(NAME gfx906_code_object_v5_implicit_args COMMAND test_gfx906_code_object_v5)
endif()
