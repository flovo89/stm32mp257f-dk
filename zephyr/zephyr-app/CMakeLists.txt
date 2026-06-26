cmake_minimum_required(VERSION 3.20.0)

find_package(Zephyr REQUIRED HINTS $ENV{ZEPHYR_BASE})
project(stm32mp257f_m33_app VERSION 2.0.0 LANGUAGES C)

target_include_directories(app PRIVATE ${LIBMETAL_INCLUDE_DIR} ${OPENAMP_INCLUDE_DIR})

target_sources(app PRIVATE
    src/main.c
    src/pulse_gen.c
    src/sampler.c
)
