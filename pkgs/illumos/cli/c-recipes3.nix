# cli/c-recipes3.nix -- C/C++ libraries the x86 build queue has jobs for and solnix lacked (recipes3, 2026-11-08): every one's
# nixpkgs inputs are already in solnix, and nothing on main depends on them yet, so only these drvs are new. Versions are the queue's
# targets (jansson and oniguruma: the cross-arch jobs from the served sparcv9 rows, same source and sha256). Store-only builds
# (nativeTools = NixOS nativeBuildInputs + config.site), shared libraries as nixpkgs builds them, each with an in-build check that links
# and runs it. Sources pinned by sha256 (libogg and libzip equal to nixpkgs' flat hash; GitHub tag tarballs have no upstream signature).
{ base, mkSrcPkg, world, zlib, chk, hostTools, cmake, ... }:
let
  gh = repo: tag: sha256: { url = "https://codeload.github.com/${repo}/tar.gz/refs/tags/${tag}"; inherit sha256; };
  # cmake projects: the store cmake, store prefixes only (as c-recipes2.nix)
  cmakeB = extra: ''
    cmake -S . -B _b -DCMAKE_INSTALL_PREFIX="$out" -DCMAKE_INSTALL_LIBDIR=lib/amd64 -DCMAKE_C_COMPILER="$CC" -DCMAKE_CXX_COMPILER="$CXX" \
      -DCMAKE_BUILD_TYPE=Release -DCMAKE_SKIP_RPATH=ON -DCMAKE_IGNORE_PREFIX_PATH="/usr;/usr/local;/opt" \
      -DCMAKE_IGNORE_PATH="/usr/lib/64;/usr/lib/amd64;/lib/64" ${extra} >&2
    cmake --build _b -j16 >&2; cmake --install _b >&2
  '';
  # a C/C++ test program against the just-installed library: <src> <ext> <compiler> <link flags>
  tprog = src: ext: cc: libs: ''
    cat > "$W/t.${ext}" <<'TPROG'
${src}
TPROG
    "${cc}" -I"$out/include" "$W/t.${ext}" -L"$out/lib/amd64" ${libs} -Wl,-R,"$out/lib/amd64" -o "$W/t"
  '';
