#!/usr/bin/env bash
# Version reducida de scripts/setup.sh de EmuSuNi: solo lo necesario para compilar la PlayStation.
# Ejecutar como root (sudo -i bash scripts/setup-ps1.sh). Commits copiados de scripts/setup.sh.
set -euo pipefail

SRC_ROOT="$HOME/src"
BUILD_ROOT="${PS4_BUILD_ROOT:-$HOME/dolphinps4-build}"
OPENORBIS=/opt/pacbrew/ps4/openorbis
DOLPHINPS4_COMMIT=720f60abc42d0d160ea19b81eb506de45fa0b17b
SNES9X_COMMIT=1bcc369e89f08243e0a462882fb1f3e42e51de3a
IMGUI_COMMIT=45acd5e0e82f4c954432533ae9985ff0e1aad6d5
FCEUMM_COMMIT=ac0d00a7fc01166f84c7bac01d1084ebfd2b865e
MGBA_COMMIT=7a12d6d4b9acb14c0ae62c9166b6a2f3d08007f6
SWANSTATION_COMMIT=e436e9b85374def58d211df7f78880f0f4a917b4
RCHEEVOS_COMMIT=1433173220a7eaede6a9ed7a18e94117be1821e0
LIBCHDR_COMMIT=47d794151b2b64f6aba60304e6480f4f5a2bc24b
MESA_TAG=mesa-26.0.8
LIBDRM_TAG=libdrm-2.4.125
export DEBIAN_FRONTEND=noninteractive

step() { printf '\n== %s\n' "$*"; }

checkout() {
    local url=$1 dir=$2 commit=$3
    if [ ! -d "$dir/.git" ]; then
        git init -q "$dir"
        git -C "$dir" remote add origin "$url"
    fi
    git -C "$dir" fetch -q --depth 1 origin "$commit"
    git -C "$dir" checkout -q FETCH_HEAD
}

step "Packages"
apt-get update -qq
apt-get install -y -qq git wget curl ca-certificates gnupg lsb-release xz-utils cmake ninja-build \
    python3 python3-venv python3-pil pkg-config bison flex glslang-tools libxml2 nasm make binutils >/dev/null
if ! command -v clang-21 >/dev/null; then
    wget -qO /tmp/llvm.sh https://apt.llvm.org/llvm.sh
    bash /tmp/llvm.sh 21
fi

step "OpenOrbis toolchain (PacBrew 1.0.0)"
if [ ! -d "$OPENORBIS" ]; then
    wget -q https://github.com/PacBrew/pacbrew-packages/releases/download/1.0.0/pacbrew-ps4-openorbis-1.0.0.tar.xz \
        -O /tmp/openorbis.tar.xz
    rm -rf /tmp/openorbis && mkdir -p /tmp/openorbis
    tar xJf /tmp/openorbis.tar.xz -C /tmp/openorbis
    mkdir -p "$(dirname "$OPENORBIS")"
    echo "Candidatos 'openorbis' dentro del paquete:"
    find /tmp/openorbis -maxdepth 6 -type d -name openorbis
    # La buena es la que contiene ps4vars.sh (no la primera que salga de find).
    OO_DIR=""
    while read -r d; do
        if [ -f "$d/ps4vars.sh" ]; then OO_DIR=$d; break; fi
    done < <(find /tmp/openorbis -maxdepth 6 -type d -name openorbis)
    if [ -z "$OO_DIR" ]; then
        echo "ERROR: no encontre ps4vars.sh en el paquete. Contenido:"
        find /tmp/openorbis -maxdepth 4 | head -60
        exit 1
    fi
    echo "Usando: $OO_DIR"
    mv "$OO_DIR" "$OPENORBIS"
fi
echo "Contenido de $OPENORBIS:"
ls "$OPENORBIS"
if [ ! -f "$OPENORBIS/include/math.h" ]; then
    echo "AVISO: no existe $OPENORBIS/include/math.h. Donde hay math.h:"
    find "$OPENORBIS" -name math.h | head
fi
if [ ! -e /usr/lib/x86_64-linux-gnu/libssl.so.1.1 ]; then
    pool=http://archive.ubuntu.com/ubuntu/pool/main/o/openssl/
    deb=$(curl -s "$pool" | grep -o 'libssl1.1_1.1.1f-1ubuntu2[^"]*_amd64.deb' | sort -u | tail -1)
    wget -q "$pool$deb" -O /tmp/libssl11.deb
    apt-get install -y -qq /tmp/libssl11.deb >/dev/null
