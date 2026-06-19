cmake_minimum_required(VERSION 3.20.0)

# Board: STM32MP257F-DK, Cortex-M33 core
# Set via -DBOARD=stm32mp257f_dk/stm32mp257f/m33
# or export BOARD=stm32mp257f_dk/stm32mp257f/m33

find_package(Zephyr REQUIRED HINTS $ENV{ZEPHYR_BASE})
project(stm32mp257f_m33_app VERSION 1.0.0 LANGUAGES C)

target_include_directories(app PRIVATE ${LIBMETAL_INCLUDE_DIR} ${OPENAMP_INCLUDE_DIR})

target_sources(app PRIVATE
    src/main.c
    src/adc.c
    src/encoder.c
    src/pwm.c
    src/foc.c
)