in rec {
  # libogg (BSD-3-Clause): the Ogg container library (libvorbis, opus-tools, flac). cmake, shared, as nixpkgs.
  libogg = mkSrcPkg {
    pname = "libogg"; version = "1.3.6";
    src = { url = "https://downloads.xiph.org/releases/ogg/libogg-1.3.6.tar.xz";
            sha256 = "5c8253428e181840cd20d41f3ca16557a9cc04bad4a3d04cce84808677fa1061"; };
    deps = [ world ]; nativeTools = [ cmake ] ++ hostTools;
    build = ''
      ${cmakeB "-DBUILD_SHARED_LIBS=ON -DBUILD_TESTING=OFF -DINSTALL_DOCS=OFF"}
      ${tprog ''#include <ogg/ogg.h>
#include <stdio.h>
int main(void){ogg_sync_state s; if(ogg_sync_init(&s)) return 1; char *b=ogg_sync_buffer(&s,4); if(!b) return 1; ogg_sync_clear(&s); puts("ogg ok"); return 0;}'' "c" "$CC" "-logg"}
      ${chk ''"$W/t"'' "^ogg ok$"}
    '';
  };

  # jansson (MIT): a C JSON library. autotools (the served sparcv9 row's build system and tarball).
  jansson = mkSrcPkg {
    pname = "jansson"; version = "2.14";
    src = { url = "https://github.com/akheron/jansson/releases/download/v2.14/jansson-2.14.tar.gz";
            sha256 = "5798d010e41cf8d76b66236cfb2f2543c8d082181d16bc3085ab49538d4b9929"; };
    deps = [ world ]; nativeTools = hostTools;
    build = ''
      ./configure --prefix="$out" --libdir="$out/lib/amd64" --disable-static
      gmake -j8; gmake install
      ${tprog ''#include <jansson.h>
#include <stdio.h>
int main(void){json_error_t e; json_t *j=json_loads("{\"a\":[1,2,42]}",0,&e); if(!j) return 1;
printf("%lld\n",(long long)json_integer_value(json_array_get(json_object_get(j,"a"),2))); json_decref(j); return 0;}'' "c" "$CC" "-ljansson"}
      ${chk ''"$W/t"'' "^42$"}
    '';
  };

  # oniguruma (BSD-2-Clause): the regex library jq and tig link. autotools, --enable-posix-api as nixpkgs (the served sparcv9 row's tarball).
  oniguruma = mkSrcPkg {
    pname = "oniguruma"; version = "6.9.9";
    src = { url = "https://github.com/kkos/oniguruma/releases/download/v6.9.9/onig-6.9.9.tar.gz";
            sha256 = "60162bd3b9fc6f4886d4c7a07925ffd374167732f55dce8c491bfd9cd818a6cf"; };
    deps = [ world ]; nativeTools = hostTools;
    build = ''
      # illumos declares alloca() only in <alloca.h>, which regint.h does not include: the gcc builtin (as packages.nix's oniguruma)
      ./configure --prefix="$out" --libdir="$out/lib/amd64" --disable-static --enable-posix-api=yes CFLAGS="-O2 -Dalloca=__builtin_alloca"
      gmake -j8; gmake install
      ${tprog ''#include <oniguruma.h>
#include <stdio.h>
#include <string.h>
int main(void){regex_t *r; OnigErrorInfo ei; OnigEncoding e[1]={ONIG_ENCODING_UTF8}; onig_initialize(e,1);
const UChar *p=(const UChar*)"a(b+)c", *s=(const UChar*)"xxabbbcyy"; OnigRegion *g=onig_region_new();
if(onig_new(&r,p,p+strlen((const char*)p),ONIG_OPTION_DEFAULT,ONIG_ENCODING_UTF8,ONIG_SYNTAX_DEFAULT,&ei)) return 1;
if(onig_search(r,s,s+9,s,s+9,g,ONIG_OPTION_NONE)<0) return 1; printf("%d %d\n",g->beg[1],g->end[1]); return 0;}'' "c" "$CC" "-lonig"}
      ${chk ''"$W/t"'' "^3 6$"}
    '';
  };

  # libuv (MIT etc.): the async I/O library (nodejs, cmake, neovim, bind). cmake (nixpkgs uses autotools; the cmake build installs the same
  # libuv.so.1 + libuv.pc without autogen.sh's autoreconf). Its event-port backend is the Solaris one upstream.
  libuv = mkSrcPkg {
    pname = "libuv"; version = "1.53.0";
    src = { url = "https://dist.libuv.org/dist/v1.53.0/libuv-v1.53.0.tar.gz";
            sha256 = "cb0d6dd2128d5a95bd242c6cc982a24fe608fa93da57b6b4ec763b0018c53e64"; };
    deps = [ world ]; nativeTools = [ cmake ] ++ hostTools;
    build = ''
      ${cmakeB "-DBUILD_TESTING=OFF -DLIBUV_BUILD_SHARED=ON"}
      ${tprog ''#include <uv.h>
#include <stdio.h>
static int n; static void cb(uv_timer_t *t){n++; uv_close((uv_handle_t*)t,NULL);}
int main(void){uv_loop_t *l=uv_default_loop(); uv_timer_t t; uv_timer_init(l,&t); uv_timer_start(&t,cb,10,0); uv_run(l,UV_RUN_DEFAULT);
printf("libuv %s timer %d\n",uv_version_string(),n); return n!=1;}'' "c" "$CC" "-luv"}
      ${chk ''"$W/t"'' "^libuv 1\\.53\\.0 timer 1$"}
    '';
  };

  # snappy (BSD-3-Clause): Google's fast compressor (leveldb, mongodb drivers). cmake, shared, no tests/benchmarks, as nixpkgs.
  snappy = mkSrcPkg {
    pname = "snappy"; version = "1.2.2";
    src = gh "google/snappy" "1.2.2" "90f74bc1fbf78a6c56b3c4a082a05103b3a56bb17bca1a27e052ea11723292dc";
    deps = [ world ]; nativeTools = [ cmake ] ++ hostTools;
    build = ''
      ${cmakeB "-DBUILD_SHARED_LIBS=ON -DSNAPPY_BUILD_TESTS=OFF -DSNAPPY_BUILD_BENCHMARKS=OFF"}
      ${tprog ''#include <snappy.h>
#include <cstdio>
#include <string>
int main(){std::string in(1000,'z'), c, u; snappy::Compress(in.data(),in.size(),&c); if(!snappy::Uncompress(c.data(),c.size(),&u)||u!=in) return 1;
std::printf("snappy %zu->%zu\n",in.size(),c.size()); return 0;}'' "cc" "$CXX" "-lsnappy"}
      ${chk ''"$W/t"'' "^snappy 1000->[0-9]+$"}
    '';
  };

  # pugixml (MIT): a C++ XML parser. cmake, static as nixpkgs (BUILD_SHARED_LIBS=FALSE: nixpkgs builds the static library + headers).
  pugixml = mkSrcPkg {
    pname = "pugixml"; version = "1.16";
    src = { url = "https://github.com/zeux/pugixml/releases/download/v1.16/pugixml-1.16.tar.gz";
            sha256 = "4cee1ca4aad395170f4c7a07824f3bdd41f28316c6e1e1090a1425b278ec0b4b"; };
    deps = [ world ]; nativeTools = [ cmake ] ++ hostTools;
    build = ''
      ${cmakeB "-DBUILD_SHARED_LIBS=OFF -DPUGIXML_BUILD_TESTS=OFF"}
      ${tprog ''#include <pugixml.hpp>
#include <cstdio>
int main(){pugi::xml_document d; if(!d.load_string("<a><b n=\"42\"/></a>")) return 1; std::printf("%d\n", d.child("a").child("b").attribute("n").as_int()); return 0;}'' "cc" "$CXX" "-lpugixml"}
      ${chk ''"$W/t"'' "^42$"}
    '';
  };

  # googletest (BSD-3-Clause): gtest + gmock, shared, as nixpkgs gtest.
  gtest = mkSrcPkg {
    pname = "gtest"; version = "1.18.0";
    src = gh "google/googletest" "v1.18.0" "6e3191c1455468b3fc35a417fb565c1c5071aee1b7e7f85e30cf48a98d37d8b5";
    deps = [ world ]; nativeTools = [ cmake ] ++ hostTools;
    build = ''
      ${cmakeB "-DBUILD_SHARED_LIBS=ON"}
      ${tprog ''#include <gtest/gtest.h>
TEST(T, Add){ EXPECT_EQ(1+1, 2); }
int main(int c, char **v){ ::testing::InitGoogleTest(&c, v); return RUN_ALL_TESTS(); }'' "cc" "$CXX" "-lgtest"}
      ${chk ''"$W/t"'' "\\[  PASSED  \\] 1 test"}
    '';
  };

  # scdoc (MIT): the man page generator (from scdoc markup) that sway/wlroots/foot/aerc docs need. One C file, a plain Makefile.
  scdoc = mkSrcPkg {
    pname = "scdoc"; version = "1.11.5";
    src = { url = "https://git.sr.ht/~sircmpwn/scdoc/archive/1.11.5.tar.gz";
            sha256 = "98780bbdf16c1bce89ef3a8c0f537ac6e4ea77087b609e7698857614488a2a62"; };
    deps = [ world ]; nativeTools = hostTools;
    build = ''
      gmake -j8 PREFIX="$out" CC="$CC" LDFLAGS=; gmake install PREFIX="$out" CC="$CC"
      ${chk ''printf 'scdoc(1)\n\n# NAME\n\nscdoc - a test page\n' | "$out/bin/scdoc"'' "^\\.TH \"scdoc\" \"1\""}
    '';
  };

  # libzip (BSD-3-Clause): read/write zip archives. cmake, zlib + bzip2 (nixpkgs adds xz/zstd; solnix's xz/zstd are nix-chain internal).
  libzip = mkSrcPkg {
    pname = "libzip"; version = "1.11.4";
    src = { url = "https://libzip.org/download/libzip-1.11.4.tar.gz";
            sha256 = "82e9f2f2421f9d7c2466bbc3173cd09595a88ea37db0d559a9d0a2dc60dc722e"; };
    deps = [ world zlib base.nixChain.bzip2 ]; nativeTools = [ cmake ] ++ hostTools;
    build = ''
      # zlib and bzip2 by path: main's CMAKE_PREFIX_PATH is ';'-joined, one dir to cmake on Unix ("Could NOT find ZLIB", measured)
      ${cmakeB "-DZLIB_ROOT=${zlib} -DZLIB_LIBRARY=${zlib}/lib/amd64/libz.so -DZLIB_INCLUDE_DIR=${zlib}/include -DBZIP2_LIBRARY=${base.nixChain.bzip2}/lib/amd64/libbz2.so -DBZIP2_INCLUDE_DIR=${base.nixChain.bzip2}/include -DBUILD_REGRESS=OFF -DBUILD_EXAMPLES=OFF -DBUILD_DOC=OFF -DBUILD_TOOLS=ON -DENABLE_LZMA=OFF -DENABLE_ZSTD=OFF -DENABLE_OPENSSL=OFF -DENABLE_GNUTLS=OFF -DENABLE_MBEDTLS=OFF -DENABLE_COMMONCRYPTO=OFF -DENABLE_WINDOWS_CRYPTO=OFF"}
      ${tprog ''#include <zip.h>
#include <stdio.h>
int main(int c, char **v){int e; zip_t *z=zip_open(v[1],ZIP_CREATE|ZIP_TRUNCATE,&e); if(!z) return 1; zip_source_t *s=zip_source_buffer(z,"hello zip",9,0);
if(zip_file_add(z,"a.txt",s,0)<0) return 1; if(zip_close(z)) return 1; z=zip_open(v[1],ZIP_RDONLY,&e); if(!z) return 1;
zip_file_t *f=zip_fopen(z,"a.txt",0); char b[16]={0}; zip_fread(f,b,9); printf("%s %lld\n",b,(long long)zip_get_num_entries(z,0)); return 0;}'' "c" "$CC" "-lzip"}
      ${chk ''"$W/t" "$W/t.zip"'' "^hello zip 1$"}
    '';
  };

  # Vulkan-Headers (Apache-2.0): headers + the registry (Mesa's vulkan drivers, vulkan-loader). Header-only; cmake installs them.
  vulkan-headers = mkSrcPkg {
    pname = "vulkan-headers"; version = "1.4.363.0";
    src = gh "KhronosGroup/Vulkan-Headers" "vulkan-sdk-1.4.363.0" "4a078be12bef21cfebc09d878b77a63cff9d68f899254a0b00d0e37ef73e7f7e";
    deps = [ world ]; nativeTools = [ cmake ] ++ hostTools;
    build = ''
      ${cmakeB ""}
      grep -q '#define VK_HEADER_VERSION 363$' "$out/include/vulkan/vulkan_core.h" || { echo "FATAL: vulkan-headers version" >&2; exit 1; }
      [ -f "$out/share/vulkan/registry/vk.xml" ] || { echo "FATAL: vulkan registry" >&2; exit 1; }
    '';
  };
}