fi

step "DolphinPS4: libc++ 21 and the PS4 runtime"
checkout https://github.com/iHaiDeeZ/DolphinPS4 "$SRC_ROOT/DolphinPS4" "$DOLPHINPS4_COMMIT"
cd "$SRC_ROOT/DolphinPS4"
chmod +x toolchain/*.sh scripts/*.sh 2>/dev/null || true
grep -q UHAVE_QSORT_S scripts/build-mesa.sh ||
    sed -i "s/'-D__ORBIS__', '-DPS4',/'-D__ORBIS__', '-DPS4', '-UHAVE_QSORT_S',/" scripts/build-mesa.sh
PS4_BUILD_ROOT="$BUILD_ROOT" toolchain/build-libcxx.sh
PS4_BUILD_ROOT="$BUILD_ROOT" toolchain/build-runtime.sh

step "Mesa RADV for the PS4 ($MESA_TAG)"
mkdir -p "$BUILD_ROOT/src" "$BUILD_ROOT/host-tools/bin"
if [ ! -d "$BUILD_ROOT/src/mesa/.git" ]; then
    git clone -q --depth 1 -b "$MESA_TAG" https://gitlab.freedesktop.org/mesa/mesa.git "$BUILD_ROOT/src/mesa"
    git -C "$BUILD_ROOT/src/mesa" apply "$SRC_ROOT/DolphinPS4/patches/mesa-ps4.patch"
fi
[ -d "$BUILD_ROOT/src/libdrm" ] ||
    git clone -q --depth 1 -b "$LIBDRM_TAG" https://gitlab.freedesktop.org/mesa/drm.git "$BUILD_ROOT/src/libdrm"
if [ ! -x "$BUILD_ROOT/mesa-venv/bin/meson" ]; then
    python3 -m venv "$BUILD_ROOT/mesa-venv"
    "$BUILD_ROOT/mesa-venv/bin/pip" install -q meson mako pyyaml packaging
fi
ln -sf "$(command -v glslangValidator)" "$BUILD_ROOT/host-tools/bin/glslangValidator"
PS4_BUILD_ROOT="$BUILD_ROOT" scripts/build-mesa.sh setup

step "Sources: Snes9x, FCEUmm, mGBA, SwanStation, Dear ImGui, rcheevos, libchdr, Mbed TLS"
checkout https://github.com/snes9xgit/snes9x.git "$SRC_ROOT/snes9x" "$SNES9X_COMMIT"
checkout https://github.com/libretro/libretro-fceumm.git "$SRC_ROOT/fceumm" "$FCEUMM_COMMIT"
checkout https://github.com/libretro/mgba.git "$SRC_ROOT/mgba" "$MGBA_COMMIT"
checkout https://github.com/libretro/swanstation.git "$SRC_ROOT/swanstation" "$SWANSTATION_COMMIT"
checkout https://github.com/ocornut/imgui.git "$SRC_ROOT/imgui" "$IMGUI_COMMIT"
checkout https://github.com/RetroAchievements/rcheevos.git "$SRC_ROOT/rcheevos" "$RCHEEVOS_COMMIT"
checkout https://github.com/rtissera/libchdr.git "$SRC_ROOT/libchdr" "$LIBCHDR_COMMIT"
MBEDTLS_SHA256=66455e23a6190a30142cdc1113f7418158839331a9d8e6b0778631d077281770
if ! echo "$MBEDTLS_SHA256  $SRC_ROOT/mbedtls-2.16.6-apache.tgz" | sha256sum -c --quiet - 2>/dev/null; then
    wget -q https://sources.buildroot.net/mbedtls/mbedtls-2.16.6-apache.tgz -O /tmp/mbedtls-2.16.6-apache.tgz
    echo "$MBEDTLS_SHA256  /tmp/mbedtls-2.16.6-apache.tgz" | sha256sum -c -
    mv /tmp/mbedtls-2.16.6-apache.tgz "$SRC_ROOT/mbedtls-2.16.6-apache.tgz"
fi

step "Listo: ahora scripts/build.sh y scripts/package.sh"
