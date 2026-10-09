cmake_minimum_required(VERSION 3.20)
project(visual_localizer LANGUAGES C CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_VISIBILITY_PRESET hidden)
set(CMAKE_VISIBILITY_INLINES_HIDDEN ON)

find_package(OpenCV REQUIRED COMPONENTS core imgproc)
set(OPENCV_REQUIRED_MAJOR "5" CACHE STRING "Require an OpenCV major version (use 4 for the baseline)")
if(OPENCV_REQUIRED_MAJOR AND NOT OpenCV_VERSION_MAJOR STREQUAL OPENCV_REQUIRED_MAJOR)
    message(FATAL_ERROR "Requested OpenCV ${OPENCV_REQUIRED_MAJOR}.x, found ${OpenCV_VERSION}")
endif()
find_package(SQLite3 REQUIRED)
if(OpenCV_VERSION_MAJOR EQUAL 5)
    find_package(OpenCV REQUIRED COMPONENTS core imgproc features geometry xfeatures2d)
elseif(OpenCV_VERSION_MAJOR EQUAL 4)
    find_package(OpenCV REQUIRED COMPONENTS core imgproc features2d calib3d)
else()
    message(FATAL_ERROR "Supported OpenCV versions are 4.x and 5.x, found ${OpenCV_VERSION}")
endif()

add_library(visual_localizer SHARED
    src/pose_contract.cpp
    src/visual_localizer.cpp
    src/visual_localizer_impl.cpp
    src/frame_contract.cpp
    src/map_loader.cpp
    src/runtime_c_api.cpp
    src/localization_session.cpp
    src/runtime_session_c_api.cpp
    src/gray_quality.cpp
    src/rigid_consensus.cpp
    src/keyframe_selection.cpp
)

target_include_directories(visual_localizer PUBLIC include)
target_link_libraries(visual_localizer PRIVATE ${OpenCV_LIBS} SQLite::SQLite3)
# One physical implementation and library for legacy and versioned bridges.
add_library(area_target_runtime ALIAS visual_localizer)

include(CTest)

if(BUILD_TESTING AND NOT CMAKE_SYSTEM_NAME STREQUAL "iOS")
    add_executable(hamming_popcount_equivalence_test
        tests/hamming_popcount_equivalence_test.cpp
        src/visual_localizer_impl.cpp
        src/pose_contract.cpp
    )
    target_include_directories(hamming_popcount_equivalence_test PRIVATE src include)
    target_link_libraries(hamming_popcount_equivalence_test PRIVATE ${OpenCV_LIBS})
    add_test(NAME hamming_popcount_equivalence COMMAND hamming_popcount_equivalence_test)
    add_executable(final_geometry_test tests/final_geometry_test.cpp src/visual_localizer_impl.cpp src/pose_contract.cpp)
    target_include_directories(final_geometry_test PRIVATE src include)
    target_link_libraries(final_geometry_test PRIVATE ${OpenCV_LIBS})
    add_test(NAME final_geometry_orb COMMAND final_geometry_test orb)
    add_test(NAME final_geometry_akaze COMMAND final_geometry_test akaze)
    add_test(NAME final_geometry_checks COMMAND final_geometry_test checks)
    add_executable(recovery_mode_test tests/recovery_mode_test.cpp)
    target_include_directories(recovery_mode_test PRIVATE include)
    target_link_libraries(recovery_mode_test PRIVATE ${OpenCV_LIBS} ${CMAKE_DL_LIBS})
    add_test(NAME recovery_mode COMMAND recovery_mode_test $<TARGET_FILE:visual_localizer>)
    add_executable(recovery_stub_test tests/recovery_stub_test.c src/visual_localizer_stub.c)
    target_include_directories(recovery_stub_test PRIVATE include)
    add_test(NAME recovery_stub COMMAND recovery_stub_test)
    add_executable(joint_pool_test tests/joint_pool_test.cpp)
    target_include_directories(joint_pool_test PRIVATE src)
    target_link_libraries(joint_pool_test PRIVATE ${OpenCV_LIBS})
    add_test(NAME joint_pool COMMAND joint_pool_test)
    add_executable(joint_pool_state_test tests/joint_pool_state_test.cpp src/visual_localizer_impl.cpp src/pose_contract.cpp)
    target_include_directories(joint_pool_state_test PRIVATE src include)
    target_link_libraries(joint_pool_state_test PRIVATE ${OpenCV_LIBS})
    add_test(NAME joint_pool_state COMMAND joint_pool_state_test)
    add_executable(scaled_fallback_state_test tests/scaled_fallback_state_test.cpp src/visual_localizer_impl.cpp src/pose_contract.cpp)
    target_include_directories(scaled_fallback_state_test PRIVATE include src)
    target_link_libraries(scaled_fallback_state_test PRIVATE ${OpenCV_LIBS})
    add_test(NAME scaled_fallback_state COMMAND scaled_fallback_state_test)
    add_executable(scaled_fallback_contract_test tests/scaled_fallback_contract_test.cpp)
    target_include_directories(scaled_fallback_contract_test PRIVATE include)
    target_link_libraries(scaled_fallback_contract_test PRIVATE ${OpenCV_LIBS} ${CMAKE_DL_LIBS})
    foreach(mode orb1600 akaze1600 portrait1600 gate_orb gate_akaze rounded_orb rounded_akaze rounded_clean_orb rounded_clean_akaze lost1600)
        add_test(NAME scaled_fallback_${mode} COMMAND scaled_fallback_contract_test ${mode} $<TARGET_FILE:visual_localizer> 1)
    endforeach()
    foreach(test runtime_session runtime_abi runtime_quality runtime_session_delivery runtime_policy)
        add_executable(${test}_test tests/${test}_test.cpp)
        target_link_libraries(${test}_test PRIVATE visual_localizer ${CMAKE_DL_LIBS})
        add_test(NAME ${test} COMMAND ${test}_test)
    endforeach()
    add_executable(runtime_c_header_test tests/runtime_c_header_test.c)
    target_link_libraries(runtime_c_header_test PRIVATE visual_localizer)
    add_test(NAME runtime_c_header COMMAND runtime_c_header_test)
    add_executable(runtime_frame_contract_test tests/runtime_frame_contract_test.cpp src/frame_contract.cpp)
    target_include_directories(runtime_frame_contract_test PRIVATE include src)
    add_test(NAME runtime_frame_contract COMMAND runtime_frame_contract_test)
    set(ATC_FIXTURE_DIR "" CACHE PATH "Synthetic production SQLite/native fixture directory")
    if(ATC_FIXTURE_DIR)
        foreach(test runtime_map_loader runtime_raw)
            add_executable(${test}_test tests/${test}_test.cpp)
            target_link_libraries(${test}_test PRIVATE visual_localizer SQLite::SQLite3 ${OpenCV_LIBS})
            add_test(NAME ${test} COMMAND ${test}_test "${ATC_FIXTURE_DIR}")
        endforeach()
    endif()
    add_executable(visual_localizer_pose_contract_test
        tests/pose_contract_test.cpp
        src/pose_contract.cpp
    )
    target_include_directories(visual_localizer_pose_contract_test PRIVATE src)
    target_link_libraries(visual_localizer_pose_contract_test PRIVATE ${OpenCV_LIBS})
    add_test(NAME visual_localizer_pose_contract_test
             COMMAND visual_localizer_pose_contract_test)
    add_executable(visual_localizer_localization_contract_test
        tests/localization_contract_test.cpp
    )
    target_link_libraries(visual_localizer_localization_contract_test
        PRIVATE visual_localizer ${OpenCV_LIBS})
    foreach(mode orb akaze invalid low_orb akaze_rotation global_recovery akaze_continuous akaze_diagnostics)
        add_test(NAME visual_localizer_${mode}_contract_test
                 COMMAND visual_localizer_localization_contract_test ${mode})
    endforeach()
