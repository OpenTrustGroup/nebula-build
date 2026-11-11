#!/bin/bash
# Copyright 2026 Open Trust Group. All rights reserved.
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.
#
# Build the nebula hypervisor image a MediaTek BSP flashes, gz.img, signed:
# zircon and garnet from a nebula source tree with a product's packages,
# packed by the BSP's gz kit and signed by its signing kit. README.md says
# what each input is.
#
#   build.sh --nebula-src DIR --product DIR [--product DIR]...
#            --gz-kit DIR --sign-kit DIR --bsp-project NAME -o OUT_DIR
#            [--python3 PATH] [--keep-zircon]
#            [--sign-platform NAME] [--sign-env-cfg FILE]
#
# OUT_DIR gets gz.img and gz-rel.img (signed), unsigned/, images/ (what the
# gz kit packs) and SHA256SUMS. The build's own output goes to the tree's
# out/; the tree's sources and both kits are left as they are.

set -eo pipefail; [[ "${TRACE}" ]] && set -x
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
  cat >&2 <<EOF
usage: $0 --nebula-src DIR --product DIR [--product DIR]...
          --gz-kit DIR --sign-kit DIR --bsp-project NAME -o OUT_DIR
          [--python3 PATH] [--keep-zircon] [--sign-platform NAME] [--sign-env-cfg FILE]

  --nebula-src     the nebula source tree (a jiri checkout, zircon's source included)
  --product        a product directory (buildroot_packages/, product.json); more than
                   one apply in order, a later one's files over an earlier one's
  --gz-kit         the BSP's hypervisor prebuilt directory, containing build-gz.sh
  --sign-kit       the BSP's sign-image_v2 directory, containing sign_flow.py
  --bsp-project    the BSP project build-gz.sh and the signer take (e.g. auto8668p1_64_sos)
  -o               output directory, outside the tree and the kits
  --python3        Python 3.12 for the signing kit, which ships only 3.12 bytecode
                   (default: python3)
  --sign-platform  signer platform (default: mt6881)
  --sign-env-cfg   signer config inside the kit (default: env_3072.cfg)
  --keep-zircon    use the zircon the tree has built (out/build-zircon*), not
                   build it again: for kernels built elsewhere on purpose (a
                   release's, with its version strings), or to save the time;
                   only when out/ is what the tree's zircon/ makes
EOF
  exit 1
}

PRODUCTS=()
PYTHON3=python3
SIGN_PLATFORM=mt6881
SIGN_ENV_CFG=env_3072.cfg
while [[ $# -ne 0 ]]; do
  case "$1" in
    --nebula-src) NEBULA="$(realpath "$2")"; shift ;;
    --product) PRODUCTS+=("$(realpath "$2")"); shift ;;
    --gz-kit) GZ_KIT="$(realpath "$2")"; shift ;;
    --sign-kit) SIGN_KIT="$(realpath "$2")"; shift ;;
    --bsp-project) BSP_PROJECT="$2"; shift ;;
    -o) OUT_DIR="$(realpath -m "$2")"; shift ;;
    --python3) PYTHON3="$2"; shift ;;
    --sign-platform) SIGN_PLATFORM="$2"; shift ;;
    --sign-env-cfg) SIGN_ENV_CFG="$2"; shift ;;
    --keep-zircon) KEEP_ZIRCON=1; shift; continue ;;
    *) usage ;;
  esac
  [[ $# -ge 1 ]] || usage
  shift
done
[[ -n "${NEBULA}" && ${#PRODUCTS[@]} -gt 0 && -n "${GZ_KIT}" && -n "${SIGN_KIT}" &&
   -n "${BSP_PROJECT}" && -n "${OUT_DIR}" ]] || usage

fail() { echo "error: $*" >&2; exit 1; }
[[ -f "${NEBULA}/zircon/makefile" && -d "${NEBULA}/garnet/packages" &&
   -f "${NEBULA}/build/gn/buildroot_gen_product.py" && -f "${NEBULA}/scripts/env.sh" ]] ||
  fail "${NEBULA} is not a nebula source tree (zircon/, garnet/, build/, scripts/)"
for p in "${PRODUCTS[@]}"; do
  [[ -d "${p}/buildroot_packages" ]] || fail "product ${p} has no buildroot_packages/"
done
[[ -x "${GZ_KIT}/build-gz.sh" ]] || fail "${GZ_KIT}/build-gz.sh not found"
[[ -f "${SIGN_KIT}/sign_flow.py" ]] || fail "${SIGN_KIT}/sign_flow.py not found"
"${PYTHON3}" -c 'import sys; sys.exit(sys.version_info[:2] != (3, 12))' 2>/dev/null ||
  fail "${PYTHON3} is not Python 3.12; the signing kit ships only 3.12 bytecode"
command -v python2 >/dev/null || fail "python2 is not on PATH (the tree's package resolver needs it)"
case "${OUT_DIR}/" in
  "${NEBULA}/"*|"${GZ_KIT}/"*|"${SIGN_KIT}/"*)
    fail "-o must not be inside the tree or a kit" ;;
esac

# The product the image is: the last product.json given names its platform
# and product, which name zircon's boot shim and the bootdata image.
PRODUCT_JSON=
for p in "${PRODUCTS[@]}"; do
  [[ ! -f "${p}/product.json" ]] || PRODUCT_JSON="${p}/product.json"
done
[[ -n "${PRODUCT_JSON}" ]] || fail "no --product has a product.json"
read -r PLATFORM PRODUCT < <(python3 -c '
import json, sys
d = json.load(open(sys.argv[1]))
print(d["platform"], d["product"])' "${PRODUCT_JSON}")
# build-gz.sh derives its image directory from the project name the same way.
IC_NAME="mt${BSP_PROJECT:4:4}"

# Only ever delete a previous output of this script, which it marks.
MARKER="${OUT_DIR}/.nebula-build"
if [[ -e "${OUT_DIR}" ]]; then
  if [[ -f "${MARKER}" ]]; then
    rm -rf "${OUT_DIR}"
  elif [[ -n "$(ls -A "${OUT_DIR}")" ]]; then
    fail "${OUT_DIR} is not empty and was not made by this script; refusing to replace it"
  fi
fi
WORK="${OUT_DIR}/work"
mkdir -p "${WORK}" "${OUT_DIR}/unsigned" "${OUT_DIR}/images"
touch "${MARKER}"

cd "${NEBULA}"
# A FUCHSIA_* variable left from another tree makes fx build that one.
unset FUCHSIA_DIR FUCHSIA_CONFIG FUCHSIA_OUT_DIR FUCHSIA_BUILD_DIR
export NEBULA_SRC="${NEBULA}"
source scripts/env.sh

# zircon: what the hypervisor image takes, in the nebula release flow's
# order (fx set-venus, then fx build-zircon): arm64, and venus-hee debug and
# release -- the kernels and the sysroot garnet compiles against. venus-tee
# (the TEE's) is no part of gz.img and is not built.
ZIRCON_BUILDS=(build-zircon/build-arm64 build-zircon/build-venus-hee build-zircon-release/build-venus-hee)
if [[ -n "${KEEP_ZIRCON}" ]]; then
  for z in "${ZIRCON_BUILDS[@]}"; do
    [[ -f "out/${z}/zircon.bin" ]] || fail "--keep-zircon: out/${z}/zircon.bin is not there; build zircon first"
  done
  echo "keeping zircon (out/build-zircon*)"
else
echo "building zircon"
(
  Z=scripts/build-zircon.sh; A=(USE_CLANG=true WITH_SYZKALLER=0)
  $Z -t arm64 "${A[@]}"
  $Z -t venus-hee "${A[@]}"
  $Z -r -t venus-hee "${A[@]}"
) > "${WORK}/zircon.log" 2>&1 || fail "building zircon failed; see ${WORK}/zircon.log"
fi

# The device-tree compiler: garnet builds a dtb into the image with whatever
# `dtc` is on PATH, so take the gz kit's, as the BSP's build does.
export PATH="${GZ_KIT}/nebula/host-tools:${PATH}"

# The products' package set: garnet/packages with every product over it, as
# the nebula release flow sees packages, resolved first so that only what the
# image is made of is built.
B="${NEBULA}/out/nebula-build"
P="${B}/pkgroot"
rm -rf "${B}"; mkdir -p "${P}/garnet" "${B}/packages"
cp -r garnet/packages "${P}/garnet/"
for p in "${PRODUCTS[@]}"; do
  cp -rf "${p}/buildroot_packages/." "${P}/"
done
python2 "${HERE}/lib/product-packages.py" --root "${P}" --package garnet/packages/venus-hee \
  --out "${B}/packages/venus-hee"

# `fx set-venus PROJECT`, with the package file in place of the project's
# own package lists; the same args.gn and .config otherwise.
venus_set() {  # project package-file
  local p=$1 d="out/$1/arm64"
  mkdir -p "$d"; rm -rf out/arm64; ln -s "${NEBULA}/$d" out/arm64
  {
    echo 'target_cpu = "arm64"'
    echo "zircon_project = \"$p\""
    echo 'bootfs_packages = true'
    echo 'with_syzkaller = 0'
    if [[ -n "${CCACHE_DIR:-}" && -d "${CCACHE_DIR}" ]]; then echo 'use_ccache = true'; fi
    echo "fuchsia_packages = [ \"$2\" ]"
  } > "$d/args.gn"
  buildtools/gn gen "$d" --check
  (source scripts/devshell/lib/vars.sh && zircon_project=$p variant= &&
   fx-config-write out/arm64 "" linux_6.6 2.10 nebula 0)
}
for p in venus-hee; do
  echo "building ${p}"
  {
    venus_set "${p}" "out/nebula-build/packages/${p}"
    fx build
    # export-buildroot copies the kernel command lines; the full package set
    # builds them by way of build/packages/bootfs
    fx build build/gn:cmdline build/gn:cmdline.rel
  } > "${WORK}/${p}.log" 2>&1 || fail "building ${p} failed; see ${WORK}/${p}.log"
done

# The buildroot, and the product over its packages, as the nebula release
# flow makes the images: a copy of the resolved packages, so that nothing
# writes into the garnet checkout.
echo "making the ${PRODUCT} images"
BR="${B}/buildroot"; PKG="${BR}/build/nebula/buildroot_packages"
{
  # fx export-buildroot exports venus-tee too, which is not built:
  # buildroot_initialize.py's own code, for venus-hee alone
  python3 - "${NEBULA}" "${BR}" "${P}" <<'PY'
import os, sys
sys.path.insert(0, os.path.join(sys.argv[1], 'build', 'gn'))
import buildroot_initialize as b
copy_packages = b.copy_packages
b.copy_packages = lambda n, h, p, z: copy_packages(n, h, p, z) if z == 'venus-hee' else None
b.buildroot_initialize(*sys.argv[1:4])
PY
  rm -rf "${PKG}/garnet"; mkdir -p "${PKG}"; cp -r "${P}/garnet" "${PKG}/"
  for p in "${PRODUCTS[@]}"; do
    cp -rf "${p}/buildroot_packages/." "${PKG}/"
  done
  cp -f "${PRODUCT_JSON}" "${PKG}/product.json"
  cp -f "${PKG}/bootfs.manifest.debug.venus-hee" "${BR}/out/build-zircon/build-venus-hee/bootfs.manifest"
  cp -f "${PKG}/bootfs.manifest.release.venus-hee" "${BR}/out/build-zircon-release/build-venus-hee/bootfs.manifest"
  (cd "${BR}" && ./build/gn/buildroot_gen_product.py --packages-home "${PKG}")
} > "${WORK}/product.log" 2>&1 || fail "making the images failed; see ${WORK}/product.log"

IMG="${OUT_DIR}/images"
Z="${BR}/out/build-zircon/build-venus-hee"; ZR="${BR}/out/build-zircon-release/build-venus-hee"
A="${BR}/out/venus-hee/arm64"
cp "${Z}/${PLATFORM}-boot-shim.bin" "${IMG}/boot-shim.bin"
cp "${ZR}/${PLATFORM}-boot-shim.bin" "${IMG}/boot-shim-rel.bin"
cp "${Z}/zircon.bin" "${IMG}/zircon.bin"
cp "${ZR}/zircon.bin" "${IMG}/zircon-rel.bin"
cp "${A}/bootdata-fs-${PLATFORM}-${PRODUCT}.bin" "${IMG}/bootdata-fs.bin"
cp "${A}/bootdata-fs-${PLATFORM}-${PRODUCT}-rel.bin" "${IMG}/bootdata-fs-rel.bin"

# The BSP's gz kit packs them; the copy keeps the kit as it is.
echo "packing with the BSP's build-gz.sh (${BSP_PROJECT})"
KIT="${WORK}/gz-kit"
cp -a "${GZ_KIT}" "${KIT}"
rm -rf "${KIT}/out"
mkdir -p "${KIT}/nebula/prebuilt-images-${IC_NAME}"
cp "${IMG}"/*.bin "${KIT}/nebula/prebuilt-images-${IC_NAME}/"
# No PLID is copied: build-gz.sh writes its own from the kit's
# ${BSP_PROJECT}/product.json, so the BSP decides what board the image claims.
(cd "${KIT}" && ./build-gz.sh --project "${BSP_PROJECT}" --no-ddk) > "${WORK}/build-gz.log" 2>&1 ||
  fail "build-gz.sh failed; see ${WORK}/build-gz.log"
cp "${KIT}/out/gz.img" "${KIT}/out/gz-rel.img" "${OUT_DIR}/unsigned/"

# The signer only knows the image as gz.img, so each variant is signed under
# that name in turn. PRODUCT_OUT, if set (as in a BSP or Android shell), would
# redirect the signer's input and output away from this copy of the kit.
SIGNER="${WORK}/sign-kit"
cp -a "${SIGN_KIT}" "${SIGNER}"
for variant in "" "-rel"; do
  rm -rf "${SIGNER}/unsigned" "${SIGNER}/out"
  mkdir -p "${SIGNER}/unsigned" "${SIGNER}/out"
  cp "${OUT_DIR}/unsigned/gz${variant}.img" "${SIGNER}/unsigned/gz.img"
  echo "signing gz${variant}.img"
  (cd "${SIGNER}" && env -u PRODUCT_OUT "${PYTHON3}" sign_flow.py "${SIGN_PLATFORM}" "${BSP_PROJECT}" \
      -env_cfg "${SIGNER}/${SIGN_ENV_CFG}" -target gz.img) > "${WORK}/sign${variant}.log" 2>&1 ||
    fail "signing gz${variant}.img failed; see ${WORK}/sign${variant}.log"
  cp "${SIGNER}/out/gz-verified.img" "${OUT_DIR}/gz${variant}.img"
done

# The build must not have written into the sources it read.
if [[ -e garnet/.git && -n "$(git -C garnet status --porcelain)" ]]; then
  git -C garnet status --short >&2
  fail "the build changed the garnet checkout"
fi

(cd "${OUT_DIR}" && sha256sum gz.img gz-rel.img unsigned/gz.img unsigned/gz-rel.img \
   images/*.bin > SHA256SUMS)
ls -l "${OUT_DIR}"/gz.img "${OUT_DIR}"/gz-rel.img
echo "done."
