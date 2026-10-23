# pkgs.solnix.bsdfetch -- FreeBSD fetch(1) with libfetch(3) linked in: the maintainer-required
# "BSD fetch". Source: src/ports/bsdfetch/upstream, vendored unmodified from freebsd-src
# e48eb1c5 (PROVENANCE.md: the two directories are ~200 KB, the only upstream tarball is the
# whole 344 MB tree). Compiled directly, with one force-included shim header
# (shims/bsdfetch-illumos.h) in place of FreeBSD's bsd.lib.mk. TLS through the from-source
# openssl (-DWITH_SSL), as FreeBSD's default build. libfetch is FreeBSD-private API that
# nothing else here uses, so it is linked statically into fetch(1).
{ gate, gccWrapper, openssl, libcSlice
, system ? "x86_64-solaris"
, fetchSrc ? builtins.path { path = ../../src/ports/bsdfetch; name = "bsdfetch-src"; }
}:
derivation {
  name = "bsdfetch-14-e48eb1c5";
  inherit system gate gccWrapper openssl fetchSrc;
  libcDir = "${libcSlice}/lib/amd64";
  builder = "/usr/bin/bash";
  PATH = "/usr/gnu/bin:/usr/bin:/usr/sbin";
  args = [ "-c" ''
    set -eu
    export PATH=/usr/gnu/bin:/usr/bin:/usr/sbin
    W=$(mktemp -d /var/tmp/bsdfetch.XXXXXX); cp -r "$fetchSrc"/. "$W"/; chmod -R u+w "$W"
    L="$W/upstream/lib/libfetch"; F="$W/upstream/usr.bin/fetch"
    # The one source change: BSD sockaddrs carry sin_len/ss_len, illumos's do not.
    # Guard TCP_NOPUSH/IP_PORTRANGE (FreeBSD-only socket options) the way upstream already guards
    # IPV6_PORTRANGE, drop sin_len/ss_len, and default the CA bundle to the system's
    # /etc/ssl/certs/ca-certificates.crt (openssl's compiled-in default is an empty store path).
    for p in "$W"/patches/*.patch; do ( cd "$W/upstream" && patch -p1 --fuzz=0 < "$p" ) >&2; done
    grep -q 'ss_len' "$L/ftp.c" && { echo "FATAL: ftp.c still reads ss_len" >&2; exit 1; }
    cd "$L"
    # ftperr.h / httperr.h: generated from the .errors tables exactly as libfetch/Makefile does.
    for t in ftp http; do
      U=$(echo $t | tr a-z A-Z)
      { echo "static struct fetcherr ''${t}_errlist[] = {"
        grep -v '^#' $t.errors | sort | while read NUM CAT STRING; do
          echo "    { $NUM, FETCH_$CAT, \"$STRING\" },"
        done
        echo "    { -1, FETCH_UNKNOWN, \"Unknown $U error\" }"
        echo "};"; } > ''${t}err.h
    done
    CC="$gccWrapper/bin/gcc"
    RP="$openssl/lib/amd64:$libcDir"
    CF="-m64 -O2 -std=gnu99 -include $W/shims/bsdfetch-illumos.h -I$W/shims -I$L -I$openssl/include
        -DWITH_SSL -DOPENSSL_API_COMPAT=0x10100000L -DINET6 -DFTP_COMBINE_CWDS"
    for s in fetch common ftp http file; do $CC $CF -c $s.c -o $s.o; done
    # funopen(3) for illumos (no funopen, no fopencookie): shims/funopen.c.
    $CC $CF -c "$W/shims/funopen.c" -o funopen.o
    ar rcs libfetch.a fetch.o common.o ftp.o http.o file.o funopen.o
    cd "$F"
    $CC $CF -c fetch.c -o fetch.o
    $CC -m64 -o fetch fetch.o "$L/libfetch.a" -L"$openssl/lib/amd64" \
      -lssl -lcrypto -lsocket -lnsl -lresolv -lmd -lpthread -Wl,-R,"$RP"
    mkdir -p "$out/bin" "$out/share/man/man1" "$out/share/man/man3"
    cp fetch "$out/bin/fetch"; cp fetch.1 "$out/share/man/man1/fetch.1"
    cp "$L/fetch.3" "$out/share/man/man3/fetch.3"
    # Gates: links only into the store; runs; reads a file:// URL end to end.
    unset LD_LIBRARY_PATH LD_LIBRARY_PATH_64 LD_LIBRARY_PATH_32 || true
    bad=$(/usr/bin/ldd "$out/bin/fetch" 2>&1 | awk '/not found/ || (/=>/ && $NF !~ /^\/(nix\/store|lib|usr\/lib)\//)')
    [ -z "$bad" ] || { echo "FATAL: fetch links outside the store/system: $bad" >&2; exit 1; }
    "$out/bin/fetch" 2>&1 | grep -qi usage || { echo "FATAL: fetch prints no usage" >&2; exit 1; }
    echo "bsdfetch file:// self-test" > "$W/in.txt"
    "$out/bin/fetch" -q -o "$W/out.txt" "file://$W/in.txt"
    cmp -s "$W/in.txt" "$W/out.txt" || { echo "FATAL: fetch file:// round-trip differs" >&2; exit 1; }
    "$out/bin/fetch" -q -o "$W/none.txt" "file://$W/no-such-file" 2>/dev/null \
      && { echo "FATAL: fetch of a missing file reported success (negative control)" >&2; exit 1; }
    # http:// through the funopen shim: a one-shot HTTP/1.0 server on loopback (bash /dev/tcp
    # is client-only, so the server is a tiny perl, present on the build host as on OI).
    if command -v perl >/dev/null 2>&1; then
      body="bsdfetch http self-test $(date +%s)"
      printf '%s\n' "$body" > "$W/www.txt"
      perl -MIO::Socket::INET -e '
        my $s = IO::Socket::INET->new(LocalAddr => "127.0.0.1", LocalPort => 0, Listen => 1, ReuseAddr => 1) or die;
        open(my $pf, ">", $ARGV[1]) or die; print $pf $s->sockport, "\n"; close $pf;
        my $c = $s->accept or die; while (<$c>) { last if /^\r?$/ }
        open(my $f, "<", $ARGV[0]) or die; local $/; my $d = <$f>;
        print $c "HTTP/1.0 200 OK\r\nContent-Length: " . length($d) . "\r\nContent-Type: text/plain\r\n\r\n" . $d;
        close $c;' "$W/www.txt" "$W/port" &
      for i in 1 2 3 4 5 6 7 8 9 10; do [ -s "$W/port" ] && break; sleep 0.5; done
      port=$(cat "$W/port")
      "$out/bin/fetch" -q -o "$W/http-out.txt" "http://127.0.0.1:$port/www.txt"
      cmp -s "$W/www.txt" "$W/http-out.txt" || { echo "FATAL: fetch http:// round-trip differs" >&2; exit 1; }
      wait
      echo "bsdfetch: http:// round-trip ok (port $port)" >&2
    fi
    echo "bsdfetch: built, links clean, file:// round-trip ok, missing-file negative control ok" >&2
  '' ];
}
