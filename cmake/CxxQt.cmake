# SPDX-FileCopyrightText: 2024 Klarälvdalens Datakonsult AB, a KDAB Group company <info@kdab.com>
# SPDX-FileContributor: Andrew Hayzen <andrew.hayzen@kdab.com>
# SPDX-FileContributor: Leon Matthes <leon.matthes@kdab.com>
#
# SPDX-License-Identifier: MIT OR Apache-2.0

option(CXX_QT_SUPPRESS_MSVC_RUNTIME_WARNING "Disable checking that the CMAKE_MSVC_RUNTIME_LIBRARY is set when importing Cargo targets in Debug builds with MSVC.")

find_package(Corrosion QUIET)
if(NOT Corrosion_FOUND)
    include(FetchContent)
    FetchContent_Declare(
        Corrosion
        GIT_REPOSITORY https://github.com/corrosion-rs/corrosion.git
        GIT_TAG v0.5.1
    )

    FetchContent_MakeAvailable(Corrosion)
endif()

function(cxx_qt_import_crate)
  cmake_parse_arguments(IMPORT_CRATE "" "CXX_QT_EXPORT_DIR;QMAKE" "QT_MODULES" ${ARGN})

  corrosion_import_crate(IMPORTED_CRATES __cxx_qt_imported_crates ${IMPORT_CRATE_UNPARSED_ARGUMENTS})

  message(STATUS "CXX-Qt Found crate(s): ${__cxx_qt_imported_crates}")

  if (NOT DEFINED IMPORT_CRATE_CXX_QT_EXPORT_DIR)
    set(IMPORT_CRATE_CXX_QT_EXPORT_DIR "${CMAKE_CURRENT_BINARY_DIR}/cxxqt/")
  endif()
  message(VERBOSE "CXX-Qt EXPORT_DIR: ${IMPORT_CRATE_CXX_QT_EXPORT_DIR}")

  if (NOT DEFINED IMPORT_CRATE_QMAKE)
    get_target_property(QMAKE Qt::qmake IMPORTED_LOCATION)
    if (NOT QMAKE STREQUAL "QMAKE-NOTFOUND")
      set(IMPORT_CRATE_QMAKE "${QMAKE}")
    else()
      message(FATAL_ERROR "cxx_qt_import_crate: QMAKE is not defined and could not be queried from the Qt::qmake target!\nPlease use the QMAKE argument to specify the path to the qmake executable or use find_package(Qt) before calling cxx_qt_import_crate.")
    endif()
  endif()

  if (NOT DEFINED IMPORT_CRATE_QT_MODULES)
    message(FATAL_ERROR "Missing QT_MODULES argument! You must specify at least one Qt module to link to.")
  else()
    message(VERBOSE "CXX_QT_QT_MODULES: ${IMPORT_CRATE_QT_MODULES}")
  endif()

  foreach(CRATE ${__cxx_qt_imported_crates})
    # Join modules by a comma so that we can pass easily via an env variable
    #
    # TODO: can we instead read the module from _qt_config_module_name or
    # _qt_public_module_interface_name of the target, but need to consider
    # private modules too
    list(JOIN IMPORT_CRATE_QT_MODULES "," IMPORT_CRATE_QT_MODULES_STR)

    corrosion_set_env_vars(${CRATE}
      # Tell cxx-qt-build where to export the data
      "CXX_QT_EXPORT_DIR=${IMPORT_CRATE_CXX_QT_EXPORT_DIR}"
      # Tell cxx-qt-build which crate to export
      "CXX_QT_EXPORT_CRATE_${CRATE}=1"
      # Tell cxx-qt-build which Qt modules we are using
      "CXX_QT_QT_MODULES=${IMPORT_CRATE_QT_MODULES_STR}"
      "QMAKE=${IMPORT_CRATE_QMAKE}"
      $<$<BOOL:${CMAKE_RUSTC_WRAPPER}>:RUSTC_WRAPPER=${CMAKE_RUSTC_WRAPPER}>)

    # When using WASM ensure that we have RUST_CXX_NO_EXCEPTIONS set
    if (${CMAKE_SYSTEM_NAME} MATCHES "Emscripten")
        # Read any existing CXX_FLAGS and append RUST_CXX_NO_EXCEPTIONS
        set(EMSCRIPTEN_CXX_FLAGS "${CMAKE_CXX_FLAGS}")
        list(APPEND EMSCRIPTEN_CXX_FLAGS "-DRUST_CXX_NO_EXCEPTIONS")

        message(STATUS "CXX-Qt Found Emscripten, setting CXXFLAGS=${EMSCRIPTEN_CXX_FLAGS}")
        corrosion_set_env_vars(${CRATE} "CXXFLAGS=${EMSCRIPTEN_CXX_FLAGS}")
    endif()

    file(MAKE_DIRECTORY "${IMPORT_CRATE_CXX_QT_EXPORT_DIR}/crates/${CRATE}/include/")
    target_include_directories(${CRATE} INTERFACE "${IMPORT_CRATE_CXX_QT_EXPORT_DIR}/crates/${CRATE}/include/")

    set_target_properties(${CRATE}
      PROPERTIES
      CXX_QT_EXPORT_DIR "${IMPORT_CRATE_CXX_QT_EXPORT_DIR}")

    # cxx-qt-build generates object files that need to be linked to the final target.
    # These are the static initializers that would be removed as an optimization if they're not referenced.
    # So add them to an object library instead.
    file(MAKE_DIRECTORY "${IMPORT_CRATE_CXX_QT_EXPORT_DIR}/crates/${CRATE}/")
    # When using the Ninja generator, we need to provide **some** way to generate the object file
    # Unfortunately I'm not able to tell corrosion that this obj file is indeed a byproduct, so
    # create a fake target for it.
    # This target doesn't need to do anything, because the file should already exist after building the crate.
    add_custom_target(${CRATE}_mock_initializers
      COMMAND ${CMAKE_COMMAND} -E true
      DEPENDS ${CRATE}
      BYPRODUCTS "${IMPORT_CRATE_CXX_QT_EXPORT_DIR}/crates/${CRATE}/initializers.o")

    add_library(${CRATE}_initializers OBJECT IMPORTED)
    set_target_properties(${CRATE}_initializers
      PROPERTIES
      IMPORTED_OBJECTS "${IMPORT_CRATE_CXX_QT_EXPORT_DIR}/crates/${CRATE}/initializers.o")
    # Note that we need to link using TARGET_OBJECTS, so that the object files are included **transitively**, otherwise
    # Only the linker flags from the object library would be included, but not the actual object files.
    # See also the "Linking Object Libraries" and "Linking Object Libraries via $<TARGET_OBJECTS>" sections:
    # https://cmake.org/cmake/help/latest/command/target_link_libraries.html
    target_link_libraries(${CRATE} INTERFACE ${CRATE}_initializers $<TARGET_OBJECTS:${CRATE}_initializers>)

    # Link the static library to Qt
    # Note that we cannot do this on the final CRATE target as this is an interface
    # which depends on the static library. If we do target_link_libraries on the ${CRATE} target,
    # the static library will not actually depend on the Qt modules, but be a kind of "sibling dependency", which CMake may reorder.
    # This can cause CMake to emit the wrong link order, with Qt before the static library, which then fails to build with ld.bfd
    # https://stackoverflow.com/questions/51333069/how-do-the-library-selection-rules-differ-between-gold-and-the-standard-bfd-li
    target_link_libraries(${CRATE}-static INTERFACE ${IMPORT_CRATE_QT_MODULES})

    if ((CMAKE_CXX_COMPILER_ID STREQUAL "MSVC")
      AND (CMAKE_BUILD_TYPE STREQUAL "Debug")
      AND (NOT (CMAKE_MSVC_RUNTIME_LIBRARY STREQUAL "MultiThreadedDLL")))
      # MSVC(Debug): Tell the linker not to link to the MultiThreadedDLL runtime and use the Debug version instead
      # This is a new workaround for this issue:
      # https://corrosion-rs.github.io/corrosion/common_issues.html#linking-debug-cc-libraries-into-rust-fails-on-windows-msvc-targets
      # As outlined in this comment:
      # https://github.com/rust-lang/rust/issues/39016#issuecomment-2521395154
      target_link_options(${CRATE}-static INTERFACE  /NODEFAULTLIB:msvcrt /DEFAULTLIB:msvcrtd)
    endif()
  endforeach()

  if((NOT CXX_QT_SUPPRESS_MSVC_RUNTIME_WARNING)
    AND (CMAKE_CXX_COMPILER_ID STREQUAL "MSVC")
    AND (CMAKE_BUILD_TYPE STREQUAL "Debug")
    AND (CMAKE_MSVC_RUNTIME_LIBRARY STREQUAL "MultiThreadedDLL"))
    message(WARNING
      " CXX-Qt Warning: CMAKE_MSVC_RUNTIME_LIBRARY should no longer be set in MSVC Debug build!\n \n"
      " In previous versions of CXX-Qt it was necessary to set CMAKE_MSVC_RUNTIME_LIBRARY=\"MultiThreadedDLL\".\n"
      " Starting with CXX-Qt 0.7.2, this has been fixed and is no longer necessary or recommended.\n \n"

      " See also:\n"
      " https://github.com/KDAB/cxx-qt/issues/1234\n \n"
      " To suppress this warning set CXX_QT_SUPPRESS_MSVC_RUNTIME_WARNING to ON"
      )
  endif()

