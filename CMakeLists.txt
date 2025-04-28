# SPDX-FileCopyrightText: 2024 Klarälvdalens Datakonsult AB, a KDAB Group company <info@kdab.com>
# SPDX-FileContributor: Leon Matthes <leon.matthes@kdab.com>
#
# SPDX-License-Identifier: MIT OR Apache-2.0

cmake_minimum_required(VERSION 3.22)
project(CxxQt
    VERSION 0.7.2
    LANGUAGES NONE
    HOMEPAGE_URL "https://github.com/kdab/cxx-qt/"
)

# Include without installing
list(APPEND CMAKE_MODULE_PATH ${CMAKE_CURRENT_SOURCE_DIR}/cmake)
include(CxxQt)

if (NOT PROJECT_IS_TOP_LEVEL)
  return()
endif()

# Installation

include(GNUInstallDirs)

# Generate the Config file
include(CMakePackageConfigHelpers)

configure_package_config_file(
  cmake/CxxQtConfig.cmake.in CxxQtConfig.cmake
  INSTALL_DESTINATION
  "${CMAKE_INSTALL_FULL_LIBDIR}/cmake/CxxQt"
  )

install(
  FILES
  "${CMAKE_CURRENT_BINARY_DIR}/CxxQtConfig.cmake"
  DESTINATION
  "${CMAKE_INSTALL_FULL_LIBDIR}/cmake/CxxQt"
  )

# These CMake scripts are needed both for the install and as a subdirectory
install(
  FILES
  cmake/CxxQt.cmake
  DESTINATION
  "${CMAKE_INSTALL_FULL_DATADIR}/cmake"
  )
