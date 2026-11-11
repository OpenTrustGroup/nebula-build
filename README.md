# nebula-build

Builds the nebula hypervisor image a MediaTek BSP flashes, `gz.img`, signed:
zircon and garnet from a nebula source tree with a product's packages, packed
by the BSP's gz kit and signed by its signing kit.

The gz kit and the signing kit are the BSP's and are not in this repository:
give their paths.

## What it needs

- **A nebula source tree**: a jiri checkout of the nebula tag to build, with
  zircon's source, its toolchains (`zircon/prebuilt/`, `buildtools/`) and the
  host packages the nebula build documents. It is built in place: its `out/`
  receives the build; its sources are not changed.
- **A product**: one or more product directories, each with
  `buildroot_packages/` (files laid over `garnet/packages` and the buildroot's
  package lists: package files, bootfs manifests, `cmdline.txt`) and, in the
  last one, `product.json` (its `platform` and `product` name the boot shim and
  the bootdata image). Later products' files replace earlier ones'.
  `products/default` and `products/mtk8668` here are MT8668's.
- **The BSP's gz kit**: its hypervisor prebuilt directory, with `build-gz.sh`,
  its `nebula/host-tools/` (the build uses its `dtc`) and a directory per BSP
  project.
- **The BSP's signing kit**: its `sign-image_v2` directory, with `sign_flow.py`,
  and Python 3.12, the only version its bytecode runs on.
- `python2` on `PATH` (the tree's package resolver).

## Build

```sh
./build.sh --nebula-src ~/nebula \
    --product products/default --product products/mtk8668 \
    --gz-kit <BSP>/prebuilt/hypervisor/grt_mt8668 \
    --sign-kit <BSP>/sign-image_v2 \
    --bsp-project auto8668p1_64_sos_sta \
    --python3 /opt/python3.12/bin/python3.12 \
    -o out/mt8668
```

`-o` is a directory outside the tree and the kits:

```
out/mt8668/gz.img           signed
out/mt8668/gz-rel.img       signed, release build
out/mt8668/unsigned/        the same, unsigned
out/mt8668/images/          what the gz kit packed: boot-shim, zircon,
                            bootdata-fs, each also -rel
out/mt8668/SHA256SUMS
out/mt8668/work/            logs and the kits' working copies
```

A later run replaces a directory an earlier run made, and refuses any other
non-empty one.

`--bsp-project` is the BSP project the image is for: `auto8668p1_64_sos_sta`
for MT8668 with the TBox (3OS), `auto8668p1_64_sos` without it.

`--sign-platform` (default `mt6881`) and `--sign-env-cfg` (default
`env_3072.cfg`) are passed to the signer.

### Keeping zircon

`--keep-zircon` uses the zircon the tree has built (`out/build-zircon*`:
arm64, and venus-hee debug and release) instead of building it:
kernels built on purpose some other way (a release's, with its version strings
and build times, to check an image byte for byte), or to save the time when
only garnet changed. Use it only when `out/` is what the tree's `zircon/`
makes.

## Products

`products/SOURCE` says which grpower commit `products/` is, and which GRT tag
it pairs with. Build a tree with the products of its tag.

## What it does

1. zircon: arm64, and venus-hee debug and release, as the nebula release flow
   builds them. venus-tee, the TEE's, is no part of `gz.img`: not built.
2. The products' package set: `garnet/packages` with every product over it,
   resolved into one package file, so that only what the image is made of is
   built.
3. garnet for venus-hee (`fx build`), the buildroot (what `fx
   export-buildroot` makes, of venus-hee alone), the products over its package
   lists, and the product's images (`buildroot_gen_product.py`).
4. The gz kit's `build-gz.sh --project <bsp-project> --no-ddk` on a copy of
   the kit with the images in `nebula/prebuilt-images-<IC>/`; the board the
   image claims (its PLID) is the kit's.
5. The signing kit's `sign_flow.py` on a copy of the kit, for `gz.img` and
   `gz-rel.img`.

## Layout

| path | what |
| --- | --- |
| `build.sh` | the build |
| `lib/product-packages.py` | resolves a product's package set into one package file |
| `products/default`, `products/mtk8668` | MT8668's product |
| `products/SOURCE` | the grpower commit and GRT tag `products/` is |
