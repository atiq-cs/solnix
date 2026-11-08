# cli/c-recipes3.nix -- C/C++ libraries the x86 build queue has jobs for and solnix lacked (recipes3, 2026-11-08): every one's
# nixpkgs inputs are already in solnix, and nothing on main depends on them yet, so only these drvs are new. Versions are the queue's
# targets (jansson and oniguruma: the cross-arch jobs from the served sparcv9 rows, same source and sha256). Store-only builds
# (nativeTools = NixOS nativeBuildInputs + config.site), shared libraries as nixpkgs builds them, each with an in-build check that links
# and runs it. Sources pinned by sha256 (libogg and libzip equal to nixpkgs' flat hash; GitHub tag tarballs have no upstream signature).
{ base, mkSrcPkg, world, zlib, openssl, ncurses, chk, hostTools, cmake, ... }:
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

  # ---- recipes3 batch 2 ---------------------------------------------------------------------------------------------------------
  # libedit (BSD-3-Clause): the BSD line editor (lldb, sqlite's shell, postgresql's psql can use it). autotools, ncurses.
  libedit = mkSrcPkg {
    pname = "libedit"; version = "20260508-3.1";
    src = { url = "https://thrysoee.dk/editline/libedit-20260508-3.1.tar.gz";
            sha256 = "91f42d6571dd8d92faedd1341134ce5abca0c5d0b4b352814186d33f2b11272e"; };
    deps = [ world ncurses ]; nativeTools = hostTools;
    build = ''
      # sys.h, terminal.h and terminal.c each declare Solaris' old termcap prototypes (tgetflag(char *), ...) under __sun; ncurses'
      # <termcap.h> (HAVE_TERMCAP_H) declares them const, and gcc 14 errors on the conflict (measured): the __sun blocks only without it
      for f in src/sys.h src/terminal.h src/terminal.c; do
        grep -qE '^#(if defined\(__sun\)|ifdef __sun)$' $f || { echo "FATAL: libedit $f __sun anchor" >&2; exit 1; }
        sed -i -E 's/^#(if defined\(__sun\)|ifdef __sun)$/#if defined(__sun) \&\& !defined(HAVE_TERMCAP_H)/' $f
      done
      ./configure --prefix="$out" --libdir="$out/lib/amd64" --disable-static CPPFLAGS="-I${ncurses}/include/ncursesw -I${ncurses}/include -D__EXTENSIONS__" LIBS="-lncursesw"
      gmake -j8; gmake install
      ${tprog ''#include <histedit.h>
#include <stdio.h>
int main(void){HistEvent e; History *h=history_init(); history(h,&e,H_SETSIZE,10); history(h,&e,H_ENTER,"solnix line");
if(history(h,&e,H_FIRST)<0) return 1; printf("%s\n",e.str); history_end(h); return 0;}'' "c" "$CC" "-ledit -lncursesw"}
      ${chk ''"$W/t"'' "^solnix line$"}
    '';
  };

  # cJSON (MIT): a small C JSON parser (mosquitto, libfido2 tooling). cmake, shared.
  cjson = mkSrcPkg {
    pname = "cjson"; version = "1.7.19";
    src = gh "DaveGamble/cJSON" "v1.7.19" "7fa616e3046edfa7a28a32d5f9eacfd23f92900fe1f8ccd988c1662f30454562";
    deps = [ world ]; nativeTools = [ cmake ] ++ hostTools;
    build = ''
      # its custom flags add -fstack-protector-strong, which NEEDs libssp.so.0: gcc.lib ships no libssp (as nvi2.nix): off
      grep -q -- '-fstack-protector-strong' CMakeLists.txt || { echo "FATAL: cjson ssp anchor" >&2; exit 1; }
      sed -i '/-fstack-protector-strong/d' CMakeLists.txt
      ${cmakeB "-DBUILD_SHARED_LIBS=ON -DENABLE_CJSON_TEST=OFF -DENABLE_CJSON_UTILS=ON -DCMAKE_POLICY_VERSION_MINIMUM=3.5"}
      ${tprog ''#include <cjson/cJSON.h>
#include <stdio.h>
int main(void){cJSON *j=cJSON_Parse("{\"a\":[1,2,42]}"); if(!j) return 1; printf("%d\n", cJSON_GetArrayItem(cJSON_GetObjectItem(j,"a"),2)->valueint); cJSON_Delete(j); return 0;}'' "c" "$CC" "-lcjson"}
      ${chk ''"$W/t"'' "^42$"}
    '';
  };

  # TinyXML-2 (Zlib): a small C++ XML parser. cmake, shared, as nixpkgs.
  tinyxml-2 = mkSrcPkg {
    pname = "tinyxml-2"; version = "11.0.0";
    src = gh "leethomason/tinyxml2" "11.0.0" "5556deb5081fb246ee92afae73efd943c889cef0cafea92b0b82422d6a18f289";
    deps = [ world ]; nativeTools = [ cmake ] ++ hostTools;
    build = ''
      ${cmakeB "-DBUILD_SHARED_LIBS=ON -Dtinyxml2_BUILD_TESTING=OFF"}
      ${tprog ''#include <tinyxml2.h>
#include <cstdio>
int main(){tinyxml2::XMLDocument d; if(d.Parse("<a><b n=\"42\"/></a>")) return 1; std::printf("%d\n", d.FirstChildElement("a")->FirstChildElement("b")->IntAttribute("n")); return 0;}'' "cc" "$CXX" "-ltinyxml2"}
      ${chk ''"$W/t"'' "^42$"}
    '';
  };

  # OpenCL-Headers (Apache-2.0): the Khronos OpenCL C headers (ocl-icd, mesa's rusticl, pocl). Header-only; cmake installs them.
  opencl-headers = mkSrcPkg {
    pname = "opencl-headers"; version = "2026.05.29";
    src = gh "KhronosGroup/OpenCL-Headers" "v2026.05.29" "d9e6c48357de5002da11ce45de600e0c3ffe6ab4f628a3b9fe2b38603161658a";
    deps = [ world ]; nativeTools = [ cmake ] ++ hostTools;
    build = ''
      ${cmakeB "-DBUILD_TESTING=OFF"}
      [ -f "$out/include/CL/cl.h" ] && grep -q CL_VERSION_3_0 "$out/include/CL/cl.h" || { echo "FATAL: opencl-headers" >&2; exit 1; }
      printf '#include <CL/cl.h>\nint main(void){return CL_SUCCESS;}\n' > "$W/t.c"; "$CC" -I"$out/include" -c "$W/t.c" -o "$W/t.o"
    '';
  };

  # termcolor (BSD-3-Clause): a header-only C++ library for colored terminal output. cmake installs the header + config.
  termcolor = mkSrcPkg {
    pname = "termcolor"; version = "2.1.0";
    src = gh "ikalnytskyi/termcolor" "v2.1.0" "435994c32557674469404cb1527c283fdcf45746f7df75fd2996bb200d6a759f";
    deps = [ world ]; nativeTools = [ cmake ] ++ hostTools;
    build = ''
      ${cmakeB "-DTERMCOLOR_TESTS=OFF -DCMAKE_POLICY_VERSION_MINIMUM=3.5"}
      ${tprog ''#include <termcolor/termcolor.hpp>
#include <iostream>
int main(){ std::cout << termcolor::colorize << termcolor::red << "red" << termcolor::reset << std::endl; return 0; }'' "cc" "$CXX" ""}
      ${chk ''"$W/t" | od -c | head -2'' "033"}
    '';
  };

  # check (LGPL-2.1+): a unit test framework for C. autotools (no subunit), as nixpkgs.
  check = mkSrcPkg {
    pname = "check"; version = "0.15.2";
    src = { url = "https://github.com/libcheck/check/releases/download/0.15.2/check-0.15.2.tar.gz";
            sha256 = "a8de4e0bacfb4d76dd1c618ded263523b53b85d92a146d8835eb1a52932fa20a"; };
    deps = [ world ]; nativeTools = hostTools;
    build = ''
      ./configure --prefix="$out" --libdir="$out/lib/amd64" --disable-static --disable-subunit --disable-build-docs
      gmake -j8; gmake install
      find "$out/share/doc" -delete 2>/dev/null || true
      ${tprog ''#include <check.h>
#include <stdlib.h>
START_TEST(t1){ ck_assert_int_eq(1+1, 2); } END_TEST
int main(void){Suite *s=suite_create("s"); TCase *c=tcase_create("c"); tcase_add_test(c,t1); suite_add_tcase(s,c);
SRunner *r=srunner_create(s); srunner_set_fork_status(r, CK_NOFORK); srunner_run_all(r, CK_NORMAL); int f=srunner_ntests_failed(r); srunner_free(r); return f;}'' "c" "$CC" "-lcheck -lm"}
      ${chk ''"$W/t"'' "100%: Checks: 1, Failures: 0, Errors: 0"}
    '';
  };

  # popt (MIT): command-line option parsing (rsync, logrotate, cryptsetup). autotools.
  popt = mkSrcPkg {
    pname = "popt"; version = "1.19";
    src = { url = "https://ftp.osuosl.org/pub/rpm/popt/releases/popt-1.x/popt-1.19.tar.gz";
            sha256 = "c25a4838fc8e4c1c8aacb8bd620edb3084a3d63bf8987fdad3ca2758c63240f9"; };
    deps = [ world ]; nativeTools = hostTools;
    build = ''
      # poptint.c passes char ** as iconv's input buffer; the gate's <iconv.h> (XPG6) takes const char **, and gcc 14 makes the
      # mismatch an error (measured; GNU libiconv's header is const too). The pre-gcc-14 warning, as packages.nix's tputsFix.
      ./configure --prefix="$out" --libdir="$out/lib/amd64" --disable-static --disable-nls CFLAGS="-O2 -Wno-error=incompatible-pointer-types"
      gmake -j8; gmake install
      ${tprog ''#include <popt.h>
#include <stdio.h>
int main(int c, const char **v){int n=0; struct poptOption o[]={{"num",'n',POPT_ARG_INT,&n,0,"n",NULL},POPT_TABLEEND};
poptContext x=poptGetContext(NULL,c,v,o,0); while(poptGetNextOpt(x)>0); printf("n=%d\n",n); poptFreeContext(x); return 0;}'' "c" "$CC" "-lpopt"}
      ${chk ''"$W/t" --num 42'' "^n=42$"}
    '';
  };

  # libev (BSD-2-Clause): an event loop (its event-port backend is the Solaris one). autotools.
  libev = mkSrcPkg {
    pname = "libev"; version = "4.33";
    src = { url = "https://dist.schmorp.de/libev/Attic/libev-4.33.tar.gz";
            sha256 = "507eb7b8d1015fbec5b935f34ebed15bf346bed04a11ab82b8eee848c4205aea"; };
    deps = [ world ]; nativeTools = hostTools;
    build = ''
      ./configure --prefix="$out" --libdir="$out/lib/amd64" --disable-static
      gmake -j8; gmake install
      # its ev.h is also the name of libevent's compat header: nixpkgs ships it as is (no event.h shim conflict here: none installed)
      ${tprog ''#include <ev.h>
#include <stdio.h>
static int n; static void cb(EV_P_ ev_timer *w, int r){ n++; ev_break(EV_A_ EVBREAK_ALL); }
int main(void){ struct ev_loop *l = ev_default_loop(0); ev_timer t; ev_timer_init(&t, cb, 0.01, 0.); ev_timer_start(l, &t); ev_run(l, 0);
printf("libev %d.%d backend %u timer %d\n", ev_version_major(), ev_version_minor(), ev_backend(l), n); return n != 1; }'' "c" "$CC" "-lev"}
      ${chk ''"$W/t"'' "^libev 4\\.33 backend [0-9]+ timer 1$"}
    '';
  };

  # c-ares (MIT): async DNS (curl, nodejs, grpc). cmake, shared, tests off.
  c-ares = mkSrcPkg {
    pname = "c-ares"; version = "1.34.4";
    src = { url = "https://github.com/c-ares/c-ares/releases/download/v1.34.4/c-ares-1.34.4.tar.gz";
            sha256 = "fa38dbed659ee4cc5a32df5e27deda575fa6852c79a72ba1af85de35a6ae222f"; };
    deps = [ world ]; nativeTools = [ cmake ] ++ hostTools;
    build = ''
      ${cmakeB "-DCARES_SHARED=ON -DCARES_STATIC=OFF -DCARES_BUILD_TESTS=OFF -DCARES_BUILD_TOOLS=ON"}
      ${tprog ''#include <ares.h>
#include <stdio.h>
int main(void){ if(ares_library_init(ARES_LIB_INIT_ALL)) return 1; ares_channel_t *c; if(ares_init(&c) != ARES_SUCCESS) return 1;
printf("c-ares %s\n", ares_version(NULL)); ares_destroy(c); ares_library_cleanup(); return 0; }'' "c" "$CC" "-lcares"}
      ${chk ''"$W/t"'' "^c-ares 1\\.34\\.4$"}
    '';
  };

  # libssh2 (BSD-3-Clause): the SSH2 client library (curl's sftp/scp, libgit2). autotools, OpenSSL + zlib.
  libssh2 = mkSrcPkg {
    pname = "libssh2"; version = "1.11.1";
    src = { url = "https://www.libssh2.org/download/libssh2-1.11.1.tar.gz";
            sha256 = "d9ec76cbe34db98eec3539fe2c899d26b0c837cb3eb466a56b0f109cabf658f7"; };
    deps = [ world openssl zlib ]; nativeTools = hostTools;
    build = ''
      ./configure --prefix="$out" --libdir="$out/lib/amd64" --disable-static --with-crypto=openssl --with-libssl-prefix=${openssl} \
        --with-libz --disable-examples-build --disable-tests
      gmake -j8; gmake install
      ${tprog ''#include <libssh2.h>
#include <stdio.h>
int main(void){ if(libssh2_init(0)) return 1; LIBSSH2_SESSION *s = libssh2_session_init(); if(!s) return 1;
printf("libssh2 %s\n", libssh2_version(0)); libssh2_session_free(s); libssh2_exit(); return 0; }'' "c" "$CC" "-lssh2"}
      ${chk ''"$W/t"'' "^libssh2 1\\.11\\.1$"}
    '';
  };

  # cmocka (Apache-2.0): a unit test framework for C with mock objects. cmake, shared.
  cmocka = mkSrcPkg {
    pname = "cmocka"; version = "2.0.2";
    src = { url = "https://cmocka.org/files/2.0/cmocka-2.0.2.tar.xz";
            sha256 = "39f92f366bdf3f1a02af4da75b4a5c52df6c9f7e736c7d65de13283f9f0ef416"; };
    deps = [ world ]; nativeTools = [ cmake ] ++ hostTools;
    build = ''
      # CompilerChecks.cmake adds -fstack-protector(-strong) when the compiler takes it, which NEEDs libssp.so.0 (no libssp in gcc.lib)
      grep -q 'check_c_compiler_flag_ssp("-fstack-protector-strong"' CompilerChecks.cmake || { echo "FATAL: cmocka ssp anchor" >&2; exit 1; }
      sed -i 's/check_c_compiler_flag_ssp("-fstack-protector[-a-z]*" \(WITH_STACK_PROTECTOR[A-Z_]*\))/set(\1 FALSE)/' CompilerChecks.cmake
      ${cmakeB "-DBUILD_SHARED_LIBS=ON -DUNIT_TESTING=OFF -DWITH_EXAMPLES=OFF"}
      ${tprog ''#include <stdarg.h>
#include <stddef.h>
#include <stdint.h>
#include <setjmp.h>
#include <cmocka.h>
static void t(void **s){ (void)s; assert_int_equal(1+1, 2); }
int main(void){ const struct CMUnitTest ts[] = { cmocka_unit_test(t) }; return cmocka_run_group_tests(ts, NULL, NULL); }'' "c" "$CC" "-lcmocka"}
      ${chk ''"$W/t" 2>&1'' "PASSED.*1 test"}
    '';
  };

  # utfcpp (BSL-1.0): header-only UTF-8 helpers for C++ (taglib, kodi). cmake installs the headers + config.
  utf8cpp = mkSrcPkg {
    pname = "utf8cpp"; version = "4.2.1";
    src = gh "nemtrif/utfcpp" "v4.2.1" "6d6a5493a111884cc085ee31babfe6d9960c8fb08fc80a64852eaeea8323dbc1";
    deps = [ world ]; nativeTools = [ cmake ] ++ hostTools;
    build = ''
      ${cmakeB "-DUTF8_TESTS=OFF -DUTF8_SAMPLES=OFF"}
      ${tprog ''#include <utf8cpp/utf8.h>
#include <cstdio>
#include <string>
int main(){ std::string s = "\xc3\xa9t\xc3\xa9"; std::printf("%d %d\n", (int)utf8::distance(s.begin(), s.end()), utf8::is_valid(s.begin(), s.end()) ? 1 : 0); return 0; }'' "cc" "$CXX" ""}
      ${chk ''"$W/t"'' "^3 1$"}
    '';
  };
}
