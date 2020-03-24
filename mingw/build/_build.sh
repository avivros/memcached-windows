#!/bin/sh -ex

# Requirements (not a comprehensive list at this point):
#   Windows:
#     MSYS2: zip zstd mingw-w64-{i686,x86_64}-{clang,jq,osslsigncode,python3-pip} gpg python3
#   Linux
#     zip zstd binutils-mingw-w64 gcc-mingw-w64 gnupg-curl jq osslsigncode dos2unix realpath wine
#   Mac:
#     brew install xz zstd gnu-tar mingw-w64 jq osslsigncode dos2unix gpg gnu-sed wine

cd "$(dirname "$0")" || exit

LC_ALL=C
LC_MESSAGES=C
LANG=C

readonly _LOG='logurl.txt'
if [ -n "${APPVEYOR_ACCOUNT_NAME}" ]; then
  _LOGURL="https://ci.appveyor.com/project/${APPVEYOR_ACCOUNT_NAME}/${APPVEYOR_PROJECT_SLUG}/build/${APPVEYOR_BUILD_VERSION}/job/${APPVEYOR_JOB_ID}"
# _LOGURL="https://ci.appveyor.com/api/buildjobs/${APPVEYOR_JOB_ID}/log"
elif [ -n "${TRAVIS_REPO_SLUG}" ]; then
  _LOGURL="https://travis-ci.org/${TRAVIS_REPO_SLUG}/jobs/${TRAVIS_JOB_ID}"
# _LOGURL="https://api.travis-ci.org/v3/job/${TRAVIS_JOB_ID}/log.txt"
else
  # TODO: https://docs.gitlab.com/ce/ci/variables/README.html
  _LOGURL=''
fi
echo "${_LOGURL}" | tee "${_LOG}"

# export _BRANCH="${APPVEYOR_REPO_BRANCH}${TRAVIS_BRANCH}${CI_COMMIT_REF_NAME}${GIT_BRANCH}"
# [ -n "${_BRANCH}" ] || _BRANCH="$(git symbolic-ref --short --quiet HEAD)"
# [ -n "${_BRANCH}" ] || _BRANCH='master'
export _BRANCH=master

export _URL=''
command -v git >/dev/null 2>&1 && _URL="$(git ls-remote --get-url | sed 's|.git$||')"
[ -n "${_URL}" ] || _URL="https://github.com/${APPVEYOR_REPO_NAME}${TRAVIS_REPO_SLUG}"

# Detect host OS
export os
case "$(uname)" in
  *_NT*)   os='win';;
  Linux*)  os='linux';;
  Darwin*) os='mac';;
  *BSD)    os='bsd';;
esac

export PUBLISH_PROD_FROM
[ "${APPVEYOR_REPO_PROVIDER}" = 'gitHub' ] && PUBLISH_PROD_FROM='linux'

unset _ALLSUFF
# Upload Travis/Linux builds too as a test
if [ "$TRAVIS_OS_NAME" = 'linux' ]; then
  PUBLISH_PROD_FROM="${os}"
  _ALLSUFF=".travis-${os}"
fi

export _BLD='build.txt'

