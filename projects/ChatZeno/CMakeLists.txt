cmake_minimum_required(VERSION 3.16)
set(CMAKE_CXX_STANDARD 17)

file(GLOB_RECURSE CHATZENO_SOURCE_FILES CONFIGURE_DEPENDS *.h *.cpp)

target_sources(zeno PRIVATE ${CHATZENO_SOURCE_FILES})
