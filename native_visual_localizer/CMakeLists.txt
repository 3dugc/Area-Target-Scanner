cmake_minimum_required(VERSION 3.20)
project(visual_localizer LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_VISIBILITY_PRESET hidden)
set(CMAKE_VISIBILITY_INLINES_HIDDEN ON)

find_package(OpenCV REQUIRED COMPONENTS core features2d calib3d)

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
endif()

# Android: NDK cross-compilation
if(CMAKE_SYSTEM_NAME STREQUAL "Android")
    set(CMAKE_ANDROID_STL_TYPE c++_shared)
    set_target_properties(visual_localizer PROPERTIES
        POSITION_INDEPENDENT_CODE ON
    )
endif()
