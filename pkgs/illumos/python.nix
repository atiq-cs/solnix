# python.nix -- nixpkgs' Python packaging on mk-src-pkg (py1): the PyPA bootstrap set and buildPythonPackage, the shape of nixpkgs
# f4a03c0's pkgs/development/interpreters/python/mk-python-derivation.nix + hooks/ (pypa-build, pypa-install, python-imports-check,
# python-runtime-deps-check, wrapPythonPrograms) and python-modules/bootstrap/. No pip, no network: every source is a pinned tarball.
#  - bootstrap (nixpkgs bootstrap/): flit-core builds its own wheel and bootstrap_install.py unpacks it; installer, packaging,
#    pyproject-hooks and build are `python -m flit_core.wheel` + `python -m installer` (installer runs from its own src/).
#  - buildPythonPackage: `pyproject-build --no-isolation --wheel` (pypaBuildHook) with build-system + dependencies on PYTHONPATH, then `python -m installer --prefix $out --executable <python3>` (pypaInstallHook, nixpkgs' cross.patch), then
#    ./python-fixup.py: pyc (checked-hash only, as c-dev.nix's python3), wrap (bin scripts get the site.addsitedir preamble), deps.
#    buildPythonApplication = the same with no "python3.13-" name prefix (nixpkgs: an application's drv name is pname-version).
# Bytecode: installer compiles levels 0 and 1 (its default, as nixpkgs); SOURCE_DATE_EPOCH (mk-src-pkg) makes py_compile write
# checked-hash pyc, PYTHONHASHSEED=0 (nixpkgs python setup-hook) fixes set ordering in the marshalled constants.
# Runtime dependencies: a package's pyClosure (eval time; nixpkgs: propagated-build-inputs), whose site-packages its bin scripts add.
# shortcut: wrap patches the script in place (nixpkgs' wrap.sh preamble) and adds no bash wrapper (makeWrapper: PATH/extra args); add
# one when a leaf needs its dependencies' bin/ on PATH or makeWrapperArgs.
{ mkSrcPkg, python3, hostTools, gnupatch, chk }:
let
  py = "${python3}/bin/python3";
  site = "lib/python3.13/site-packages";
  fix = ./python-fixup.py;
  sitesOf = ds: builtins.concatStringsSep " " (map (d: "${d}/${site}") ds);
  pathOf = ds: builtins.concatStringsSep ":" (map (d: "${d}/${site}") ds);
  # ds and their pyClosures, each once, dependencies first
  closure = ds: builtins.foldl' (acc: d: if builtins.elem d acc then acc else acc ++ [ d ]) [ ]
    (builtins.concatMap (d: (d.pyClosure or [ ]) ++ [ d ]) ds);
  env = "export PYTHONHASHSEED=0 PYTHONNOUSERSITE=1 DETERMINISTIC_BUILD=1 PYTHONDONTWRITEBYTECODE=1";
  # pythonImportsCheck + the fixups, for an out whose runtime closure is rt
  post = rt: mods: ''
    ${py} ${fix} pyc "$out"
    ${py} ${fix} wrap "$out" "$out/${site}" ${sitesOf rt}
    ${if mods == [ ] then "" else ''
    ( cd "$out" && PYTHONPATH="$out/${site}${if rt == [ ] then "" else ":" + pathOf rt}" ${py} -c \
        'import importlib, sys; [importlib.import_module(m) for m in sys.argv[1:]]' ${builtins.concatStringsSep " " mods} ) \
      || { echo "FATAL: pythonImportsCheck failed" >&2; exit 1; }
    echo "IMPORTS-OK: ${builtins.concatStringsSep " " mods}" >&2''}
  '';
  withClosure = deps: d: d // { pyClosure = closure deps; };

  # nixpkgs bootstrap/: flit_core.wheel builds the wheel, installer installs it
  flitPkg = { pname, version, src, deps ? [ ], prep ? "", installerPath ? "${installer}/${site}", imports, check }: withClosure deps (mkSrcPkg {
    pname = "python3.13-${pname}"; inherit version src;
    nativeTools = hostTools ++ [ gnupatch ];
    build = ''
      ${env}
      ${prep}
      PYTHONPATH="${flit-core}/${site}" ${py} -m flit_core.wheel --outdir dist
      PYTHONPATH="${installerPath}" ${py} -m installer --prefix "$out" --executable ${py} dist/*.whl
      ${post (closure deps) imports}
      ${check}
    '';
  });

  # flit-core 3.12.0 (BSD-3-Clause): PEP 517 backend with no dependencies; builds and installs itself (bootstrap_install.py)
  flit-core = mkSrcPkg {
    pname = "python3.13-flit-core"; version = "3.12.0";
    src = { url = "https://github.com/pypa/flit/archive/refs/tags/3.12.0.tar.gz"; sha256 = "c157ff92c01f4bb169182722ff76aadac113926b729215e91909021aa56e2ea3"; };
    nativeTools = hostTools;
    build = ''
      ${env}
      cd flit_core
      ${py} -m flit_core.wheel --outdir dist
      ${py} bootstrap_install.py dist/flit_core-*.whl --installdir "$out/${site}"
      ${py} -m compileall -q -f -j1 -o 0 -o 1 "$out/${site}" >/dev/null
      ${post [ ] [ "flit_core" "flit_core.buildapi" ]}
      ${chk ''PYTHONPATH="$out/${site}" ${py} -c "import flit_core; print(flit_core.__version__)"'' "^3\\.12\\.0$"}
    '';
  } // { pyClosure = [ ]; };

  # installer 1.0.1 (MIT): installs a wheel; nixpkgs' cross.patch adds --executable (the #! of generated scripts)
  installer = flitPkg {
    pname = "installer"; version = "1.0.1";
    src = { url = "https://github.com/pypa/installer/archive/refs/tags/1.0.1.tar.gz"; sha256 = "391b8068eb6b5629496a71e33b948b10c31bea77a12d302034323406ee03ffd1"; };
    prep = "patch -p1 < ${./patches/installer-1.0.1-cross.patch}"; installerPath = "src";
    imports = [ "installer" "installer.__main__" ];
    check = chk ''PYTHONPATH="$out/${site}" ${py} -m installer --help'' "[-]-executable";
  };

  # packaging 26.3 (Apache-2.0 OR BSD-2-Clause): version/specifier/marker parsing (a new attr: the served graphics.packaging 24.1 stays)
  packaging = flitPkg {
    pname = "packaging"; version = "26.3";
    src = { url = "https://files.pythonhosted.org/packages/7d/fa/3944b40b07da9ce895c0e6303a5ab7d53da063554f534556b134a54d6093/packaging-26.3.tar.gz";
            sha256 = "94edc256424af38762eb31306eed28beb9f0efc50a8837492c9d6fd6004aed79"; };
    imports = [ "packaging" "packaging.metadata" "packaging.requirements" "packaging.specifiers" "packaging.tags" "packaging.version" ];
    check = chk ''PYTHONPATH="$out/${site}" ${py} -c "import packaging; print(packaging.__version__)"'' "^26\\.3$";
  };

  # pyproject-hooks 1.2.0 (MIT): calls a PEP 517 backend in a subprocess
  pyproject-hooks = flitPkg {
    pname = "pyproject-hooks"; version = "1.2.0";
    src = { url = "https://files.pythonhosted.org/packages/e7/82/28175b2414effca1cdac8dc99f76d660e7a4fb0ceefa4b4ab8f5f6742925/pyproject_hooks-1.2.0.tar.gz";
            sha256 = "1e859bd5c40fae9448642dd871adf459e5e2084186e8d2c2a79a824c970da1f8"; };
    imports = [ "pyproject_hooks" ];
    check = chk ''PYTHONPATH="$out/${site}" ${py} -c "import pyproject_hooks; print(pyproject_hooks.__version__)"'' "^1\\.2\\.0$";
  };

  # build 1.5.1 (MIT): the PEP 517 frontend (pyproject-build); its bin script adds packaging + pyproject-hooks (nixpkgs wraps it)
  build = flitPkg {
    pname = "build"; version = "1.5.1";
    src = { url = "https://github.com/pypa/build/archive/refs/tags/1.5.1.tar.gz"; sha256 = "5a2a17d683cc597aa1930b28d824993f8077ce608e14a07c2cfb8c5565ee51b5"; };
    deps = [ packaging pyproject-hooks ];
    imports = [ "build" "build.__main__" ];
    check = chk ''"$out/bin/pyproject-build" --version'' "^build 1\\.5\\.1 ";
  };

  buildPythonPackage = { pname, version, src, build-system ? [ ], dependencies ? [ ], pythonImportsCheck ? [ ], prep ? "", postInstall ? "",
                         check ? "", namePrefix ? "python3.13-", nativeTools ? [ ] }:
    let rt = closure dependencies; in withClosure dependencies (mkSrcPkg {
      pname = "${namePrefix}${pname}"; inherit version src;
      nativeTools = hostTools ++ [ gnupatch ] ++ nativeTools;
      build = ''
        ${env}
        ${prep}
        PYSRC=$(pwd)
        # pypaBuildHook: pyproject-build --no-isolation --outdir dist/ --wheel (its dependency check reads build-system's dist-info;
        # the backend runs in a subprocess, so build-system goes on PYTHONPATH)
        PYTHONPATH="${pathOf (closure (build-system ++ dependencies))}" ${build}/bin/pyproject-build --no-isolation --outdir dist --wheel
        # pypaInstallHook
        PYTHONPATH="${installer}/${site}" ${py} -m installer --prefix "$out" --executable ${py} "$PYSRC"/dist/*.whl
        ${postInstall}
        ${post rt pythonImportsCheck}
        # pythonRuntimeDepsCheckHook: every Requires-Dist (markers evaluated) is in the runtime closure at a matching version
        PYTHONPATH="${packaging}/${site}" ${py} ${fix} deps "$PYSRC"/dist/*.whl "$out/${site}" ${sitesOf rt} \
          || { echo "FATAL: python runtime dependencies not satisfied" >&2; exit 1; }
        ${check}
      '';
    });
  buildPythonApplication = a: buildPythonPackage ({ namePrefix = ""; } // a);

  # wheel 0.47.0 (MIT): the bdist_wheel command and `wheel` tool
  wheel = buildPythonPackage {
    pname = "wheel"; version = "0.47.0";
    src = { url = "https://github.com/pypa/wheel/archive/refs/tags/0.47.0.tar.gz"; sha256 = "7077424e2d404e5ed1c1be5075b05afa1807ccf251939a5e753567fdcfcd7a58"; };
    build-system = [ flit-core ]; dependencies = [ packaging ];
    pythonImportsCheck = [ "wheel" ];
    check = chk ''"$out/bin/wheel" version'' "^wheel 0\\.47\\.0";
  };

  # setuptools 83.0.0 (MIT): builds itself (backend-path "."); nixpkgs' reproducible-wheel.patch pins version.py
  setuptools = buildPythonPackage {
    pname = "setuptools"; version = "83.0.0";
    src = { url = "https://github.com/pypa/setuptools/archive/refs/tags/v83.0.0.tar.gz"; sha256 = "188917862e785dc039fbc353b809ff185237411101fa270241034a6ec0e4f44b"; };
    prep = ''
      patch -p1 < ${./patches/setuptools-83-reproducible-wheel.patch}
      sed -i "/coherent.licensed/d" pyproject.toml
      sed -i "s/@version@/83.0.0/" setuptools/version.py; grep -q "'83.0.0'" setuptools/version.py || { echo "FATAL: version.py" >&2; exit 1; }
      export SETUPTOOLS_INSTALL_WINDOWS_SPECIFIC_FILES=0
    '';
    pythonImportsCheck = [ "setuptools" "setuptools.build_meta" ];
    check = chk ''PYTHONPATH="$out/${site}" ${py} -c "import setuptools; print(setuptools.__version__)"'' "^83\\.0\\.0$";
  };
in { inherit flit-core installer packaging pyproject-hooks build wheel setuptools buildPythonPackage buildPythonApplication; }