endfunction()


function(cxx_qt_import_qml_module target)
  cmake_parse_arguments(QML_MODULE "" "URI;SOURCE_CRATE" "" ${ARGN})

  if (NOT DEFINED QML_MODULE_URI)
    message(FATAL_ERROR "cxx_qt_import_qml_module: URI must be specified!")
  endif()

  if (NOT DEFINED QML_MODULE_SOURCE_CRATE)
    message(FATAL_ERROR "cxx_qt_import_qml_module: SOURCE_CRATE must be specified!")
  endif()

  get_target_property(QML_MODULE_EXPORT_DIR ${QML_MODULE_SOURCE_CRATE} CXX_QT_EXPORT_DIR)
  get_target_property(QML_MODULE_CRATE_TYPE ${QML_MODULE_SOURCE_CRATE} TYPE)

  if (${QML_MODULE_EXPORT_DIR} STREQUAL "QML_MODULE_EXPORT_DIR-NOTFOUND")
    message(FATAL_ERROR "cxx_qt_import_qml_module: SOURCE_CRATE must be a valid target that has been imported with cxx_qt_import_crate!")
  endif()

  # Note: This needs to match the URI conversion in cxx-qt-build
  string(REPLACE "." "_" module_name ${QML_MODULE_URI})
  set(QML_MODULE_DIR "${QML_MODULE_EXPORT_DIR}/qml_modules/${module_name}")
  file(MAKE_DIRECTORY ${QML_MODULE_DIR})

  # QML plugin - init target
  # When using the Ninja generator, we need to provide **some** way to generate the object file
  # Unfortunately I'm not able to tell corrosion that this obj file is indeed a byproduct, so
  # create a fake target for it.
  # This target doesn't need to do anything, because the file should already exist after building the crate.
  add_custom_target(${target}_mock_obj_output
    COMMAND ${CMAKE_COMMAND} -E true
    DEPENDS ${QML_MODULE_SOURCE_CRATE}
    BYPRODUCTS "${QML_MODULE_DIR}/plugin_init.o")

  add_library(${target} OBJECT IMPORTED GLOBAL)
  set_target_properties(${target}
    PROPERTIES
    IMPORTED_OBJECTS "${QML_MODULE_DIR}/plugin_init.o")
  target_link_libraries(${target} INTERFACE ${QML_MODULE_SOURCE_CRATE})

  message(VERBOSE "CXX-Qt Expects QML plugin: ${QML_MODULE_URI} in directory: ${QML_MODULE_DIR}")
endfunction()
