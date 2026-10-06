cmake_minimum_required(VERSION 3.20)
project(visual_localizer LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_VISIBILITY_PRESET hidden)
set(CMAKE_VISIBILITY_INLINES_HIDDEN ON)

find_package(OpenCV REQUIRED COMPONENTS core imgproc)
set(OPENCV_REQUIRED_MAJOR "5" CACHE STRING "Require an OpenCV major version (use 4 for the baseline)")
if(OPENCV_REQUIRED_MAJOR AND NOT OpenCV_VERSION_MAJOR STREQUAL OPENCV_REQUIRED_MAJOR)
    message(FATAL_ERROR "Requested OpenCV ${OPENCV_REQUIRED_MAJOR}.x, found ${OpenCV_VERSION}")
endif()
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
)

target_include_directories(visual_localizer PUBLIC include)
target_link_libraries(visual_localizer PRIVATE ${OpenCV_LIBS})

include(CTest)

if(BUILD_TESTING AND NOT CMAKE_SYSTEM_NAME STREQUAL "iOS")
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
    foreach(mode orb akaze invalid)
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
    set(VL_SYMBOL_MANIFEST "${CMAKE_CURRENT_SOURCE_DIR}/../tools/phase0/required_native_symbols.txt")
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
