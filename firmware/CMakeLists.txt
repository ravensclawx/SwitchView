cmake_minimum_required(VERSION 3.25)
set(PICO_BOARD pico2_w)
include($ENV{PICO_SDK_PATH}/external/pico_sdk_import.cmake)
project(pico_pro_controller C CXX ASM)
set(CMAKE_CXX_STANDARD 17)
set(PICO_CXX_ENABLE_EXCEPTIONS 1)
pico_sdk_init()
add_executable(pico_pro_controller
  src/main.cpp
  src/SwitchUsb.cpp
  src/SwitchCommon.cpp)
target_include_directories(pico_pro_controller PUBLIC include ${CMAKE_CURRENT_SOURCE_DIR}/../proto)
target_link_libraries(pico_pro_controller pico_stdlib pico_rand hardware_pio tinyusb_device pico_cyw43_arch_lwip_poll)
pico_enable_stdio_usb(pico_pro_controller 0)
pico_enable_stdio_uart(pico_pro_controller 1)
pico_add_extra_outputs(pico_pro_controller)

set(USB_LAYOUT 0 CACHE STRING "0 controller, 1 composite, 2 keyboard")
if(NOT USB_LAYOUT MATCHES "^[012]$")
  message(FATAL_ERROR "Invalid USB_LAYOUT")
endif()
target_compile_definitions(pico_pro_controller PRIVATE USB_LAYOUT=${USB_LAYOUT})

# Wi-Fi credentials and the Pico's static address live in secrets.cmake
# (git-ignored); see secrets.cmake.example.
include(${CMAKE_CURRENT_SOURCE_DIR}/secrets.cmake OPTIONAL RESULT_VARIABLE SV_SECRETS)
if(NOT SV_SECRETS)
  message(FATAL_ERROR "firmware/secrets.cmake missing: copy secrets.cmake.example and fill in your Wi-Fi details")
endif()
if(NOT DEFINED SV_PICO_IP)
  set(SV_PICO_IP "192.168.4.60")
endif()
if(NOT DEFINED SV_NETMASK)
  set(SV_NETMASK "255.255.252.0")
endif()
if(NOT DEFINED SV_GATEWAY)
  set(SV_GATEWAY "192.168.4.1")
endif()
target_compile_definitions(pico_pro_controller PRIVATE
  SV_WIFI_SSID="${SV_WIFI_SSID}" SV_WIFI_PASS="${SV_WIFI_PASS}"
  SV_PICO_IP="${SV_PICO_IP}" SV_NETMASK="${SV_NETMASK}" SV_GATEWAY="${SV_GATEWAY}")