rm -f ./*-*-mingw*.*
rm -f hashes.txt
rm -f "${_BLD}"

. ./_dl.sh || exit 1

# decrypt code signing key
export CODESIGN_KEY=
CODESIGN_KEY="$(realpath '.')/codesign.p12"
if [ -f "${CODESIGN_KEY}.asc" ]; then
  (
    set +x
    if [ -n "${CODESIGN_GPG_PASS}" ]; then
      install -m 600 /dev/null "${CODESIGN_KEY}"
      gpg --batch --passphrase "${CODESIGN_GPG_PASS}" -d "${CODESIGN_KEY}.asc" >> "${CODESIGN_KEY}"
    fi
  )
fi
[ -f "${CODESIGN_KEY}" ] || unset CODESIGN_KEY

if [ -f "${CODESIGN_KEY}" ]; then
  # build a patched binary of osslsigncode
  ./osslsigncode.sh
fi

ls -l "$(dirname "$0")/osslsigncode-determ"*

case "${os}" in
  mac) alias sed=gsed;;
esac

if [ "${CC}" = 'mingw-clang' ]; then
  echo ".clang$("clang${_CCSUFFIX}" --version | grep -o -E ' [0-9]*\.[0-9]*[\.][0-9]*')" >> "${_BLD}"
fi

case "${os}" in
  mac)   ver="$(brew info --json=v1 mingw-w64 | jq -r '.[] | select(.name == "mingw-w64") | .versions.stable')";;
  # FIXME: Linux-distro specific
  linux) ver="$(apt-cache show mingw-w64 | grep '^Version:' | cut -c 10-)";;
  *)     ver='';;
esac
[ -n "${ver}" ] && echo ".mingw-w64 ${ver}" >> "${_BLD}"

_ori_path="${PATH}"

build_single_target() {
  _cpu="$1"

  unset CC
  export _TRIPLET=
  export _SYSROOT=
  export _CCPREFIX=
  export _MAKE='make'
  export _WINE=''

  [ "${_cpu}" = '32' ] && _machine='i686'
  [ "${_cpu}" = '64' ] && _machine='x86_64'

  if [ "${os}" = 'win' ]; then
    export PATH="/mingw${_cpu}/bin:${_ori_path}"
    export _MAKE='mingw32-make'

    # Install required component
    # TODO: add `--progress-bar off` when pip 10.0.0 is available
    pip3 --version
    pip3 --disable-pip-version-check install --user pefile
  else
    if [ "${CC}" = 'mingw-clang' ] && [ "${os}" = 'mac' ]; then
      export PATH="/usr/local/opt/llvm/bin:${_ori_path}"
    fi
    _TRIPLET="${_machine}-w64-mingw32"
    # Prefixes don't work with MSYS2/mingw-w64, because `ar`, `nm` and
    # `runlib` are missing from them. They are accessible either _without_
    # one, or as prefix + `gcc-ar`, `gcc-nm`, `gcc-runlib`.
    _CCPREFIX="${_TRIPLET}-"
    # mingw-w64 sysroots
    if [ "${os}" = 'mac' ]; then
      _SYSROOT="/usr/local/opt/mingw-w64/toolchain-${_machine}"
    else
      _SYSROOT="/usr/${_TRIPLET}"
    fi
    if [ "${os}" = 'mac' ]; then
      _WINE='wine64'
    else
      _WINE='wine'
    fi
  fi

  export _CCVER
  if [ "${CC}" = 'mingw-clang' ]; then
    # We don't use old mingw toolchain versions when building with clang, so this is safe:
    _CCVER='99'
  else
    _CCVER="$("${_CCPREFIX}gcc" -dumpversion | sed -e 's/\<[0-9]\>/0&/g' -e 's/\.//g' | cut -c -2)"
  fi

  echo ".gcc-mingw-w64-${_machine} $(${_CCPREFIX}gcc -dumpversion)" >> "${_BLD}"
  echo ".binutils-mingw-w64-${_machine} $(${_CCPREFIX}ar V | grep -o -E '[0-9]+\.[0-9]+(\.[0-9]+)?')" >> "${_BLD}"

  command -v "$(dirname "$0")/osslsigncode-determ" >/dev/null 2>&1 || unset CODESIGN_KEY

  time ./libevent.sh       	"${LIBEVENT_VER_}" "${_cpu}"
  time ./memcached.sh		"${MEMCACHED_VER_}" "${_cpu}"
}

if [ -n "$CPU" ]; then
  build_single_target "${CPU}"
else
  build_single_target 64
  build_single_target 32
fi

sort "${_BLD}" > "${_BLD}.sorted"
mv -f "${_BLD}.sorted" "${_BLD}"

# Use the newest package timestamp for supplementary files
# shellcheck disable=SC2012
touch -r "$(ls -1 -t ./*-*-mingw*.* | head -1)" hashes.txt "${_BLD}" "${_LOG}"

ls -l ./*-*-mingw*.*
cat hashes.txt
cat "${_BLD}"

# Strip '-built-on-*' suffix for the single-file artifact,
# and also add revision to filenames.
for f in ./*-*-mingw*.*; do
  mv -f "${f}" "$(echo "${f}" | sed "s|-win|${_REV}-win|g" | sed 's|-built-on-[^.]*||g')"
done

sed "s|-win|${_REV}-win|g" hashes.txt | sed 's|-built-on-[^.]*||g' | sort > hashes.txt.all
touch -r hashes.txt hashes.txt.all
mv -f hashes.txt.all hashes.txt

# Create an artifact that includes all packages
_ALL="all-mingw-${MEMCACHED_VER_}${_REV}${_ALLSUFF}.zip"
zip -q -0 -X -o "${_ALL}" ./*-*-mingw*.* hashes.txt "${_BLD}" "${_LOG}"

openssl dgst -sha256 "${_ALL}" | tee "${_ALL}.txt"
openssl dgst -sha512 "${_ALL}" | tee -a "${_ALL}.txt"
