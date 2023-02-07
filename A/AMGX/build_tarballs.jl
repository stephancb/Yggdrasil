using BinaryBuilder, Pkg

const YGGDRASIL_DIR = "../.."
include(joinpath(YGGDRASIL_DIR, "fancy_toys.jl"))
include(joinpath(YGGDRASIL_DIR, "platforms", "cuda.jl"))

name = "AMGX"
version = v"2.3.0"
sources = [
    GitSource("https://github.com/NVIDIA/AMGX.git",
              "32e1f44fa93af7859490a800f137e75b6513420c"),
    DirectorySource("./bundled")
]

script = raw"""
# nvcc writes to /tmp, which is a small tmpfs in our sandbox.
# make it use the workspace instead
export TMPDIR=${WORKSPACE}/tmpdir
mkdir ${TMPDIR}

# the build system doesn't find libgcc and libstdc++
if [[ "${nbits}" == 32 ]]; then
    export CFLAGS="-Wl,-rpath-link,/opt/${target}/${target}/lib"
elif [[ "${target}" != *-apple-* ]]; then
    export CFLAGS="-Wl,-rpath-link,/opt/${target}/${target}/lib64"
fi

cd ${WORKSPACE}/srcdir/AMGX*

# Apply all our patches
if [ -d $WORKSPACE/srcdir/patches ]; then
for f in $WORKSPACE/srcdir/patches/*.patch; do
    echo "Applying patch ${f}"
    atomic_patch -p1 ${f}
done
fi

install_license LICENSE

mkdir build
cd build
CMAKE_POLICY_DEFAULT_CMP0021=OLD \
CUDA_BIN_PATH=${prefix}/cuda/bin \
CUDA_LIB_PATH=${prefix}/cuda/lib64 \
CUDA_INC_PATH=${prefix}/cuda/include \
cmake -DCMAKE_TOOLCHAIN_FILE="${CMAKE_TARGET_TOOLCHAIN}" \
      -DCMAKE_INSTALL_PREFIX=${prefix} \
      -DCMAKE_FIND_ROOT_PATH="${prefix}" \
      -DCMAKE_BUILD_TYPE=Release \
      -DCMAKE_CXX_STANDARD=11 \
      -DCUDA_ARCH=${CUDA_ARCHS} \
      -DCUDA_TOOLKIT_ROOT_DIR="${prefix}/cuda" \
      -DCMAKE_CUDA_COMPILER=$prefix/cuda/bin/nvcc \
      -DCMAKE_EXE_LINKER_FLAGS="-Wl,-rpath-link,/opt/${target}/${target}/lib64" \
      -Wno-dev \
      ..

# Notes:
# - https://github.com/NVIDIA/AMGX/issues/172#issuecomment-1124194288

make -j${nproc} all
make install

# clean-up
## unneeded static libraries
rm ${libdir}/*.a ${libdir}/sublibs/*.a
"""

augment_platform_block = CUDA.augment

platforms = [
    Platform("x86_64", "linux"; libc="glibc", cxxstring_abi = "cxx11"),
]

products = [
    LibraryProduct("libamgxsh", :libamgxsh),
]

# XXX: support only specifying major/minor version (JuliaPackaging/BinaryBuilder.jl#/1212)
cuda_full_versions = Dict(
    v"10.2" => v"10.2.89",
    v"11.0" => v"11.0.3",
    v"12.0" => v"12.0.0",
)

cuda_archs = Dict(
    v"10.2" => "30;50;60;70",
    v"11.0" => "50;60;70;80;90",
    v"12.0" => "50;60;70;80;90",
)

# build AMGX for all supported CUDA toolkits
#
# the library doesn't have specific CUDA requirements, so we only build for CUDA 10.2,
# the oldest version supported by CUDA.jl, and 11.0, which (per semantic versioning)
# should support every CUDA 11.x version.
#
# if AMGX would start using specific APIs from recent CUDA versions, add those here.
for cuda_version in [v"10.2", v"11.0", v"12.0"], platform in platforms
    augmented_platform = Platform(arch(platform), os(platform);
                                  cuda=CUDA.platform(cuda_version))
    should_build_platform(triplet(augmented_platform)) || continue

    dependencies = [
        BuildDependency(PackageSpec(name="CUDA_full_jll",
                                    version=cuda_full_versions[cuda_version])),
        RuntimeDependency(PackageSpec(name="CUDA_Runtime_jll")),
    ]

    preamble = """
    CUDA_ARCHS="$(cuda_archs[cuda_version])"
    """

    build_tarballs(ARGS, name, version, sources, preamble*script, [augmented_platform],
                   products, dependencies; lazy_artifacts=true,
                   julia_compat="1.7", augment_platform_block,
                   skip_audit=true, dont_dlopen=true)
end