endif()

# --- Platform-specific configuration ---

# iOS: build as framework (static linked into Unity)
if(CMAKE_SYSTEM_NAME STREQUAL "iOS")
    set_target_properties(visual_localizer PROPERTIES
        FRAMEWORK TRUE
        MACOSX_FRAMEWORK_IDENTIFIER com.areatarget.visuallocalizer
    )
endif()

# macOS: universal binary (x86_64 + arm64)
if(CMAKE_SYSTEM_NAME STREQUAL "Darwin" AND NOT CMAKE_SYSTEM_NAME STREQUAL "iOS")
    set(CMAKE_OSX_ARCHITECTURES "x86_64;arm64" CACHE STRING "Build universal binary")
    set_target_properties(visual_localizer PROPERTIES
        INSTALL_RPATH "@loader_path"
    )
    # Static OpenCV still marks its C++ APIs as public on Apple platforms.
    # Keep those private so another plugin can use a different OpenCV version.
    set(VL_SYMBOL_MANIFEST "${CMAKE_CURRENT_SOURCE_DIR}/../tools/phase0/required_combined_native_symbols.txt")
    set_property(DIRECTORY APPEND PROPERTY CMAKE_CONFIGURE_DEPENDS "${VL_SYMBOL_MANIFEST}")
    file(STRINGS "${VL_SYMBOL_MANIFEST}" VL_EXPORTED_SYMBOLS)
    list(TRANSFORM VL_EXPORTED_SYMBOLS PREPEND "_")
    list(JOIN VL_EXPORTED_SYMBOLS "\n" VL_EXPORT_CONTENT)
    set(VL_EXPORT_LIST "${CMAKE_CURRENT_BINARY_DIR}/exports_macos.txt")
    file(GENERATE OUTPUT "${VL_EXPORT_LIST}" CONTENT "${VL_EXPORT_CONTENT}\n")
    target_link_options(visual_localizer PRIVATE "LINKER:-exported_symbols_list,${VL_EXPORT_LIST}")
    set_property(TARGET visual_localizer APPEND PROPERTY LINK_DEPENDS "${VL_EXPORT_LIST}")
endif()

# Android: NDK cross-compilation
if(CMAKE_SYSTEM_NAME STREQUAL "Android")
    set(CMAKE_ANDROID_STL_TYPE c++_shared)
    set_target_properties(visual_localizer PROPERTIES
        POSITION_INDEPENDENT_CODE ON
    )
endif()
